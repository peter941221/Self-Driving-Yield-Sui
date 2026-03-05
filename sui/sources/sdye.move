module self_driving_yield::sdye;

use sui::coin;

/// SDYE (Self-Driving Yield Engine) share token type.
public struct SDYE has drop {}

#[allow(deprecated_usage)]
fun init(witness: SDYE, ctx: &mut TxContext) {
    let (treasury, meta) = coin::create_currency(
        witness,
        9,
        b"SDYE",
        b"Self-Driving Yield Engine",
        b"SDYE share token for the Self-Driving Yield Engine vault.",
        option::none(),
        ctx,
    );
    transfer::public_freeze_object(meta);
    transfer::public_transfer(treasury, tx_context::sender(ctx));
}

public(package) fun mint_shares(
    treasury: &mut coin::TreasuryCap<SDYE>,
    amount: u64,
    ctx: &mut TxContext,
): coin::Coin<SDYE> {
    coin::mint(treasury, amount, ctx)
}

#[test]
fun init_registers_currency_in_tests() {
    let mut ctx = tx_context::dummy();
    init(SDYE {}, &mut ctx);
}
