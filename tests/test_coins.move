#[test_only]
module hydra_lend::test_coins {
    use std::string;
    use aptos_framework::coin::{Self, Coin, MintCapability, BurnCapability};

    struct TestAPT {}
    struct TestUSDC {}
    struct TestWBTC {}

    struct Caps<phantom CoinType> has key {
        mint_cap: MintCapability<CoinType>,
        burn_cap: BurnCapability<CoinType>,
    }

    public fun initialize_coin<CoinType>(
        admin: &signer,
        name: vector<u8>,
        symbol: vector<u8>,
        decimals: u8
    ) {
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<CoinType>(
            admin,
            string::utf8(name),
            string::utf8(symbol),
            decimals,
            true,
        );
        coin::destroy_freeze_cap(freeze_cap);
        move_to(admin, Caps<CoinType> { mint_cap, burn_cap });
    }

    public fun mint<CoinType>(amount: u64): Coin<CoinType> acquires Caps {
        let caps = borrow_global<Caps<CoinType>>(@hydra_lend);
        coin::mint(amount, &caps.mint_cap)
    }

    public fun burn<CoinType>(c: Coin<CoinType>) acquires Caps {
        let caps = borrow_global<Caps<CoinType>>(@hydra_lend);
        coin::burn(c, &caps.burn_cap);
    }
}
