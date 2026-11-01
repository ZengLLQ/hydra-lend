/// Module: hydra_lend::hot_potato
/// Implementation of the Move "Hot Potato" pattern for uncollateralized Flash Loans.
/// The FlashReceipt has NO ABILITIES (neither drop, copy, store, nor key).
/// It cannot be saved in storage, dropped, or ignored. It MUST be consumed by
/// the protocol within the same transaction that borrowed it.
module hydra_lend::hot_potato {
    friend hydra_lend::lending_market;

    /// The Hot Potato struct: no abilities whatsoever.
    struct FlashReceipt<phantom Asset> {
        pool_address: address,
        borrow_amount: u64,
        fee_amount: u64,
    }

    /// Internal friend-only constructor for FlashReceipt
    public(friend) fun new_receipt<Asset>(
        pool_address: address,
        borrow_amount: u64,
        fee_amount: u64
    ): FlashReceipt<Asset> {
        FlashReceipt<Asset> {
            pool_address,
            borrow_amount,
            fee_amount,
        }
    }

    /// Internal friend-only destructor for FlashReceipt
    public(friend) fun destroy_receipt<Asset>(
        receipt: FlashReceipt<Asset>
    ): (address, u64, u64) {
        let FlashReceipt { pool_address, borrow_amount, fee_amount } = receipt;
        (pool_address, borrow_amount, fee_amount)
    }

    // --- Read-only inspection functions ---
    public fun borrow_amount<Asset>(receipt: &FlashReceipt<Asset>): u64 {
        receipt.borrow_amount
    }

    public fun fee_amount<Asset>(receipt: &FlashReceipt<Asset>): u64 {
        receipt.fee_amount
    }

    public fun total_repayment_amount<Asset>(receipt: &FlashReceipt<Asset>): u64 {
        receipt.borrow_amount + receipt.fee_amount
    }
}
