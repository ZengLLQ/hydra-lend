#[test_only]
module hydra_lend::hydra_tests {
    use std::signer;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use aptos_framework::coin;
    use hydra_lend::math;
    use hydra_lend::rate_model;
    use hydra_lend::oracle;
    use hydra_lend::lending_market;
    use hydra_lend::hot_potato;
    use hydra_lend::test_coins::{Self, TestAPT, TestUSDC, TestWBTC};

    fun setup(
        framework: &signer,
        admin: &signer,
        alice: &signer,
        bob: &signer
    ) {
        // Initialize mock timestamp at t = 1000000
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1000000);

        // Create accounts
        account::create_account_for_test(signer::address_of(admin));
        account::create_account_for_test(signer::address_of(alice));
        account::create_account_for_test(signer::address_of(bob));

        // Initialize admin caps and oracle
        lending_market::initialize_admin(admin);
        oracle::initialize(admin);

        // Initialize mock test coins
        test_coins::initialize_coin<TestAPT>(admin, b"Aptos Token", b"APT", 8);
        test_coins::initialize_coin<TestUSDC>(admin, b"USD Coin", b"USDC", 6);
        test_coins::initialize_coin<TestWBTC>(admin, b"Wrapped BTC", b"WBTC", 8);

        // Register coin stores for accounts
        coin::register<TestAPT>(admin);
        coin::register<TestUSDC>(admin);
        coin::register<TestWBTC>(admin);

        coin::register<TestAPT>(alice);
        coin::register<TestUSDC>(alice);
        coin::register<TestWBTC>(alice);

        coin::register<TestAPT>(bob);
        coin::register<TestUSDC>(bob);
        coin::register<TestWBTC>(bob);

        // Set oracle prices (8 decimals):
        // 1 APT = $10.00 (1,000,000,000)
        // 1 USDC = $1.00 (100,000,000)
        // 1 WBTC = $60,000.00 (6,000,000,000,000)
        oracle::set_price<TestAPT>(admin, 1000000000, 8);
        oracle::set_price<TestUSDC>(admin, 100000000, 6);
        oracle::set_price<TestWBTC>(admin, 6000000000000, 8);

        // Create lending pools:
        // Jump rate config: base 2% (200), kink 80% (8000), slope1 8% (800), slope2 100% (10000), reserve 10% (1000)
        let rate_cfg = rate_model::new_config(200, 8000, 800, 10000, 1000);

        // APT pool: LTV 70% (7000), LiqThresh 80% (8000), LiqBonus 5% (500), FlashFee 9 bps (9)
        lending_market::create_pool<TestAPT>(admin, rate_cfg, 7000, 8000, 500, 9);
        // USDC pool: LTV 80% (8000), LiqThresh 85% (8500), LiqBonus 5% (500), FlashFee 9 bps (9)
        lending_market::create_pool<TestUSDC>(admin, rate_cfg, 8000, 8500, 500, 9);
    }

    // =========================================================================
    // 1. Math Tests
    // =========================================================================
    #[test]
    fun test_math_operations() {
        assert!(math::mul_bps(10000, 500) == 500, 1); // 5% of 10,000 = 500
        assert!(math::div_bps(500, 500) == 10000, 2);
        assert!(math::lerp(100, 200, 50, 100) == 150, 3);
        assert!(math::min(10, 20) == 10, 4);
        assert!(math::max(10, 20) == 20, 5);
        assert!(math::pow(2, 10) == 1024, 6);

        let wad = math::wad();
        assert!(math::wad_mul(wad * 2, wad * 3) == wad * 6, 7);
        assert!(math::wad_div(wad * 6, wad * 2) == wad * 3, 8);
    }

    // =========================================================================
    // 2. Rate Model Tests
    // =========================================================================
    #[test]
    fun test_rate_model_utilization_and_jump_curve() {
        let cfg = rate_model::new_config(200, 8000, 800, 10000, 1000);

        // At 0% utilization: rate = base (200 bps = 2%)
        let u0 = rate_model::calculate_utilization(100000, 0, 0);
        assert!(u0 == 0, 1);
        let r0 = rate_model::calculate_borrow_rate(&cfg, 100000, 0, 0);
        assert!(r0 == 200, 2);

        // At 40% utilization (halfway to kink): rate = 200 + 400 = 600 bps (6%)
        let u40 = rate_model::calculate_utilization(60000, 40000, 0);
        assert!(u40 == 4000, 3);
        let r40 = rate_model::calculate_borrow_rate(&cfg, 60000, 40000, 0);
        assert!(r40 == 600, 4);

        // At kink 80% utilization: rate = 200 + 800 = 1000 bps (10%)
        let u80 = rate_model::calculate_utilization(20000, 80000, 0);
        assert!(u80 == 8000, 5);
        let r80 = rate_model::calculate_borrow_rate(&cfg, 20000, 80000, 0);
        assert!(r80 == 1000, 6);

        // Beyond kink at 90% utilization:
        // rate = 200 + 800 + ((9000-8000)/(10000-8000)) * 10000 = 1000 + 5000 = 6000 bps (60%)
        let u90 = rate_model::calculate_utilization(10000, 90000, 0);
        assert!(u90 == 9000, 7);
        let r90 = rate_model::calculate_borrow_rate(&cfg, 10000, 90000, 0);
        assert!(r90 == 6000, 8);
    }

    // =========================================================================
    // 3. Oracle Valuation Tests
    // =========================================================================
    #[test(framework = @0x1, admin = @hydra_lend, alice = @0x11, bob = @0x12)]
    fun test_oracle_valuation(framework: &signer, admin: &signer, alice: &signer, bob: &signer) {
        setup(framework, admin, alice, bob);

        // 10 APT (10 * 10^8) at $10.00/APT = $100.00 (100 * 10^8 = 10,000,000,000)
        let apt_val = oracle::calculate_value_usd<TestAPT>(1000000000);
        assert!(apt_val == 10000000000, 1);

        // 500 USDC (500 * 10^6) at $1.00/USDC = $500.00 (500 * 10^8 = 50,000,000,000)
        let usdc_val = oracle::calculate_value_usd<TestUSDC>(500000000);
        assert!(usdc_val == 50000000000, 2);

        // Convert $100.00 USD back to APT = 10 APT
        let apt_amt = oracle::calculate_amount_from_usd<TestAPT>(10000000000);
        assert!(apt_amt == 1000000000, 3);
    }

    // =========================================================================
    // 4. Supply Liquidity and Withdraw Tests
    // =========================================================================
    #[test(framework = @0x1, admin = @hydra_lend, alice = @0x11, bob = @0x12)]
    fun test_supply_and_withdraw(framework: &signer, admin: &signer, alice: &signer, bob: &signer) {
        setup(framework, admin, alice, bob);

        // Mint 10,000 USDC to Alice
        let alice_usdc = test_coins::mint<TestUSDC>(10000000000); // 10,000 USDC
        lending_market::supply<TestUSDC>(alice, alice_usdc);

        let alice_addr = signer::address_of(alice);
        assert!(lending_market::get_user_supply_shares<TestUSDC>(alice_addr) == 10000000000, 1);
        assert!(lending_market::get_pool_cash<TestUSDC>() == 10000000000, 2);

        // Alice withdraws 4,000 USDC shares
        let withdrawn_coin = lending_market::withdraw_supply<TestUSDC>(alice, 4000000000);
        assert!(coin::value(&withdrawn_coin) == 4000000000, 3);
        assert!(lending_market::get_pool_cash<TestUSDC>() == 6000000000, 4);
        assert!(lending_market::get_user_supply_shares<TestUSDC>(alice_addr) == 6000000000, 5);

        test_coins::burn(withdrawn_coin);
    }

    // =========================================================================
    // 5. Collateral Deposit, Borrow, and Health Factor
    // =========================================================================
    #[test(framework = @0x1, admin = @hydra_lend, alice = @0x11, bob = @0x12)]
    fun test_collateral_deposit_and_borrow(framework: &signer, admin: &signer, alice: &signer, bob: &signer) {
        setup(framework, admin, alice, bob);

        // Alice supplies 20,000 USDC to pool for liquidity
        let supply_coin = test_coins::mint<TestUSDC>(20000000000);
        lending_market::supply<TestUSDC>(alice, supply_coin);

        // Bob deposits 100 APT as collateral: 100 APT * $10 = $1,000 USD
        // Max borrow capacity at 70% LTV = $700 USD (700 USDC)
        let bob_apt = test_coins::mint<TestAPT>(10000000000); // 100 APT (8 dec)
        lending_market::deposit_collateral<TestAPT>(bob, bob_apt);

        let bob_addr = signer::address_of(bob);
        assert!(lending_market::get_user_collateral<TestAPT>(bob_addr) == 10000000000, 1);

        // Bob borrows 600 USDC ($600 USD <= $700 max capacity)
        let borrowed_usdc = lending_market::borrow<TestUSDC, TestAPT>(bob, 600000000);
        assert!(coin::value(&borrowed_usdc) == 600000000, 2);
        assert!(lending_market::get_user_borrow<TestUSDC>(bob_addr) == 600000000, 3);
        assert!(lending_market::get_pool_total_borrows<TestUSDC>() == 600000000, 4);

        // Check Bob's Health Factor:
        // Collateral value = $1,000. Liq Threshold = 80% -> $800.
        // Debt value = $600.
        // HF = 800 / 600 = 1.3333... (13333 bps)
        let hf = lending_market::calculate_health_factor<TestAPT, TestUSDC>(bob_addr);
        assert!(hf >= 13300 && hf <= 13350, 5);

        test_coins::burn(borrowed_usdc);
    }

    // =========================================================================
    // 6. Borrow Fails When Exceeding LTV
    // =========================================================================
    #[test(framework = @0x1, admin = @hydra_lend, alice = @0x11, bob = @0x12)]
    #[expected_failure(abort_code = 0x30fa7, location = hydra_lend::lending_market)]
    fun test_borrow_fails_insufficient_collateral(framework: &signer, admin: &signer, alice: &signer, bob: &signer) {
        setup(framework, admin, alice, bob);

        // Supply 10,000 USDC
        let supply_coin = test_coins::mint<TestUSDC>(10000000000);
        lending_market::supply<TestUSDC>(alice, supply_coin);

        // Bob deposits 10 APT ($100 USD value). Max borrow 70% LTV = $70 USDC.
        let bob_apt = test_coins::mint<TestAPT>(1000000000);
        lending_market::deposit_collateral<TestAPT>(bob, bob_apt);

        // Bob attempts to borrow 90 USDC ($90 > $70 max borrow capacity) -> MUST ABORT
        let borrowed = lending_market::borrow<TestUSDC, TestAPT>(bob, 90000000);
        test_coins::burn(borrowed);
    }

    // =========================================================================
    // 7. Repay Debt
    // =========================================================================
    #[test(framework = @0x1, admin = @hydra_lend, alice = @0x11, bob = @0x12)]
    fun test_repay_borrow_debt(framework: &signer, admin: &signer, alice: &signer, bob: &signer) {
        setup(framework, admin, alice, bob);

        // Supply liquidity and borrow
        let supply_coin = test_coins::mint<TestUSDC>(20000000000);
        lending_market::supply<TestUSDC>(alice, supply_coin);

        let bob_apt = test_coins::mint<TestAPT>(10000000000);
        lending_market::deposit_collateral<TestAPT>(bob, bob_apt);
        let borrowed = lending_market::borrow<TestUSDC, TestAPT>(bob, 500000000); // 500 USDC

        let bob_addr = signer::address_of(bob);
        assert!(lending_market::get_user_borrow<TestUSDC>(bob_addr) == 500000000, 1);

        // Bob repays 300 USDC
        let repay_payment = test_coins::mint<TestUSDC>(300000000);
        let refund = lending_market::repay<TestUSDC>(bob, repay_payment);
        assert!(coin::value(&refund) == 0, 2);
        coin::destroy_zero(refund);

        assert!(lending_market::get_user_borrow<TestUSDC>(bob_addr) == 200000000, 3);
        assert!(lending_market::get_pool_total_borrows<TestUSDC>() == 200000000, 4);

        test_coins::burn(borrowed);
    }

    // =========================================================================
    // 8. Interest Accrual Over Time
    // =========================================================================
    #[test(framework = @0x1, admin = @hydra_lend, alice = @0x11, bob = @0x12)]
    fun test_interest_accrual_over_time(framework: &signer, admin: &signer, alice: &signer, bob: &signer) {
        setup(framework, admin, alice, bob);

        // Supply 100,000 USDC
        let supply_coin = test_coins::mint<TestUSDC>(100000000000);
        lending_market::supply<TestUSDC>(alice, supply_coin);

        // Bob deposits 10,000 APT ($100,000 USD) and borrows 50,000 USDC
        let bob_apt = test_coins::mint<TestAPT>(1000000000000);
        lending_market::deposit_collateral<TestAPT>(bob, bob_apt);
        let borrowed = lending_market::borrow<TestUSDC, TestAPT>(bob, 50000000000);

        let borrows_before = lending_market::get_pool_total_borrows<TestUSDC>();
        let reserves_before = lending_market::get_pool_reserves<TestUSDC>();

        // Advance mock time by 1 year (31,536,000 seconds)
        timestamp::fast_forward_seconds(31536000);

        // Trigger interest accrual
        lending_market::accrue_interest<TestUSDC>();

        let borrows_after = lending_market::get_pool_total_borrows<TestUSDC>();
        let reserves_after = lending_market::get_pool_reserves<TestUSDC>();

        // Total borrows and protocol reserves MUST have strictly increased
        assert!(borrows_after > borrows_before, 1);
        assert!(reserves_after > reserves_before, 2);

        test_coins::burn(borrowed);
    }

    // =========================================================================
    // 9. Hot Potato Flash Loan: Success Case
    // =========================================================================
    #[test(framework = @0x1, admin = @hydra_lend, alice = @0x11, bob = @0x12)]
    fun test_hot_potato_flash_loan_success(framework: &signer, admin: &signer, alice: &signer, bob: &signer) {
        setup(framework, admin, alice, bob);

        // Supply 50,000 USDC to pool
        let supply_coin = test_coins::mint<TestUSDC>(50000000000);
        lending_market::supply<TestUSDC>(alice, supply_coin);

        let pool_cash_before = lending_market::get_pool_cash<TestUSDC>();

        // Flash borrow 10,000 USDC (fee is 9 bps = 9 USDC)
        let (flash_funds, receipt) = lending_market::flash_borrow<TestUSDC>(10000000000);
        assert!(coin::value(&flash_funds) == 10000000000, 1);
        assert!(hot_potato::borrow_amount(&receipt) == 10000000000, 2);
        assert!(hot_potato::fee_amount(&receipt) == 9000000, 3); // 9 USDC fee (6 decimals)

        // Mock arbitrage profit: borrower merges repayment + fee
        let fee_coin = test_coins::mint<TestUSDC>(9000000);
        coin::merge(&mut flash_funds, fee_coin);

        // Repay flash loan, destroying Hot Potato receipt
        lending_market::repay_flash_loan<TestUSDC>(flash_funds, receipt);

        // Pool cash must now reflect the added fee revenue
        let pool_cash_after = lending_market::get_pool_cash<TestUSDC>();
        assert!(pool_cash_after == pool_cash_before + 9000000, 4);
        assert!(lending_market::get_pool_reserves<TestUSDC>() == 9000000, 5);
    }

    // =========================================================================
    // 10. Hot Potato Flash Loan: Repayment Underflow Rejection
    // =========================================================================
    #[test(framework = @0x1, admin = @hydra_lend, alice = @0x11, bob = @0x12)]
    #[expected_failure(abort_code = 0x10faa, location = hydra_lend::lending_market)]
    fun test_hot_potato_insufficient_repay_fails(framework: &signer, admin: &signer, alice: &signer, bob: &signer) {
        setup(framework, admin, alice, bob);

        // Supply 50,000 USDC
        let supply_coin = test_coins::mint<TestUSDC>(50000000000);
        lending_market::supply<TestUSDC>(alice, supply_coin);

        let (flash_funds, receipt) = lending_market::flash_borrow<TestUSDC>(10000000000);

        // Attempting to repay WITHOUT the 9 bps protocol fee -> MUST ABORT
        lending_market::repay_flash_loan<TestUSDC>(flash_funds, receipt);
    }

    // =========================================================================
    // 11. Liquidation of Underwater Borrow Position
    // =========================================================================
    #[test(framework = @0x1, admin = @hydra_lend, alice = @0x11, bob = @0x12)]
    fun test_liquidation_flow(framework: &signer, admin: &signer, alice: &signer, bob: &signer) {
        setup(framework, admin, alice, bob);

        // 1. Alice supplies 20,000 USDC
        let supply_coin = test_coins::mint<TestUSDC>(20000000000);
        lending_market::supply<TestUSDC>(alice, supply_coin);

        // 2. Bob deposits 100 APT ($1,000 USD) and borrows 700 USDC (max 70% LTV)
        let bob_apt = test_coins::mint<TestAPT>(10000000000);
        lending_market::deposit_collateral<TestAPT>(bob, bob_apt);
        let borrowed = lending_market::borrow<TestUSDC, TestAPT>(bob, 700000000);

        let bob_addr = signer::address_of(bob);

        // 3. Market price of APT crashes from $10.00 to $8.00!
        // Bob's 100 APT collateral is now worth $800.
        // Liquidation Threshold at 80% = $640.
        // Debt = $700.
        // Health Factor = 640 / 700 = 0.9142 (< 1.0) -> Position is underwater!
        oracle::set_price<TestAPT>(admin, 800000000, 8); // $8.00

        let hf_crash = lending_market::calculate_health_factor<TestAPT, TestUSDC>(bob_addr);
        assert!(hf_crash < 10000, 1); // HF < 1.0

        // 4. Liquidator Alice repays 50% close factor = 350 USDC
        let repay_coin = test_coins::mint<TestUSDC>(350000000);
        let seized_apt = lending_market::liquidate<TestUSDC, TestAPT>(alice, bob_addr, repay_coin);

        // Liquidator receives: $350 * 105% (5% bonus) = $367.50 USD in APT
        // At $8.00/APT, $367.50 / $8.00 = 45.9375 APT
        let seized_amount = coin::value(&seized_apt);
        assert!(seized_amount > 4500000000, 2); // > 45 APT seized

        // Bob's debt reduced to 350 USDC
        assert!(lending_market::get_user_borrow<TestUSDC>(bob_addr) == 350000000, 3);

        test_coins::burn(borrowed);
        test_coins::burn(seized_apt);
    }

    // =========================================================================
    // 12. Liquidation Fails If Position Healthy
    // =========================================================================
    #[test(framework = @0x1, admin = @hydra_lend, alice = @0x11, bob = @0x12)]
    #[expected_failure(abort_code = 0x30fa8, location = hydra_lend::lending_market)]
    fun test_liquidation_fails_if_healthy(framework: &signer, admin: &signer, alice: &signer, bob: &signer) {
        setup(framework, admin, alice, bob);

        let supply_coin = test_coins::mint<TestUSDC>(20000000000);
        lending_market::supply<TestUSDC>(alice, supply_coin);

        // Bob deposits 100 APT ($1000) and borrows only 300 USDC (HF ~ 2.66)
        let bob_apt = test_coins::mint<TestAPT>(10000000000);
        lending_market::deposit_collateral<TestAPT>(bob, bob_apt);
        let borrowed = lending_market::borrow<TestUSDC, TestAPT>(bob, 300000000);

        let bob_addr = signer::address_of(bob);
        let repay_coin = test_coins::mint<TestUSDC>(100000000);

        // Attempting to liquidate a healthy position -> MUST ABORT
        let seized = lending_market::liquidate<TestUSDC, TestAPT>(alice, bob_addr, repay_coin);

        test_coins::burn(borrowed);
        test_coins::burn(seized);
    }

    // =========================================================================
    // 13. Liquidation Fails When Exceeding 50% Close Factor
    // =========================================================================
    #[test(framework = @0x1, admin = @hydra_lend, alice = @0x11, bob = @0x12)]
    #[expected_failure(abort_code = 0x10fa9, location = hydra_lend::lending_market)]
    fun test_liquidation_fails_exceeding_close_factor(framework: &signer, admin: &signer, alice: &signer, bob: &signer) {
        setup(framework, admin, alice, bob);

        let supply_coin = test_coins::mint<TestUSDC>(20000000000);
        lending_market::supply<TestUSDC>(alice, supply_coin);

        // Bob deposits 100 APT and borrows 700 USDC
        let bob_apt = test_coins::mint<TestAPT>(10000000000);
        lending_market::deposit_collateral<TestAPT>(bob, bob_apt);
        let borrowed = lending_market::borrow<TestUSDC, TestAPT>(bob, 700000000);

        let bob_addr = signer::address_of(bob);

        // Price crashes to $8.00
        oracle::set_price<TestAPT>(admin, 800000000, 8);

        // Liquidator attempts to repay 80% (560 USDC) when max close factor is 50% (350 USDC) -> MUST ABORT
        let repay_coin = test_coins::mint<TestUSDC>(560000000);
        let seized = lending_market::liquidate<TestUSDC, TestAPT>(alice, bob_addr, repay_coin);

        test_coins::burn(borrowed);
        test_coins::burn(seized);
    }

    // =========================================================================
    // 14. Formal Solvency Invariant Audit
    // =========================================================================
    #[test(framework = @0x1, admin = @hydra_lend, alice = @0x11, bob = @0x12)]
    fun test_solvency_invariant_audit(framework: &signer, admin: &signer, alice: &signer, bob: &signer) {
        setup(framework, admin, alice, bob);

        // Invariant: For any pool, Total Pool Value = Cash + Total Borrows - Reserves
        // Supplier Share Valuation matches the underlying claims
        let supply_coin = test_coins::mint<TestUSDC>(50000000000); // 50k USDC
        lending_market::supply<TestUSDC>(alice, supply_coin);

        let bob_apt = test_coins::mint<TestAPT>(500000000000); // 5,000 APT ($50,000 USD value)
        lending_market::deposit_collateral<TestAPT>(bob, bob_apt);
        let borrowed = lending_market::borrow<TestUSDC, TestAPT>(bob, 20000000000); // 20,000 USDC ($20,000 <= $35,000 max capacity)

        let cash = lending_market::get_pool_cash<TestUSDC>();
        let borrows = lending_market::get_pool_total_borrows<TestUSDC>();
        let reserves = lending_market::get_pool_reserves<TestUSDC>();

        // Cash (30k) + Borrows (20k) - Reserves (0) = 50k
        assert!(cash + borrows - reserves == 50000000000, 1);

        test_coins::burn(borrowed);
    }
}
