module Goblin::Goblin {
    use std::option;
    use std::signer::address_of;
    use std::string::utf8;
    use aptos_std::simple_map;
    use aptos_std::simple_map::SimpleMap;
    use aptos_std::table;
    use aptos_framework::account;
    use aptos_framework::account::SignerCapability;
    use aptos_framework::aptos_account;
    use aptos_framework::delegation_pool;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{MintRef, BurnRef, Metadata};
    use aptos_framework::object;
    use aptos_framework::object::Object;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp::now_seconds;

    const GOBLIN_SEED: vector<u8> = b"Goblin seed";
    const CAPABILITY_NAME: vector<u8> = b"Goblin capability";
    const GOBLIN_TOKEN_NAME: vector<u8> = b"Goblin token";
    const GOBLIN_TOKEN_SYMBOL: vector<u8> = b"GOBLIN";
    const GOBLIN_PROJECT_URL: vector<u8> = b"https://goblin.io";
    const GOBLIN_PERCISION: u256 = 10000;

    const ENOT_GOBLIN: u64 = 1000001;
    const EGOBLIN_ALREADY_INITIALIZED: u64 = 1000002;
    const ENO_WITHDRAWAL: u64 = 1000003;

    struct GoblinExternal has key, store {
        mint_ref: MintRef,
        burn_ref: BurnRef,
        metadata: Object<Metadata>,
    }

    struct GoblinConfig has key, store {
        pools: SimpleMap<address, u256>,
        reward_receipt: address,
        resource_cap: SignerCapability,
    }

    struct Storage has key, store {
        withdrawals: table::Table<address, vector<Withdrawal>>,
    }

    struct Withdrawal has store, drop {
        amount: u64,
        pool: address,
        init_time: u64,
        unlock_index: u64,
    }

    public entry fun initialize(signer: &signer) {
        let signer_addr = address_of(signer);
        assert!(signer_addr == @Goblin, ENOT_GOBLIN);
        assert!(!object::object_exists<GoblinConfig>(signer_addr), EGOBLIN_ALREADY_INITIALIZED);

        let constructor_ref = object::create_named_object(signer, GOBLIN_SEED);
        let object_signer = object::generate_signer(&constructor_ref);

        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor_ref,
            option::none(),
            utf8(GOBLIN_TOKEN_NAME),
            utf8(GOBLIN_TOKEN_SYMBOL),
            8,
            utf8(b""),
            utf8(GOBLIN_PROJECT_URL),
        );

        let mint_ref = fungible_asset::generate_mint_ref(&constructor_ref);
        let burn_ref = fungible_asset::generate_burn_ref(&constructor_ref);

        let external = GoblinExternal {
            mint_ref,
            burn_ref,
            metadata: object::object_from_constructor_ref(&constructor_ref),
        };

        let (_, capability) = account::create_resource_account(signer, CAPABILITY_NAME);

        let config = GoblinConfig {
            pools: simple_map::new<address, u256>(),
            reward_receipt: signer_addr,
            resource_cap: capability,
        };

        let storage = Storage {
            withdrawals: table::new<address, vector<Withdrawal>>(),
        };

        move_to(&object_signer, config);
        move_to(&object_signer, external);
        move_to(&object_signer, storage);
    }

    public entry fun set_pool(signer: &signer, pool: address, weight: u256) acquires GoblinConfig {
        let signer_addr = address_of(signer);
        assert!(signer_addr == @Goblin, ENOT_GOBLIN);
        let address = get_storage_address();
        let config = borrow_global_mut<GoblinConfig>(address);

        // add or update the pool with the given weight
        config.pools.upsert(pool, weight);
    }

    public entry fun set_reward_receipt(signer: &signer, reward_receipt: address) acquires GoblinConfig {
        let signer_addr = address_of(signer);
        assert!(signer_addr == @Goblin, ENOT_GOBLIN);
        let address = get_storage_address();
        let config = borrow_global_mut<GoblinConfig>(address);

        // set the reward receipt address
        config.reward_receipt = reward_receipt;
    }

    public entry fun stake(signer: &signer, amount: u64) acquires GoblinConfig, GoblinExternal {
        let signer_addr = address_of(signer);
        let address = get_storage_address();
        let config = borrow_global_mut<GoblinConfig>(address);
        let external = borrow_global_mut<GoblinExternal>(address);

        let pool = choose_pool(config);
        let goblin_signer = account::create_signer_with_capability(&config.resource_cap);
        let goblin_signer_addr = address_of(&goblin_signer);

        aptos_account::transfer(signer, goblin_signer_addr, amount);
        delegation_pool::add_stake(&goblin_signer, pool, amount);

        let goblin_amount = get_goblin_amount(config, external, goblin_signer_addr, amount);

        primary_fungible_store::mint(&external.mint_ref, signer_addr, goblin_amount);
    }

    public entry fun unlock(signer: &signer, goblin_amount: u64) acquires GoblinConfig, GoblinExternal, Storage {
        let signer_addr = address_of(signer);
        let address = get_storage_address();
        let config = borrow_global_mut<GoblinConfig>(address);
        let external = borrow_global_mut<GoblinExternal>(address);

        let pool = choose_pool(config);
        let goblin_signer = account::create_signer_with_capability(&config.resource_cap);
        let goblin_signer_addr = address_of(&goblin_signer);

        let amount = get_amount_from_goblin_amount(config, external, goblin_signer_addr, goblin_amount);
        delegation_pool::unlock(&goblin_signer, pool, amount);
        let unlock_index = delegation_pool::observed_lockup_cycle(pool);

        // add withdrawal to storage
        let withdrawal = Withdrawal {
            amount,
            pool,
            init_time: now_seconds(),
            unlock_index
        };

        let storage = borrow_global_mut<Storage>(address);
        if (!storage.withdrawals.contains(signer_addr)) {
            storage.withdrawals.upsert(signer_addr, std::vector::empty());
        };
        storage.withdrawals.borrow_mut(signer_addr).push_back(withdrawal);

        primary_fungible_store::burn(&external.burn_ref, signer_addr, goblin_amount);
    }

    public entry fun withdraw(signer: &signer) acquires GoblinConfig, Storage {
        let signer_addr = address_of(signer);
        let address = get_storage_address();
        let config = borrow_global<GoblinConfig>(address);
        let storage = borrow_global_mut<Storage>(address);
        let goblin_signer = account::create_signer_with_capability(&config.resource_cap);

        // check if the signer has a withdrawal for the given pool and unlock_index
        let withdrawals = storage.withdrawals.borrow_mut(signer_addr);
        let len = withdrawals.length();
        assert!(len > 0, ENO_WITHDRAWAL);
        while (len > 0) {
            let withdrawal = withdrawals.borrow(len - 1);
            if (withdrawal.unlock_index < delegation_pool::observed_lockup_cycle(withdrawal.pool)) {
                aptos_account::transfer(&goblin_signer, signer_addr, withdrawal.amount);
                withdrawals.remove(len - 1);
            };
            len -= 1;
        };
    }

    fun get_goblin_amount(config: &GoblinConfig, external: &GoblinExternal, goblin_signer_addr: address, amount: u64): u64 {
        let goblin_supply = fungible_asset::supply(external.metadata);
        let total_stake = get_total_stake(config, goblin_signer_addr);
        // if no goblin supply or no stake, return the original amount
        if (goblin_supply.is_none() || total_stake == 0) {
            return amount;
        };
        let goblin_supply_value = *goblin_supply.borrow() as u64;

        goblin_supply_value * amount / total_stake
    }

    fun get_amount_from_goblin_amount(config: &GoblinConfig, external: &GoblinExternal, goblin_signer_addr: address, goblin_amount: u64): u64 {
        let goblin_supply = fungible_asset::supply(external.metadata);
        let total_stake = get_total_stake(config, goblin_signer_addr);
        let goblin_supply_value = *goblin_supply.borrow() as u64;
        total_stake * goblin_amount / goblin_supply_value
    }

    /// Returns the total stake of all pools for a given goblin signer address.
    /// This is used to calculate the amount of GOBLIN tokens to mint or burn.
    /// It iterates through all pools in the GoblinConfig and sums up the active and pending inactive stakes.
    /// only active stakes are considered, pending inactive and inactive stakes are ignored.
    fun get_total_stake(config: &GoblinConfig, goblin_signer_address: address): u64 {
        let pools = config.pools.keys();
        let total_stake = pools.fold(0, |acc, pool| {
            let (active, _, _) = delegation_pool::get_stake(pool, goblin_signer_address);
            acc + active
        });
        total_stake
    }

    /// TODO: This function should implement a more sophisticated pool selection logic.
    fun choose_pool(config: &GoblinConfig): address {
        *config.pools.keys().borrow(0)
    }

    fun get_storage_address(): address {
        object::create_object_address(&@Goblin, GOBLIN_SEED)
    }


    #[view]
    fun get_goblin_amount_from_apt(amount: u64): u64 acquires GoblinConfig, GoblinExternal {
        let address = get_storage_address();
        let external = borrow_global<GoblinExternal>(address);
        let config = borrow_global<GoblinConfig>(address);
        let goblin_signer = account::create_signer_with_capability(&config.resource_cap);
        let goblin_signer_addr = address_of(&goblin_signer);

        get_goblin_amount(config, external, goblin_signer_addr, amount)
    }

    #[view]
    fun get_withdrawals(signer_addr: address): vector<Withdrawal> acquires Storage {
        let address = get_storage_address();
        let storage = borrow_global<Storage>(address);
        if (!storage.withdrawals.contains(signer_addr)) {
            std::vector::empty()
        } else {
            let withdrawals = storage.withdrawals.borrow(signer_addr);
            let len = withdrawals.length();
            let result = std::vector::empty<Withdrawal>();
            for (i in 0..len) {
                let withdrawal = withdrawals.borrow(i);
                result.push_back(Withdrawal {
                    amount: withdrawal.amount,
                    pool: withdrawal.pool,
                    init_time: withdrawal.init_time,
                    unlock_index: withdrawal.unlock_index
                });
            };
            result
        }
    }

    #[view]
    fun get_pool_weight(pool: address): u256 acquires GoblinConfig {
        let address = get_storage_address();
        let config = borrow_global<GoblinConfig>(address);
        if (!config.pools.contains_key(&pool)) {
            0
        } else {
            let values = config.pools.values();
            let weight = *config.pools.borrow(&pool);
            let total_weight = values.fold(0, |acc, v| acc + v);
            if (total_weight == 0) {
                0
            } else {
                weight * GOBLIN_PERCISION / total_weight
            }
        }
    }

    #[view]
    public fun get_goblin_token(): Object<Metadata> acquires GoblinExternal {
        let address = get_storage_address();
        let external = borrow_global<GoblinExternal>(address);
        external.metadata
    }
}
