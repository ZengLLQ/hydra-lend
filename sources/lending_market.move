/// Module: hydra_lend::lending_market
/// Core protocol implementation of HydraLend:
/// Multi-Asset Isolated Lending, Dynamic Jump Rate Model, Cross-Collateral Risk Engine,
/// Close-Factor Liquidations, and Hot-Potato Uncollateralized Flash Loans.
module hydra_lend::lending_market {
    use std::error;
    use std::signer;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;
    use hydra_lend::math;
    use hydra_lend::rate_model::{Self, InterestRateConfig};
    use hydra_lend::oracle;
    use hydra_lend::hot_potato::{Self, FlashReceipt};

    // --- Error Codes ---
    const ENOT_AUTHORIZED: u64 = 4001;
    const EPOOL_ALREADY_EXISTS: u64 = 4002;
    const EPOOL_NOT_FOUND: u64 = 4003;
    const EPOOL_PAUSED: u64 = 4004;
    const EZERO_AMOUNT: u64 = 4005;
    const EINSUFFICIENT_LIQUIDITY: u64 = 4006;
    const EINSUFFICIENT_COLLATERAL: u64 = 4007;
    const EPOSITION_HEALTHY: u64 = 4008;
    const ECLOSE_FACTOR_EXCEEDED: u64 = 4009;
    const EFLASH_REPAYMENT_INSUFFICIENT: u64 = 4010;
    const EFLASH_INVALID_POOL: u64 = 4011;
    const EREDUNDANT_REPAYMENT: u64 = 4012;
    const EUSER_COLLATERAL_NOT_FOUND: u64 = 4013;
    const EUSER_BORROW_NOT_FOUND: u64 = 4014;

    // --- Constants ---
    /// Maximum close factor for liquidations: 50.0% (5,000 bps)
    const MAX_CLOSE_FACTOR_BPS: u64 = 5000;
    /// Minimum health factor for solvent position: 1.0 (10,000 bps)
    const MIN_HEALTH_FACTOR_BPS: u64 = 10000;

    /// Pool governance capability
    struct AdminCap has key {
        admin: address,
    }

    /// Isolated lending pool state for a specific asset type
    struct LendingPool<phantom Asset> has key {
        /// Cash vault held on-chain
        cash: Coin<Asset>,
        /// Total borrowed principal plus accrued interest
        total_borrows: u64,
        /// Total supply shares minted to liquidity providers
        total_supply_shares: u64,
        /// Protocol insurance reserve cut
        reserve_amount: u64,
        /// Global cumulative borrow index (WAD scaling: 10^18)
        borrow_index: u128,
        /// Global cumulative supply index (WAD scaling: 10^18)
        supply_index: u128,
        /// Timestamp of last interest accrual update
        last_accrual_ts: u64,
        /// Dynamic Jump Rate model parameters
        rate_config: InterestRateConfig,
        /// Maximum Loan-To-Value ratio for borrowing (bps, e.g. 7500 = 75%)
        ltv_bps: u64,
        /// Liquidation threshold (bps, e.g. 8000 = 80%)
        liquidation_threshold_bps: u64,
        /// Liquidation incentive bonus paid to liquidator (bps, e.g. 500 = 5%)
        liquidation_bonus_bps: u64,
        /// Flash loan fee (bps, e.g. 9 = 0.09%)
        flash_loan_fee_bps: u64,
        /// Emergency pause flag
        is_paused: bool,
    }

    /// User's deposited collateral for a specific asset
    struct UserCollateral<phantom Asset> has key {
        amount: u64,
    }

    /// User's active borrow debt position for a specific asset
    struct UserBorrow<phantom Asset> has key {
        borrow_amount: u64,
        borrow_index_snapshot: u128,
    }

    /// User's supply deposit shares for a specific asset
    struct UserSupply<phantom Asset> has key {
        shares: u64,
    }

    // =========================================================================
    // INITIALIZATION & POOL CREATION
    // =========================================================================

    /// Initialize admin capability for protocol deployer
    public fun initialize_admin(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<AdminCap>(admin_addr), error::already_exists(1));
        move_to(admin, AdminCap { admin: admin_addr });
    }

    /// Create and initialize an isolated lending market pool for an asset type
    public fun create_pool<Asset>(
        admin: &signer,
        rate_config: InterestRateConfig,
        ltv_bps: u64,
        liquidation_threshold_bps: u64,
        liquidation_bonus_bps: u64,
        flash_loan_fee_bps: u64
    ) acquires AdminCap {
        let admin_addr = signer::address_of(admin);
        let cap = borrow_global<AdminCap>(@hydra_lend);
        assert!(cap.admin == admin_addr, error::permission_denied(ENOT_AUTHORIZED));
        assert!(!exists<LendingPool<Asset>>(@hydra_lend), error::already_exists(EPOOL_ALREADY_EXISTS));
        assert!(ltv_bps < liquidation_threshold_bps, error::invalid_argument(1));
        assert!(liquidation_threshold_bps <= math::bps_base(), error::invalid_argument(2));

        let now = timestamp::now_seconds();

        move_to(admin, LendingPool<Asset> {
            cash: coin::zero<Asset>(),
            total_borrows: 0,
            total_supply_shares: 0,
            reserve_amount: 0,
            borrow_index: math::wad(),
            supply_index: math::wad(),
            last_accrual_ts: now,
            rate_config,
            ltv_bps,
            liquidation_threshold_bps,
            liquidation_bonus_bps,
            flash_loan_fee_bps,
            is_paused: false,
        });
    }

    // =========================================================================
    // INTEREST RATE ACCRUAL
    // =========================================================================

    /// Accrue interest on the lending pool up to current block timestamp
    public fun accrue_interest<Asset>() acquires LendingPool {
        assert!(exists<LendingPool<Asset>>(@hydra_lend), error::not_found(EPOOL_NOT_FOUND));
        let pool = borrow_global_mut<LendingPool<Asset>>(@hydra_lend);
        let now = timestamp::now_seconds();
        let delta_t = if (now > pool.last_accrual_ts) { now - pool.last_accrual_ts } else { 0 };

        if (delta_t == 0 || pool.total_borrows == 0) {
            pool.last_accrual_ts = now;
            return
        };

        let cash_val = coin::value(&pool.cash);
        let borrow_rate_bps = rate_model::calculate_borrow_rate(
            &pool.rate_config,
            cash_val,
            pool.total_borrows,
            pool.reserve_amount
        );

        let rate_per_sec = rate_model::rate_per_second_wad(borrow_rate_bps);
        let interest_factor_wad = rate_per_sec * (delta_t as u128);

        // Simple linear interest accrual: delta_borrows = total_borrows * interest_factor
        let delta_borrows_u128 = ((pool.total_borrows as u128) * interest_factor_wad) / math::wad();
        let delta_borrows = (delta_borrows_u128 as u64);

        if (delta_borrows > 0) {
            let reserve_cut = math::mul_bps(delta_borrows, rate_model::reserve_factor_bps(&pool.rate_config));
            pool.total_borrows = pool.total_borrows + delta_borrows;
            pool.reserve_amount = pool.reserve_amount + reserve_cut;

            // Update cumulative borrow index
            let delta_index = (pool.borrow_index * interest_factor_wad) / math::wad();
            pool.borrow_index = pool.borrow_index + delta_index;
        };

        pool.last_accrual_ts = now;
    }

    // =========================================================================
    // LIQUIDITY SUPPLY & WITHDRAWAL
    // =========================================================================

    /// Supply liquidity to pool and receive proportional supply shares
    public fun supply<Asset>(
        account: &signer,
        deposit_coin: Coin<Asset>
    ) acquires LendingPool, UserSupply {
        accrue_interest<Asset>();
        let deposit_amount = coin::value(&deposit_coin);
        assert!(deposit_amount > 0, error::invalid_argument(EZERO_AMOUNT));

        let pool = borrow_global_mut<LendingPool<Asset>>(@hydra_lend);
        assert!(!pool.is_paused, error::invalid_state(EPOOL_PAUSED));

        let user_addr = signer::address_of(account);

        // Calculate supply shares: shares = amount * total_shares / total_liquidity
        let cash_val = coin::value(&pool.cash);
        let total_pool_value = cash_val + pool.total_borrows - pool.reserve_amount;

        let shares_to_mint = if (pool.total_supply_shares == 0 || total_pool_value == 0) {
            deposit_amount
        } else {
            (((deposit_amount as u128) * (pool.total_supply_shares as u128) / (total_pool_value as u128)) as u64)
        };

        // Deposit cash into pool
        coin::merge(&mut pool.cash, deposit_coin);
        pool.total_supply_shares = pool.total_supply_shares + shares_to_mint;

        // Record or increment user shares
        if (!exists<UserSupply<Asset>>(user_addr)) {
            move_to(account, UserSupply<Asset> { shares: shares_to_mint });
        } else {
            let user_sup = borrow_global_mut<UserSupply<Asset>>(user_addr);
            user_sup.shares = user_sup.shares + shares_to_mint;
        };
    }

    /// Redeem supply shares for underlying assets
    public fun withdraw_supply<Asset>(
        account: &signer,
        shares: u64
    ): Coin<Asset> acquires LendingPool, UserSupply {
        accrue_interest<Asset>();
        assert!(shares > 0, error::invalid_argument(EZERO_AMOUNT));

        let user_addr = signer::address_of(account);
        assert!(exists<UserSupply<Asset>>(user_addr), error::not_found(1));

        let user_sup = borrow_global_mut<UserSupply<Asset>>(user_addr);
        assert!(user_sup.shares >= shares, error::invalid_argument(2));

        let pool = borrow_global_mut<LendingPool<Asset>>(@hydra_lend);
        assert!(!pool.is_paused, error::invalid_state(EPOOL_PAUSED));

        let cash_val = coin::value(&pool.cash);
        let total_pool_value = cash_val + pool.total_borrows - pool.reserve_amount;
        let amount_out = (((shares as u128) * (total_pool_value as u128) / (pool.total_supply_shares as u128)) as u64);

        assert!(cash_val >= amount_out, error::invalid_state(EINSUFFICIENT_LIQUIDITY));

        user_sup.shares = user_sup.shares - shares;
        pool.total_supply_shares = pool.total_supply_shares - shares;

        coin::extract(&mut pool.cash, amount_out)
    }

    // =========================================================================
    // COLLATERAL MANAGEMENT
    // =========================================================================

    /// Deposit asset as loan collateral
    public fun deposit_collateral<Asset>(
        account: &signer,
        collateral_coin: Coin<Asset>
    ) acquires UserCollateral, LendingPool {
        let amount = coin::value(&collateral_coin);
        assert!(amount > 0, error::invalid_argument(EZERO_AMOUNT));

        let user_addr = signer::address_of(account);
        if (!exists<UserCollateral<Asset>>(user_addr)) {
            move_to(account, UserCollateral<Asset> { amount });
        } else {
            let col = borrow_global_mut<UserCollateral<Asset>>(user_addr);
            col.amount = col.amount + amount;
        };

        // Transfer collateral coin to pool
        let pool = borrow_global_mut<LendingPool<Asset>>(@hydra_lend);
        coin::merge(&mut pool.cash, collateral_coin);
    }

    /// Withdraw collateral, verifying that position remains solvent
    public fun withdraw_collateral<CollateralAsset, DebtAsset>(
        account: &signer,
        withdraw_amount: u64
    ): Coin<CollateralAsset> acquires LendingPool, UserCollateral, UserBorrow {
        accrue_interest<DebtAsset>();
        assert!(withdraw_amount > 0, error::invalid_argument(EZERO_AMOUNT));

        let user_addr = signer::address_of(account);
        assert!(exists<UserCollateral<CollateralAsset>>(user_addr), error::not_found(EUSER_COLLATERAL_NOT_FOUND));

        let col = borrow_global_mut<UserCollateral<CollateralAsset>>(user_addr);
        assert!(col.amount >= withdraw_amount, error::invalid_argument(EINSUFFICIENT_COLLATERAL));

        // Deduct collateral temporarily to check solvency
        col.amount = col.amount - withdraw_amount;

        // Verify remaining collateral covers outstanding debt
        let hf = calculate_health_factor<CollateralAsset, DebtAsset>(user_addr);
        assert!(hf >= MIN_HEALTH_FACTOR_BPS, error::invalid_state(EINSUFFICIENT_COLLATERAL));

        let pool = borrow_global_mut<LendingPool<CollateralAsset>>(@hydra_lend);
        assert!(coin::value(&pool.cash) >= withdraw_amount, error::invalid_state(EINSUFFICIENT_LIQUIDITY));

        coin::extract(&mut pool.cash, withdraw_amount)
    }

    // =========================================================================
    // BORROWING & REPAYMENT
    // =========================================================================

    /// Borrow asset against deposited collateral
    public fun borrow<DebtAsset, CollateralAsset>(
        account: &signer,
        borrow_amount: u64
    ): Coin<DebtAsset> acquires LendingPool, UserCollateral, UserBorrow {
        accrue_interest<DebtAsset>();
        assert!(borrow_amount > 0, error::invalid_argument(EZERO_AMOUNT));

        let user_addr = signer::address_of(account);
        assert!(exists<UserCollateral<CollateralAsset>>(user_addr), error::not_found(EUSER_COLLATERAL_NOT_FOUND));

        // 1. Check pool availability and fetch current borrow index
        let current_borrow_index = {
            let debt_pool = borrow_global<LendingPool<DebtAsset>>(@hydra_lend);
            assert!(!debt_pool.is_paused, error::invalid_state(EPOOL_PAUSED));
            assert!(coin::value(&debt_pool.cash) >= borrow_amount, error::invalid_state(EINSUFFICIENT_LIQUIDITY));
            debt_pool.borrow_index
        };

        // 2. Update or initialize borrower record
        if (!exists<UserBorrow<DebtAsset>>(user_addr)) {
            move_to(account, UserBorrow<DebtAsset> {
                borrow_amount,
                borrow_index_snapshot: current_borrow_index,
            });
        } else {
            let u_borrow = borrow_global_mut<UserBorrow<DebtAsset>>(user_addr);
            let compounded_debt = get_compounded_debt_internal(u_borrow.borrow_amount, u_borrow.borrow_index_snapshot, current_borrow_index);
            u_borrow.borrow_amount = compounded_debt + borrow_amount;
            u_borrow.borrow_index_snapshot = current_borrow_index;
        };

        // 3. Check health factor with LTV
        let col_amount = borrow_global<UserCollateral<CollateralAsset>>(user_addr).amount;
        let col_value_usd = oracle::calculate_value_usd<CollateralAsset>(col_amount);
        let ltv_bps = borrow_global<LendingPool<CollateralAsset>>(@hydra_lend).ltv_bps;
        let max_borrow_usd = math::mul_bps(col_value_usd, ltv_bps);

        let total_user_debt = borrow_global<UserBorrow<DebtAsset>>(user_addr).borrow_amount;
        let debt_value_usd = oracle::calculate_value_usd<DebtAsset>(total_user_debt);
        assert!(debt_value_usd <= max_borrow_usd, error::invalid_state(EINSUFFICIENT_COLLATERAL));

        // 4. Extract and disburse borrowed coins
        let debt_pool_mut = borrow_global_mut<LendingPool<DebtAsset>>(@hydra_lend);
        debt_pool_mut.total_borrows = debt_pool_mut.total_borrows + borrow_amount;
        coin::extract(&mut debt_pool_mut.cash, borrow_amount)
    }

    /// Repay outstanding borrow debt
    public fun repay<DebtAsset>(
        account: &signer,
        payment_coin: Coin<DebtAsset>
    ): Coin<DebtAsset> acquires LendingPool, UserBorrow {
        accrue_interest<DebtAsset>();
        let payment_val = coin::value(&payment_coin);
        assert!(payment_val > 0, error::invalid_argument(EZERO_AMOUNT));

        let user_addr = signer::address_of(account);
        assert!(exists<UserBorrow<DebtAsset>>(user_addr), error::not_found(EUSER_BORROW_NOT_FOUND));

        let debt_pool = borrow_global_mut<LendingPool<DebtAsset>>(@hydra_lend);
        let u_borrow = borrow_global_mut<UserBorrow<DebtAsset>>(user_addr);

        let compounded_debt = get_compounded_debt_internal(
            u_borrow.borrow_amount,
            u_borrow.borrow_index_snapshot,
            debt_pool.borrow_index
        );

        let actual_repay = math::min(payment_val, compounded_debt);
        let remaining_debt = compounded_debt - actual_repay;

        u_borrow.borrow_amount = remaining_debt;
        u_borrow.borrow_index_snapshot = debt_pool.borrow_index;

        // Deduct from pool's total borrows
        let borrow_reduction = math::min(actual_repay, debt_pool.total_borrows);
        debt_pool.total_borrows = debt_pool.total_borrows - borrow_reduction;

        // Split payment into accepted payment and refund excess
        let accepted_coin = coin::extract(&mut payment_coin, actual_repay);
        coin::merge(&mut debt_pool.cash, accepted_coin);

        // Return excess payment coin to caller
        payment_coin
    }

    // =========================================================================
    // LIQUIDATION ENGINE
    // =========================================================================

    /// Liquidate an undercollateralized borrow position (Health Factor < 1.0)
    /// Enforces close factor <= 50% and delivers collateral with bonus to liquidator.
    public fun liquidate<DebtAsset, CollateralAsset>(
        _liquidator: &signer,
        borrower: address,
        debt_repayment: Coin<DebtAsset>
    ): Coin<CollateralAsset> acquires LendingPool, UserCollateral, UserBorrow {
        accrue_interest<DebtAsset>();
        accrue_interest<CollateralAsset>();

        let repay_amount = coin::value(&debt_repayment);
        assert!(repay_amount > 0, error::invalid_argument(EZERO_AMOUNT));

        // 1. Position Health Check
        let hf = calculate_health_factor<CollateralAsset, DebtAsset>(borrower);
        assert!(hf < MIN_HEALTH_FACTOR_BPS, error::invalid_state(EPOSITION_HEALTHY));

        // 2. Fetch current borrow index and compound debt
        let current_borrow_index = borrow_global<LendingPool<DebtAsset>>(@hydra_lend).borrow_index;
        let (compounded_debt, max_close_amount) = {
            let u_borrow = borrow_global<UserBorrow<DebtAsset>>(borrower);
            let debt = get_compounded_debt_internal(
                u_borrow.borrow_amount,
                u_borrow.borrow_index_snapshot,
                current_borrow_index
            );
            let max_close = math::mul_bps(debt, MAX_CLOSE_FACTOR_BPS);
            (debt, max_close)
        };
        assert!(repay_amount <= max_close_amount, error::invalid_argument(ECLOSE_FACTOR_EXCEEDED));

        // 3. Calculate collateral seized = repay_usd * (1 + bonus) converted to CollateralAsset
        let liquidation_bonus_bps = borrow_global<LendingPool<CollateralAsset>>(@hydra_lend).liquidation_bonus_bps;
        let repay_val_usd = oracle::calculate_value_usd<DebtAsset>(repay_amount);
        let bonus_factor = math::bps_base() + liquidation_bonus_bps;
        let seized_val_usd = math::mul_bps(repay_val_usd, bonus_factor);
        let collateral_to_seize = oracle::calculate_amount_from_usd<CollateralAsset>(seized_val_usd);

        // 4. Update borrower collateral and debt
        let actual_col_seized = {
            let u_col = borrow_global_mut<UserCollateral<CollateralAsset>>(borrower);
            let seized = math::min(collateral_to_seize, u_col.amount);
            u_col.amount = u_col.amount - seized;
            seized
        };

        {
            let u_borrow = borrow_global_mut<UserBorrow<DebtAsset>>(borrower);
            u_borrow.borrow_amount = compounded_debt - repay_amount;
            u_borrow.borrow_index_snapshot = current_borrow_index;
        };

        // 5. Deposit debt repayment into debt pool
        {
            let debt_pool = borrow_global_mut<LendingPool<DebtAsset>>(@hydra_lend);
            let pool_borrow_deduct = math::min(repay_amount, debt_pool.total_borrows);
            debt_pool.total_borrows = debt_pool.total_borrows - pool_borrow_deduct;
            coin::merge(&mut debt_pool.cash, debt_repayment);
        };

        // 6. Extract seized collateral from collateral pool cash and return to liquidator
        let col_pool_mut = borrow_global_mut<LendingPool<CollateralAsset>>(@hydra_lend);
        coin::extract(&mut col_pool_mut.cash, actual_col_seized)
    }

    // =========================================================================
    // HOT POTATO FLASH LOANS
    // =========================================================================

    /// Borrow uncollateralized flash loan, receiving funds and a Hot Potato FlashReceipt.
    /// The FlashReceipt CANNOT be dropped or saved; caller MUST invoke repay_flash_loan.
    public fun flash_borrow<Asset>(
        amount: u64
    ): (Coin<Asset>, FlashReceipt<Asset>) acquires LendingPool {
        assert!(amount > 0, error::invalid_argument(EZERO_AMOUNT));
        assert!(exists<LendingPool<Asset>>(@hydra_lend), error::not_found(EPOOL_NOT_FOUND));

        let pool = borrow_global_mut<LendingPool<Asset>>(@hydra_lend);
        assert!(!pool.is_paused, error::invalid_state(EPOOL_PAUSED));
        assert!(coin::value(&pool.cash) >= amount, error::invalid_state(EINSUFFICIENT_LIQUIDITY));

        let fee = math::mul_bps(amount, pool.flash_loan_fee_bps);
        let flash_coin = coin::extract(&mut pool.cash, amount);
        let receipt = hot_potato::new_receipt<Asset>(@hydra_lend, amount, fee);

        (flash_coin, receipt)
    }

    /// Repay flash loan and destroy the Hot Potato FlashReceipt
    public fun repay_flash_loan<Asset>(
        payment: Coin<Asset>,
        receipt: FlashReceipt<Asset>
    ) acquires LendingPool {
        let (pool_addr, borrow_amount, fee_amount) = hot_potato::destroy_receipt(receipt);
        assert!(pool_addr == @hydra_lend, error::invalid_argument(EFLASH_INVALID_POOL));

        let total_required = borrow_amount + fee_amount;
        let payment_val = coin::value(&payment);
        assert!(payment_val >= total_required, error::invalid_argument(EFLASH_REPAYMENT_INSUFFICIENT));

        let pool = borrow_global_mut<LendingPool<Asset>>(@hydra_lend);
        // Direct fee into protocol reserves
        pool.reserve_amount = pool.reserve_amount + fee_amount;
        coin::merge(&mut pool.cash, payment);
    }

    // =========================================================================
    // RISK ENGINE & VIEW FUNCTIONS
    // =========================================================================

    /// Calculate the Health Factor of a borrower position in basis points (10000 = 1.0)
    /// Health Factor = (Collateral Value * Liquidation Threshold) / Total Debt Value
    public fun calculate_health_factor<CollateralAsset, DebtAsset>(
        borrower: address
    ): u64 acquires LendingPool, UserCollateral, UserBorrow {
        if (!exists<UserBorrow<DebtAsset>>(borrower)) {
            return 999999999 // Infinite health
        };
        let u_borrow = borrow_global<UserBorrow<DebtAsset>>(borrower);
        if (u_borrow.borrow_amount == 0) {
            return 999999999
        };

        if (!exists<UserCollateral<CollateralAsset>>(borrower)) {
            return 0 // Has debt but 0 collateral
        };
        let u_col = borrow_global<UserCollateral<CollateralAsset>>(borrower);
        if (u_col.amount == 0) {
            return 0
        };

        let debt_pool = borrow_global<LendingPool<DebtAsset>>(@hydra_lend);
        let compounded_debt = get_compounded_debt_internal(
            u_borrow.borrow_amount,
            u_borrow.borrow_index_snapshot,
            debt_pool.borrow_index
        );
        let debt_val_usd = oracle::calculate_value_usd<DebtAsset>(compounded_debt);
        if (debt_val_usd == 0) {
            return 999999999
        };

        let col_val_usd = oracle::calculate_value_usd<CollateralAsset>(u_col.amount);
        let col_pool = borrow_global<LendingPool<CollateralAsset>>(@hydra_lend);
        let liq_threshold_usd = math::mul_bps(col_val_usd, col_pool.liquidation_threshold_bps);

        let hf = ((liq_threshold_usd as u128) * (math::bps_base() as u128) / (debt_val_usd as u128) as u64);
        hf
    }

    /// Internal helper calculating compounded debt based on borrow index delta
    fun get_compounded_debt_internal(
        borrow_amount: u64,
        index_snapshot: u128,
        current_index: u128
    ): u64 {
        if (borrow_amount == 0 || index_snapshot == 0 || current_index <= index_snapshot) {
            borrow_amount
        } else {
            let accrued = ((borrow_amount as u128) * current_index) / index_snapshot;
            (accrued as u64)
        }
    }

    // --- Public Getters ---
    public fun get_pool_cash<Asset>(): u64 acquires LendingPool {
        let pool = borrow_global<LendingPool<Asset>>(@hydra_lend);
        coin::value(&pool.cash)
    }

    public fun get_pool_total_borrows<Asset>(): u64 acquires LendingPool {
        borrow_global<LendingPool<Asset>>(@hydra_lend).total_borrows
    }

    public fun get_pool_reserves<Asset>(): u64 acquires LendingPool {
        borrow_global<LendingPool<Asset>>(@hydra_lend).reserve_amount
    }

    public fun get_user_collateral<Asset>(user: address): u64 acquires UserCollateral {
        if (!exists<UserCollateral<Asset>>(user)) { 0 } else { borrow_global<UserCollateral<Asset>>(user).amount }
    }

    public fun get_user_borrow<Asset>(user: address): u64 acquires UserBorrow {
        if (!exists<UserBorrow<Asset>>(user)) { 0 } else { borrow_global<UserBorrow<Asset>>(user).borrow_amount }
    }

    public fun get_user_supply_shares<Asset>(user: address): u64 acquires UserSupply {
        if (!exists<UserSupply<Asset>>(user)) { 0 } else { borrow_global<UserSupply<Asset>>(user).shares }
    }
}
