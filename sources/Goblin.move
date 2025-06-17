module Goblin::Goblin {
    use std::option;
    use std::signer::address_of;
    use std::string::utf8;
    use aptos_std::simple_map;
    use aptos_std::simple_map::SimpleMap;
    use aptos_std::table;
    use aptos_framework::aptos_account;
    use aptos_framework::delegation_pool;
    use aptos_framework::fungible_asset;
    use aptos_framework::fungible_asset::{MintRef, BurnRef, Metadata};
    use aptos_framework::object;
    use aptos_framework::object::{Object, ExtendRef};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp::now_seconds;

    const GOBLIN_SEED: vector<u8> = b"Goblin seed";
    const GOBLIN_TOKEN_NAME: vector<u8> = b"Goblin token";
    const GOBLIN_TOKEN_SYMBOL: vector<u8> = b"GOBLIN";
    const GOBLIN_PROJECT_URL: vector<u8> = b"https://goblin.io";

    const ENOT_GOBLIN: u64 = 1000001;
    const EGOBLIN_ALREADY_INITIALIZED: u64 = 1000002;
    const ENO_WITHDRAWAL: u64 = 1000003;
    const EDELEGATION_POOL_NOT_FOUND: u64 = 1000004;
    const EPOOL_NOT_FOUND: u64 = 1000005;
    const EDIVIDOR_ZERO: u64 = 1000006;
    const ESAME_REWARD_RECEIPT: u64 = 1000007;
    const EPARAM_AMOUNT_ZERO: u64 = 1000008;

    struct GoblinExternal has key, store {
        mint_ref: MintRef,
        burn_ref: BurnRef,
        metadata: Object<Metadata>,
    }

    struct GoblinConfig has key, store {
        delegation_pools: SimpleMap<address, u256>,
        reward_receipt: address,
        extend_ref: ExtendRef,
    }

    struct Storage has key, store {
        withdrawals: table::Table<address, vector<Withdrawal>>,
    }

    struct Withdrawal has store, copy, drop {
        amount: u64,
        pool: address,
        init_time: u64,
        unlock_index: u64,
    }

    public entry fun initialize(signer: &signer) {
        let signer_addr = address_of(signer);
        assert!(signer_addr == @Goblin, ENOT_GOBLIN);
        assert!(!object::object_exists<GoblinConfig>(get_storage_address()), EGOBLIN_ALREADY_INITIALIZED);

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
            metadata: object::object_from_constructor_ref<Metadata>(&constructor_ref),
        };

        let extend_ref = object::generate_extend_ref(&constructor_ref);

        let config = GoblinConfig {
            delegation_pools: simple_map::new<address, u256>(),
            reward_receipt: signer_addr,
            extend_ref,
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
        assert!(delegation_pool::delegation_pool_exists(pool), EDELEGATION_POOL_NOT_FOUND);
        let address = get_storage_address();
        let config = borrow_global_mut<GoblinConfig>(address);

        // add or update the pool with the given weight
        config.delegation_pools.upsert(pool, weight);
    }

    public entry fun set_reward_receipt(signer: &signer, reward_receipt: address) acquires GoblinConfig {
        let signer_addr = address_of(signer);
        assert!(signer_addr == @Goblin, ENOT_GOBLIN);
        let address = get_storage_address();
        let config = borrow_global_mut<GoblinConfig>(address);
        assert!(config.reward_receipt != reward_receipt, ESAME_REWARD_RECEIPT);

        // set the reward receipt address
        config.reward_receipt = reward_receipt;
    }

    public entry fun stake(signer: &signer, amount: u64) acquires GoblinConfig, GoblinExternal {
        assert!(amount > 0, EPARAM_AMOUNT_ZERO);
        let signer_addr = address_of(signer);
        let address = get_storage_address();
        let config = borrow_global_mut<GoblinConfig>(address);
        let external = borrow_global_mut<GoblinExternal>(address);

        let pool = choose_pool(config);
        let goblin_signer = object::generate_signer_for_extending(&config.extend_ref);
        let goblin_signer_addr = address_of(&goblin_signer);

        // calculate the amount of GOBLIN tokens to mint
        let goblin_amount = get_goblin_amount(config, external, goblin_signer_addr, amount);

        aptos_account::transfer(signer, goblin_signer_addr, amount);
        delegation_pool::add_stake(&goblin_signer, pool, amount);

        primary_fungible_store::mint(&external.mint_ref, signer_addr, goblin_amount);
    }

    public entry fun unlock(signer: &signer, goblin_amount: u64) acquires GoblinConfig, GoblinExternal, Storage {
        assert!(goblin_amount > 0, EPARAM_AMOUNT_ZERO);
        let signer_addr = address_of(signer);
        let address = get_storage_address();
        let config = borrow_global_mut<GoblinConfig>(address);
        let external = borrow_global_mut<GoblinExternal>(address);

        let pool = choose_pool(config);
        let goblin_signer = object::generate_signer_for_extending(&config.extend_ref);
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
        let goblin_signer = object::generate_signer_for_extending(&config.extend_ref);

        // check if the signer has a withdrawal for the given pool and unlock_index
        let withdrawals = storage.withdrawals.borrow_mut(signer_addr);
        let len = withdrawals.length();
        assert!(len > 0, ENO_WITHDRAWAL);
        while (len > 0) {
            let withdrawal = withdrawals.borrow(len - 1);
            if (withdrawal.unlock_index < delegation_pool::observed_lockup_cycle(withdrawal.pool)) {
                // withdraw the amount from the delegation pool and transfer it to the signer
                delegation_pool::withdraw(&goblin_signer, withdrawal.pool, withdrawal.amount);
                aptos_account::transfer(&goblin_signer, signer_addr, withdrawal.amount);
                withdrawals.remove(len - 1);
            };
            len -= 1;
        };
    }

    fun get_goblin_amount(config: &GoblinConfig, external: &GoblinExternal, goblin_signer_addr: address, amount: u64): u64 {
        let goblin_supply = fungible_asset::supply(external.metadata);
        let total_stake = get_total_stake(config, goblin_signer_addr) as u256;
        // if no goblin supply or no stake, return the original amount
        if (goblin_supply.is_none() || total_stake == 0) {
            return amount;
        };
        let goblin_supply_value = *goblin_supply.borrow() as u256;

        (goblin_supply_value * (amount as u256) / total_stake) as u64
    }

    fun get_amount_from_goblin_amount(config: &GoblinConfig, external: &GoblinExternal, goblin_signer_addr: address, goblin_amount: u64): u64 {
        let goblin_supply = fungible_asset::supply(external.metadata);
        let total_stake = get_total_stake(config, goblin_signer_addr) as u256;
        let goblin_supply_value = *goblin_supply.borrow() as u256;
        assert!(goblin_supply_value > 0, EDIVIDOR_ZERO);
        (total_stake * (goblin_amount as u256) / goblin_supply_value) as u64
    }

    /// Returns the total stake of all pools for a given goblin signer address.
    /// This is used to calculate the amount of GOBLIN tokens to mint or burn.
    /// It iterates through all pools in the GoblinConfig and sums up the active stakes.
    /// only active stakes are considered, pending inactive and inactive stakes are ignored.
    fun get_total_stake(config: &GoblinConfig, goblin_signer_address: address): u64 {
        let pools = config.delegation_pools.keys();
        let total_stake = pools.fold(0, |acc, pool| {
            let (active, _, _) = delegation_pool::get_stake(pool, goblin_signer_address);
            acc + active
        });
        total_stake
    }

    /// Chooses a delegation pool based on the weights defined in the GoblinConfig.
    /// Asumes that the probability of choosing a pool is proportional to its weight.
    /// Simply iterates through the pools and their weights, accumulating the weights
    /// until it finds the pool that corresponds to the random number generated.
    /// Don't choose pool depend on the real weights of the pools, because it's too expensive.
    fun choose_pool(config: &GoblinConfig): address {
        let pools = config.delegation_pools.keys();
        let len = pools.length();
        assert!(len > 0, EPOOL_NOT_FOUND);

        let weights = config.delegation_pools.values();

        let total_weight: u256 = weights.fold(0, |acc, w| acc + w);
        assert!(total_weight > 0, EDIVIDOR_ZERO);

        let now = now_seconds();
        let r = (now as u256) % total_weight;

        let cumulative = 0;
        let i = 0;
        while (i < len) {
            let pool = *pools.borrow(i);
            let weight = *weights.borrow(i);
            cumulative += weight;
            if (cumulative > r) {
                return pool;
            };
            i += 1;
        };

        *pools.borrow(0)
    }

    fun get_storage_address(): address {
        object::create_object_address(&@Goblin, GOBLIN_SEED)
    }

    #[view]
    fun get_goblin_amount_from_apt(amount: u64): u64 acquires GoblinConfig, GoblinExternal {
        let address = get_storage_address();
        let external = borrow_global<GoblinExternal>(address);
        let config = borrow_global<GoblinConfig>(address);
        let goblin_signer = object::generate_signer_for_extending(&config.extend_ref);
        let goblin_signer_addr = address_of(&goblin_signer);

        get_goblin_amount(config, external, goblin_signer_addr, amount)
    }

    #[view]
    public fun get_withdrawals(signer_addr: address): vector<Withdrawal> acquires Storage {
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
    public fun get_pool_weight(pool: address): (u256, u256) acquires GoblinConfig {
        let address = get_storage_address();
        let config = borrow_global<GoblinConfig>(address);
        let values = config.delegation_pools.values();
        let total_weight = values.fold(0, |acc, v| acc + v);
        if (total_weight == 0) {
            return (0, 0);
        };
        if (!config.delegation_pools.contains_key(&pool)) {
            return (0, total_weight);
        };
        let weight = *config.delegation_pools.borrow(&pool);
        (weight, total_weight)
    }

    #[view]
    public fun get_goblin_token(): Object<Metadata> acquires GoblinExternal {
        let address = get_storage_address();
        let external = borrow_global<GoblinExternal>(address);
        external.metadata
    }

    #[view]
    public fun get_goblin_reward_receipt(): address acquires GoblinConfig {
        let address = get_storage_address();
        let config = borrow_global<GoblinConfig>(address);
        config.reward_receipt
    }

    #[view]
    public fun get_goblin_token_balance(user: address): u64 acquires GoblinExternal {
        let address = get_storage_address();
        let external = borrow_global<GoblinExternal>(address);
        let metadata = external.metadata;
        primary_fungible_store::balance(user, metadata)
    }

    #[test_only]
    public fun mint_goblin_token(signer: &signer, user: address, amount: u64) acquires GoblinExternal {
        assert!(address_of(signer) == @Goblin, ENOT_GOBLIN);
        let address = get_storage_address();
        let external = borrow_global_mut<GoblinExternal>(address);
        primary_fungible_store::mint(&external.mint_ref, user, amount);
    }

    #[test_only]
    public fun burn_goblin_token(signer: &signer, user: address, amount: u64) acquires GoblinExternal {
        assert!(address_of(signer) == @Goblin, ENOT_GOBLIN);
        let address = get_storage_address();
        let external = borrow_global_mut<GoblinExternal>(address);
        primary_fungible_store::burn(&external.burn_ref, user, amount);
    }

    #[test_only]
    public fun transfer_goblin_token(signer: &signer, recipient: address, amount: u64) acquires GoblinExternal {
        let address = get_storage_address();
        let external = borrow_global_mut<GoblinExternal>(address);
        primary_fungible_store::transfer(signer, external.metadata, recipient, amount);
    }

    #[test_only]
    public fun transfer_out_goblin_token(goblin_signer: &signer, recipient: address, amount: u64) acquires GoblinConfig, GoblinExternal {
        assert!(address_of(goblin_signer) == @Goblin, ENOT_GOBLIN);
        let address = get_storage_address();
        let config = borrow_global_mut<GoblinConfig>(address);
        let goblin_signer = object::generate_signer_for_extending(&config.extend_ref);
        transfer_goblin_token(&goblin_signer, recipient, amount);
    }

    #[test_only]
    public fun get_resource_cap_address(): address {
        get_storage_address()
    }

    #[test_only]
    public fun choose_pool_for_test(): address acquires GoblinConfig {
        let address = get_storage_address();
        let config = borrow_global<GoblinConfig>(address);
        choose_pool(config)
    }

    #[test_only]
    public fun add_withdrawal(
        signer: &signer,
        pool: address,
        amount: u64,
        init_time: u64,
        unlock_index: u64
    ) acquires Storage {
        let signer_addr = address_of(signer);
        let address = get_storage_address();
        let storage = borrow_global_mut<Storage>(address);

        if (!storage.withdrawals.contains(signer_addr)) {
            storage.withdrawals.upsert(signer_addr, std::vector::empty());
        };

        let withdrawal = Withdrawal {
            amount,
            pool,
            init_time,
            unlock_index
        };

        storage.withdrawals.borrow_mut(signer_addr).push_back(withdrawal);
    }
}
