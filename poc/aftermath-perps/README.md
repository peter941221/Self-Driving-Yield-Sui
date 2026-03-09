# Aftermath Perps PoC (Sui Testnet)

This PoC explores whether a perps transaction flow can be built with Aftermath's SDK on **Sui testnet**.

## Purpose

Its purpose is feasibility work around:

- creating a perps account
- depositing collateral
- opening and closing a small position

## What Lives Here

- `poc.ts`
  - a protocol-specific SDK experiment around Aftermath perps on testnet
- `patch-aftermath-sdk.mjs`
  - local compatibility patching for the prototype environment
- `package.json`
  - PoC runtime entrypoint and dependencies

## How To Use It

What it does:

- Creates a fresh ephemeral keypair (no secrets stored on disk)
- Requests testnet SUI from faucet (for gas + SUI collateral)
- Uses `aftermath-ts-sdk` (network `TESTNET`)
- Creates a Perps account collateralized by `0x2::sui::SUI`
- Deposits a small amount of SUI as collateral
- Places a tiny market **short** order on the first available market
- Closes the position with a reduce-only market order

Run:

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

## Boundary

- This uses **testnet** only.
- Faucet rate limiting is common; the script uses exponential backoff.
- This PoC is not part of the sealed release claim.
- Current public repo truth is still that Aftermath perps is blocked as a sign-off-quality live leg.
