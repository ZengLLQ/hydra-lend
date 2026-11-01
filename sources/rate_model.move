/// Module: hydra_lend::rate_model
/// Implementation of the piecewise-linear Jump Rate Model for utilization-based
/// variable interest rates.
module hydra_lend::rate_model {
    use std::error;
    use hydra_lend::math;

    // --- Error Codes ---
    const EINVALID_KINK: u64 = 2001;
    const EINVALID_RESERVE_FACTOR: u64 = 2002;

    /// Configuration for the 2-slope Jump Rate Model
    struct InterestRateConfig has copy, drop, store {
        /// Base APY interest rate when utilization is 0% (in bps, e.g. 200 = 2.0%)
        base_rate_bps: u64,
        /// Kink utilization threshold (in bps, e.g. 8000 = 80.0%)
        kink_utilization_bps: u64,
        /// Slope 1: Rate multiplier up to kink (in bps, e.g. 800 = 8.0%)
        slope1_bps: u64,
        /// Slope 2: Aggressive jump rate multiplier past kink (in bps, e.g. 10000 = 100.0%)
        slope2_bps: u64,
        /// Percentage of accrued interest retained as protocol insurance reserves (in bps, e.g. 1000 = 10.0%)
        reserve_factor_bps: u64,
    }

    /// Construct a new valid InterestRateConfig
    public fun new_config(
        base_rate_bps: u64,
        kink_utilization_bps: u64,
        slope1_bps: u64,
        slope2_bps: u64,
        reserve_factor_bps: u64
    ): InterestRateConfig {
        assert!(kink_utilization_bps > 0 && kink_utilization_bps < math::bps_base(), error::invalid_argument(EINVALID_KINK));
        assert!(reserve_factor_bps <= math::bps_base(), error::invalid_argument(EINVALID_RESERVE_FACTOR));
        InterestRateConfig {
            base_rate_bps,
            kink_utilization_bps,
            slope1_bps,
            slope2_bps,
            reserve_factor_bps,
        }
    }

    // --- Getters ---
    public fun base_rate_bps(config: &InterestRateConfig): u64 { config.base_rate_bps }
    public fun kink_utilization_bps(config: &InterestRateConfig): u64 { config.kink_utilization_bps }
    public fun slope1_bps(config: &InterestRateConfig): u64 { config.slope1_bps }
    public fun slope2_bps(config: &InterestRateConfig): u64 { config.slope2_bps }
    public fun reserve_factor_bps(config: &InterestRateConfig): u64 { config.reserve_factor_bps }

    /// Calculate pool utilization rate U = borrows / (cash + borrows - reserves) in bps
    public fun calculate_utilization(cash: u64, borrows: u64, reserves: u64): u64 {
        if (borrows == 0) {
            return 0
        };
        let net_liquidity = if (cash + borrows > reserves) {
            cash + borrows - reserves
        } else {
            0
        };
        if (net_liquidity == 0) {
            return math::bps_base() // 100%
        };
        let u = ((borrows as u128) * (math::bps_base() as u128) / (net_liquidity as u128) as u64);
        math::min(u, math::bps_base())
    }

    /// Calculate annual borrow interest rate in bps
    public fun calculate_borrow_rate(config: &InterestRateConfig, cash: u64, borrows: u64, reserves: u64): u64 {
        let u = calculate_utilization(cash, borrows, reserves);
        if (u <= config.kink_utilization_bps) {
            // Normal utilization: rate = base + (u / kink) * slope1
            let variable_rate = ((u as u128) * (config.slope1_bps as u128) / (config.kink_utilization_bps as u128) as u64);
            config.base_rate_bps + variable_rate
        } else {
            // Jump utilization: rate = base + slope1 + ((u - kink) / (1 - kink)) * slope2
            let excess_u = u - config.kink_utilization_bps;
            let excess_kink = math::bps_base() - config.kink_utilization_bps;
            let jump_rate = ((excess_u as u128) * (config.slope2_bps as u128) / (excess_kink as u128) as u64);
            config.base_rate_bps + config.slope1_bps + jump_rate
        }
    }

    /// Calculate annual supply interest rate in bps: supply_rate = borrow_rate * u * (1 - reserve_factor)
    public fun calculate_supply_rate(config: &InterestRateConfig, cash: u64, borrows: u64, reserves: u64): u64 {
        let u = calculate_utilization(cash, borrows, reserves);
        let borrow_rate = calculate_borrow_rate(config, cash, borrows, reserves);
        let rate_to_suppliers = math::mul_bps(borrow_rate, math::bps_base() - config.reserve_factor_bps);
        math::mul_bps(rate_to_suppliers, u)
    }

    /// Converts an annual borrow rate in bps to per-second compounding factor in WAD
    public fun rate_per_second_wad(borrow_rate_bps: u64): u128 {
        // (borrow_rate_bps * WAD) / (BPS_BASE * SECONDS_PER_YEAR)
        let num = (borrow_rate_bps as u128) * math::wad();
        let denom = (math::bps_base() as u128) * (math::seconds_per_year() as u128);
        num / denom
    }
}
