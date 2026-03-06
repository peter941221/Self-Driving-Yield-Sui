# Self-Driving Yield Engine (Sui Move)

<p align="center">
  <strong>An autonomous yield vault that hedges itself</strong>
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=rdQyEShM0vs">
    <img src="https://img.shields.io/badge/Demo-Video-red?style=for-the-badge&logo=youtube" alt="Demo Video">
  </a>
  <img src="https://img.shields.io/badge/Platform-Sui%20Move-yellow?style=for-the-badge" alt="Platform">
  <img src="https://img.shields.io/badge/Sui%20Framework-testnet%20%40%204e8aa9e-blue?style=for-the-badge" alt="Sui Framework">
  <img src="https://img.shields.io/badge/License-MIT-blue?style=for-the-badge" alt="License">
</p>

---

## What is this?

An **autonomous, non-custodial yield vault** written in **Sui Move (edition 2024)**.

Core loop:
- record price snapshots → compute **TWAP** (time-weighted average price) and a **volatility regime** (CALM/NORMAL/STORM)
- shift target allocations (yield / LP / buffer) based on regime
- process withdrawals via an on-chain queue
- pay a bounded bounty to permissionless `cycle()` callers

```
     CALM MARKET (low vol)      STORM MARKET (high vol)
     ┌───────────────┐         ┌──────────────────────┐
LP   │  ██████  Fees  │         │  ██  Reduce LP risk  │
Carry│  ███     Stable│         │  █████  Carry-first  │
     └───────────────┘         └──────────────────────┘
                     → Auto rebalance ←
```

## Repository Layout

```
sui/            # Main Sui Move package (current)
poc/            # PoCs (TypeScript / Python)
scripts/        # Local tooling (Python)
```

## Sui Framework Version (Testnet)

- `sui/Move.toml` tracks Sui framework `framework/testnet`
- the exact pinned commit is recorded in `sui/Move.lock`:
  - `rev = 4e8aa9ee8b307b294cc85baf7d08af1f432e3d93` (short: `4e8aa9e`)
- toolchain used locally: `sui 1.67.1` (build rev `4e8aa9e…`)

## Quickstart (Sui Move)

```bash
cd sui
sui move build
sui move test
```

Optional:

```bash
sui move coverage summary
```

## Architecture (Sui, high-level)

```
User (Coin<BASE>)
  -> entrypoints::Vault<BASE>      (shared object)
     -> vault::VaultState          (accounting + risk mode)
     -> oracle::OracleState        (TWAP + regime)
     -> queue::WithdrawalQueue     (requests -> ready -> claimed)
     -> adapters/* (P2)            (CLMM / lending / perps / rebalance)
```

## Status

- P1 (core modules + tests): done
- P2 (adapters: CLMM / lending / perps / rebalance): done
  - done: config wiring + adapter capability gates + Cetus CLMM wrapper (`open/add/remove/swap`)
  - done: `Vault<BASE>` rebalances LP / Yield / Hedge accounting buckets in `cycle()` and chooses PTB vs flash paths by delta size
  - done: scenario coverage for Cetus-only and full P2 strategy mix

## Legacy Solidity Prototype (BNB Chain)

This repository previously contained a Foundry-based BNB prototype. It has been moved out to keep this repo focused on Sui Move.
