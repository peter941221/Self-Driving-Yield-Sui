# Aftermath Perps PoC (Sui Testnet)

This PoC proves we can build and execute an on-chain Perps transaction (create perps account, deposit collateral, open + close a position) using Aftermath's SDK on **Sui testnet**.

## What It Does

- Creates a fresh ephemeral keypair (no secrets stored on disk)
- Requests testnet SUI from faucet (for gas + SUI collateral)
- Uses `aftermath-ts-sdk` (network `TESTNET`)
- Creates a Perps account collateralized by `0x2::sui::SUI`
- Deposits a small amount of SUI as collateral
- Places a tiny market **short** order on the first available market
- Closes the position with a reduce-only market order

## Run

```bash
cd poc/aftermath-perps
pnpm install
pnpm run poc
```

### Optional: Use Your Own Funded Key (Skip Faucet)

If the public testnet faucet is rate-limiting, you can provide a funded testnet key:

```bash
set SUI_SECRET_KEY=suiprivkey1...
pnpm run poc
```

## Notes

- This uses **testnet** only.
- Faucet rate limiting is common; the script uses exponential backoff.
