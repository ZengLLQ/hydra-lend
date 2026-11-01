/// Module: hydra_lend::math
/// Precision arithmetic utilities for fixed-point interest calculations,
/// basis-point conversions, and compounding indices.
module hydra_lend::math {
    use std::error;

    // --- Error Codes ---
    const EDIVISION_BY_ZERO: u64 = 1001;
    const EOVERFLOW: u64 = 1002;

    // --- Constants ---
    /// 18-decimal fixed point scaling (WAD)
    const WAD: u128 = 1000000000000000000;
    /// 27-decimal fixed point scaling (RAY)
    const RAY: u128 = 1000000000000000000000000000;
    /// Basis points denominator (100% = 10,000 bps)
    const BPS_BASE: u64 = 10000;
    /// Average seconds in a calendar year (365 days)
    const SECONDS_PER_YEAR: u64 = 31536000;

    // --- Public Accessor Getters ---
    public fun wad(): u128 { WAD }
    public fun ray(): u128 { RAY }
    public fun bps_base(): u64 { BPS_BASE }
    public fun seconds_per_year(): u64 { SECONDS_PER_YEAR }

    /// Multiplies an integer by a fraction represented in basis points (1 bps = 0.01%)
    public fun mul_bps(amount: u64, bps: u64): u64 {
        let product = (amount as u128) * (bps as u128);
        ((product / (BPS_BASE as u128)) as u64)
    }

    /// Divides an integer by a basis point factor
    public fun div_bps(amount: u64, bps: u64): u64 {
        assert!(bps > 0, error::invalid_argument(EDIVISION_BY_ZERO));
        let num = (amount as u128) * (BPS_BASE as u128);
        ((num / (bps as u128)) as u64)
    }

    /// Multiply two WAD numbers (18 decimals): (a * b) / 10^18
    public fun wad_mul(a: u128, b: u128): u128 {
        if (a == 0 || b == 0) {
            0
        } else {
            (a * b + (WAD / 2)) / WAD
        }
    }

    /// Divide two WAD numbers (18 decimals): (a * 10^18) / b
    public fun wad_div(a: u128, b: u128): u128 {
        assert!(b > 0, error::invalid_argument(EDIVISION_BY_ZERO));
        (a * WAD + (b / 2)) / b
    }

    /// Linear interpolation: start + (end - start) * factor / divisor
    public fun lerp(start: u64, end: u64, factor: u64, divisor: u64): u64 {
        assert!(divisor > 0, error::invalid_argument(EDIVISION_BY_ZERO));
        if (end >= start) {
            let diff = end - start;
            let delta = ((diff as u128) * (factor as u128) / (divisor as u128) as u64);
            start + delta
        } else {
            let diff = start - end;
            let delta = ((diff as u128) * (factor as u128) / (divisor as u128) as u64);
            start - delta
        }
    }

    /// Returns the minimum of two u64 numbers
    public fun min(a: u64, b: u64): u64 {
        if (a <= b) { a } else { b }
    }

    /// Returns the maximum of two u64 numbers
    public fun max(a: u64, b: u64): u64 {
        if (a >= b) { a } else { b }
    }

    /// Safe exponentiation by squaring for integers: base^exp
    public fun pow(base: u128, exp: u64): u128 {
        let res = 1u128;
        let b = base;
        let e = exp;
        while (e > 0) {
            if (e % 2 == 1) {
                res = res * b;
            };
            b = b * b;
            e = e / 2;
        };
        res
    }
}
