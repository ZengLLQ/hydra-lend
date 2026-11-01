/// Module: hydra_lend::oracle
/// Precision price oracle module for multi-asset collateral and borrow valuation.
/// All asset valuations are normalized to 8-decimal USD.
module hydra_lend::oracle {
    use std::error;
    use std::signer;
    use aptos_framework::timestamp;

    // --- Error Codes ---
    const ENOT_AUTHORIZED: u64 = 3001;
    const EPRICE_FEED_NOT_FOUND: u64 = 3002;
    const EINVALID_PRICE: u64 = 3003;
    const EPRICE_STALE: u64 = 3004;

    // --- Constants ---
    const USD_DECIMALS: u8 = 8;
    const USD_DECIMAL_FACTOR: u64 = 100000000; // 10^8
    const MAX_PRICE_STALENESS_SECONDS: u64 = 86400; // 24 hours max staleness

    /// On-chain price feed record for a specific asset
    struct PriceFeed<phantom CoinType> has key {
        /// Price in USD with 8 decimals (e.g. 1 APT = $10.50 -> 1,050,000,000)
        price_usd_8dec: u64,
        /// Native asset decimals (e.g. 8 for APT, 6 for USDC, 8 for WBTC)
        asset_decimals: u8,
        /// Timestamp of last oracle price update
        last_update_ts: u64,
    }

    /// Global oracle administrator configuration
    struct OracleConfig has key {
        admin: address,
    }

    /// Initialize oracle admin configuration
    public fun initialize(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        assert!(!exists<OracleConfig>(admin_addr), error::already_exists(1));
        move_to(admin, OracleConfig { admin: admin_addr });
    }

    /// Set or update the price feed for a coin type (Admin only)
    public fun set_price<CoinType>(
        admin: &signer,
        price_usd_8dec: u64,
        asset_decimals: u8
    ) acquires OracleConfig, PriceFeed {
        let admin_addr = signer::address_of(admin);
        let config = borrow_global<OracleConfig>(@hydra_lend);
        assert!(config.admin == admin_addr, error::permission_denied(ENOT_AUTHORIZED));
        assert!(price_usd_8dec > 0, error::invalid_argument(EINVALID_PRICE));

        let now = timestamp::now_seconds();

        if (!exists<PriceFeed<CoinType>>(@hydra_lend)) {
            move_to(admin, PriceFeed<CoinType> {
                price_usd_8dec,
                asset_decimals,
                last_update_ts: now,
            });
        } else {
            let feed = borrow_global_mut<PriceFeed<CoinType>>(@hydra_lend);
            feed.price_usd_8dec = price_usd_8dec;
            feed.asset_decimals = asset_decimals;
            feed.last_update_ts = now;
        };
    }

    /// Get current price of an asset in 8-decimal USD
    public fun get_price<CoinType>(): (u64, u8) acquires PriceFeed {
        assert!(exists<PriceFeed<CoinType>>(@hydra_lend), error::not_found(EPRICE_FEED_NOT_FOUND));
        let feed = borrow_global<PriceFeed<CoinType>>(@hydra_lend);
        (feed.price_usd_8dec, feed.asset_decimals)
    }

    /// Calculates normalized 8-decimal USD value of a given token amount:
    /// value_usd = (amount * price_usd_8dec) / 10^asset_decimals
    public fun calculate_value_usd<CoinType>(amount: u64): u64 acquires PriceFeed {
        if (amount == 0) {
            return 0
        };
        let (price, decimals) = get_price<CoinType>();
        let scale_factor = 1u128;
        let d = decimals;
        while (d > 0) {
            scale_factor = scale_factor * 10;
            d = d - 1;
        };
        let val = ((amount as u128) * (price as u128)) / scale_factor;
        (val as u64)
    }

    /// Converts an 8-decimal USD value into the corresponding token amount:
    /// token_amount = (value_usd * 10^asset_decimals) / price_usd_8dec
    public fun calculate_amount_from_usd<CoinType>(value_usd: u64): u64 acquires PriceFeed {
        if (value_usd == 0) {
            return 0
        };
        let (price, decimals) = get_price<CoinType>();
        assert!(price > 0, error::invalid_argument(EINVALID_PRICE));
        let scale_factor = 1u128;
        let d = decimals;
        while (d > 0) {
            scale_factor = scale_factor * 10;
            d = d - 1;
        };
        let amount = ((value_usd as u128) * scale_factor) / (price as u128);
        (amount as u64)
    }
}
