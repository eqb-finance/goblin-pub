#[test_only]
module Goblin::GoblinTests {

    use std::signer::address_of;
    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::delegation_pool;
    use aptos_framework::timestamp;
    use Goblin::Goblin;

    #[test]
    #[expected_failure(abort_code = 1000001)]
    public fun test_initialize_abort_not_goblin() {
        // This is a placeholder for the actual test logic.
        // You would typically call the functions you want to test here.
        // For example:
        let (_, alice) = setup_test();
        Goblin::initialize(&alice);
    }

    #[test]
    #[expected_failure(abort_code = 1000002)]
    public fun test_initialize_abort_already_initinalized() {
        // This is a placeholder for the actual test logic.
        // You would typically call the functions you want to test here.
        // For example:
        let (goblin, _) = setup_test();
        Goblin::initialize(&goblin);
    }

    #[test]
    public fun test_mint_goblin_token() {
        let (goblin, _) = setup_test();
        let resource_address = Goblin::get_resource_cap_address();
        Goblin::mint_goblin_token(&goblin, resource_address, 1000);
        let balance = Goblin::get_goblin_token_balance(resource_address);
        assert!(balance == 1000, 0);
    }

    #[test]
    public fun test_burn_goblin_token() {
        let (goblin, _) = setup_test();
        let resource_address = Goblin::get_resource_cap_address();
        Goblin::mint_goblin_token(&goblin, resource_address, 1000);
        let balance = Goblin::get_goblin_token_balance(resource_address);
        assert!(balance == 1000, 0);
        Goblin::burn_goblin_token(&goblin, resource_address, 500);
        let new_balance = Goblin::get_goblin_token_balance(resource_address);
        assert!(new_balance == 500, 0);
    }

    #[test]
    public fun test_transfer_goblin_token() {
        let (goblin, alice) = setup_test();
        let resource_address = Goblin::get_resource_cap_address();
        Goblin::mint_goblin_token(&goblin, resource_address, 1000);
        let balance_goblin = Goblin::get_goblin_token_balance(resource_address);
        assert!(balance_goblin == 1000, 0);

        Goblin::transfer_out_goblin_token(&goblin, address_of(&alice), 300);
        let balance_alice = Goblin::get_goblin_token_balance(address_of(&alice));
        assert!(balance_alice == 300, 0);

        let new_balance_goblin = Goblin::get_goblin_token_balance(resource_address);
        assert!(new_balance_goblin == 700, 0);
    }

    #[test]
    public fun test_set_pool() {
        let (goblin, alice) = setup_test();
        let pool_address = initialize_delegation_pool(&alice, b"Goblin pool 1");

        Goblin::set_pool(&goblin, pool_address, 1);
        let (pool_weight, total_weight) = Goblin::get_pool_weight(pool_address);
        assert!(pool_weight == 1, 0);
        assert!(total_weight == 1, 0);

        Goblin::set_pool(&goblin, pool_address, 2);
        (pool_weight, total_weight) = Goblin::get_pool_weight(pool_address);
        assert!(pool_weight == 2, 0);
        assert!(total_weight == 2, 0);

        let new_pool_address = initialize_delegation_pool(&goblin, b"Goblin pool 2");
        Goblin::set_pool(&goblin, new_pool_address, 3);
        let (new_pool_weight, new_total_weight) = Goblin::get_pool_weight(new_pool_address);
        assert!(new_pool_weight == 3, 0);
        assert!(new_total_weight == 5, 0);
    }

    #[test]
    public fun test_choose_pool() {
        let (goblin, alice) = setup_test();
        let pool_address1 = initialize_delegation_pool(&alice, b"Goblin pool 1");
        let pool_address2 = initialize_delegation_pool(&goblin, b"Goblin pool 2");

        Goblin::set_pool(&goblin, pool_address1, 1);
        Goblin::set_pool(&goblin, pool_address2, 2);

        let chosen_pool = Goblin::choose_pool_for_test();
        let counter_1 = 0;
        let counter_2 = 0;
        let iterations = 100;
        for (i in 0..iterations) {
            let pool = Goblin::choose_pool_for_test();
            timestamp::fast_forward_seconds(1);
            if (pool == pool_address1) {
                counter_1 += 1;
            } else if (pool == pool_address2) {
                counter_2 += 1;
            } else {
                abort 1000003; // Unexpected pool address
            }
        };
        assert!(counter_1 > 0, 0);
        assert!(counter_2 > 0, 0);
    }

    #[test]
    #[expected_failure(abort_code = 1000005)]
    public fun test_choose_pool_abort_no_pools() {
        let (_, _) = setup_test();
        // This test should fail because no pools are set
        Goblin::choose_pool_for_test();
    }

    #[test]
    public fun test_add_withdrawal() {
        let (goblin, alice) = setup_test();
        let pool_address = initialize_delegation_pool(&alice, b"Goblin pool 1");
        Goblin::set_pool(&goblin, pool_address, 1);

        // Add a withdrawal
        Goblin::add_withdrawal(&alice, pool_address, 100, 0, 3);
        Goblin::add_withdrawal(&alice, pool_address, 100, 0, 2);
        Goblin::add_withdrawal(&alice, pool_address, 100, 0, 3);

        let results = Goblin::get_withdrawals(address_of(&alice));
        assert!(results.length() == 3, 0);
    }

    public fun initialize_delegation_pool(
        signer: &signer,
        seed: vector<u8>
    ): address {
        delegation_pool::initialize_delegation_pool(signer, 10, seed);
        let signer_address = address_of(signer);
        delegation_pool::get_owned_pool_address(signer_address)
    }

    public fun setup_test(): (signer, signer) {
        let goblin = account::create_account_for_test(@Goblin);
        let alice = account::create_account_for_test(@0x1);
        let (burn_cap, mint_cap) = aptos_framework::aptos_coin::initialize_for_test(&alice);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
        timestamp::set_time_has_started_for_testing(&alice);
        Goblin::initialize(&goblin);
        // Return the Goblin account for further testing
        (goblin, alice)
    }
}