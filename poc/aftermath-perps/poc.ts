import { Aftermath } from "aftermath-ts-sdk";
import {
  FaucetRateLimitError,
  getFaucetHost,
  requestSuiFromFaucetV2
} from "@mysten/sui/faucet";
import { getJsonRpcFullnodeUrl, SuiJsonRpcClient } from "@mysten/sui/jsonRpc";
import { Ed25519Keypair } from "@mysten/sui/keypairs/ed25519";

const NETWORK = "testnet";
const COLLATERAL_COIN_TYPE = "0x2::sui::SUI";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

async function pollSuiBalance(client: SuiJsonRpcClient, owner: string, tries = 30) {
  for (let i = 0; i < tries; i++) {
    const bal = await client.getBalance({ owner });
    const total = BigInt(bal.totalBalance);
    if (total > 0n) return total;
    await sleep(1000);
  }
  return 0n;
}

function formatSui(mist: bigint) {
  // 1 SUI = 1e9 MIST
  const whole = mist / 1_000_000_000n;
  const frac = mist % 1_000_000_000n;
  return `${whole}.${frac.toString().padStart(9, "0")} SUI`;
}

async function main() {
  const client = new SuiJsonRpcClient({
    network: NETWORK,
    url: getJsonRpcFullnodeUrl(NETWORK)
  });

  const envSecret = process.env.SUI_SECRET_KEY?.trim();
  const keypair = envSecret ? Ed25519Keypair.fromSecretKey(envSecret) : Ed25519Keypair.generate();
  const address = keypair.getPublicKey().toSuiAddress();

  console.log("[PoC] network:", NETWORK);
  console.log("[PoC] address:", address);

  if (!envSecret) {
    console.log("[PoC] requesting faucet SUI...");
    const faucetHost = getFaucetHost(NETWORK);

    // Faucet rate limiting is common. Use exponential backoff.
    for (let attempt = 1; attempt <= 10; attempt++) {
      try {
        await requestSuiFromFaucetV2({ host: faucetHost, recipient: address });
        break;
      } catch (e: any) {
        const isRateLimit =
          e instanceof FaucetRateLimitError ||
          (typeof e?.message === "string" &&
            e.message.toLowerCase().includes("too many requests"));

        if (!isRateLimit || attempt === 10) throw e;

        const waitMs = Math.min(90_000, 3_000 * 2 ** (attempt - 1));
        console.log(
          `[PoC] faucet rate-limited (attempt ${attempt}/10). waiting ${waitMs}ms...`
        );
        await sleep(waitMs);
      }
    }
  } else {
    console.log("[PoC] SUI_SECRET_KEY detected; skipping faucet.");
  }

  const bal = await pollSuiBalance(client, address);
  if (bal === 0n) {
    throw new Error(
      "No SUI balance detected. Either wait for faucet cooldown and re-run, or set SUI_SECRET_KEY to a funded testnet account."
    );
  }
  console.log("[PoC] balance:", formatSui(bal));

  console.log("[PoC] init Aftermath SDK...");
  const af = new Aftermath("TESTNET");
  await af.init();
  const perps = af.Perpetuals();

  console.log("[PoC] ensure perps account cap exists...");
  let { accountCaps } = await perps.getOwnedAccountCaps({
    walletAddress: address,
    collateralCoinTypes: [COLLATERAL_COIN_TYPE]
  });
  let cap = accountCaps.find((c) => c.collateralCoinType === COLLATERAL_COIN_TYPE);
  if (!cap) {
    const { tx } = await perps.getCreateAccountTx({
      walletAddress: address,
      collateralCoinType: COLLATERAL_COIN_TYPE
    });

    const res = await client.signAndExecuteTransaction({
      transaction: tx,
      signer: keypair,
      options: { showEffects: true, showEvents: true },
      requestType: "WaitForLocalExecution"
    });
    console.log("[PoC] create account tx digest:", res.digest);

    // Re-fetch caps after creation
    ({ accountCaps } = await perps.getOwnedAccountCaps({
      walletAddress: address,
      collateralCoinTypes: [COLLATERAL_COIN_TYPE]
    }));
    cap = accountCaps.find((c) => c.collateralCoinType === COLLATERAL_COIN_TYPE);
    if (!cap) throw new Error("Account cap not found after creation.");
  }

  console.log("[PoC] accountCap objectId:", (cap as any).objectId ?? "(unknown)");

  console.log("[PoC] load perps account...");
  const { account } = await perps.getAccount({ accountCap: cap });

  console.log("[PoC] fetch markets for collateral:", COLLATERAL_COIN_TYPE);
  const { markets } = await perps.getAllMarkets({ collateralCoinType: COLLATERAL_COIN_TYPE });
  if (!markets || markets.length === 0) {
    throw new Error("No perps markets returned (TESTNET).");
  }

  const market =
    markets.find((m) => m.marketParams.baseAssetSymbol === "SUI") ?? markets[0];
  const marketId = market.marketId;
  console.log("[PoC] selected marketId:", marketId);

  // Deposit collateral into the perps account (leave some SUI for gas).
  // 2 SUI = 2_000_000_000 MIST
  const depositMist = 2_000_000_000n;
  console.log("[PoC] deposit collateral:", formatSui(depositMist));

  const { tx: tx1 } = await account.getDepositCollateralTx({
    depositAmount: depositMist
  });

  const depRes = await client.signAndExecuteTransaction({
    transaction: tx1,
    signer: keypair,
    options: { showEffects: true, showEvents: true },
    requestType: "WaitForLocalExecution"
  });
  console.log("[PoC] deposit tx digest:", depRes.digest);

  // Allocate (part of) collateral to the market before trading.
  // NOTE: allocation is in collateral units (MIST here).
  const allocateMist = 1_000_000_000n; // 1 SUI
  console.log("[PoC] allocate collateral to market:", formatSui(allocateMist));
  const { tx: txAlloc } = await account.getAllocateCollateralTx({
    marketId,
    allocateAmount: allocateMist
  });
  const allocRes = await client.signAndExecuteTransaction({
    transaction: txAlloc,
    signer: keypair,
    options: { showEffects: true, showEvents: true },
    requestType: "WaitForLocalExecution"
  });
  console.log("[PoC] allocate tx digest:", allocRes.digest);

  // Place a small market short.
  // `size` is in scaled base units; use market params to pick a valid multiple of lotSize
  // and satisfy min notional constraints.
  const scaling = market.marketParams.scalingFactor;
  const lotSize = market.marketParams.lotSize;
  const minUsd = market.marketParams.minOrderUsdValue;
  const px = market.indexPrice || 1;
  const minBase = minUsd / px; // base units
  let size = BigInt(Math.ceil(minBase * scaling)) + lotSize; // nudge above min
  size = ((size + lotSize - 1n) / lotSize) * lotSize;
  console.log("[PoC] open short market order size (scaled):", size.toString());

  const { tx: tx2 } = await account.getPlaceMarketOrderTx({
    marketId,
    size,
    side: 1, // PerpetualsOrderSide.Ask (short)
    collateralChange: 0,
    hasPosition: false,
    cancelSlTp: false,
    reduceOnly: false,
    slippage: 0.02
  });

  const openRes = await client.signAndExecuteTransaction({
    transaction: tx2,
    signer: keypair,
    options: { showEffects: true, showEvents: true },
    requestType: "WaitForLocalExecution"
  });
  console.log("[PoC] open short tx digest:", openRes.digest);

  // Refresh account and close whatever position is open on that market.
  const { account: account2 } = await perps.getAccount({ accountCap: cap });
  const pos = account2.account.positions.find((p) => p.marketId === marketId);
  const closeSize = size;
  console.log("[PoC] close reduce-only size (scaled):", closeSize.toString());

  const { tx: tx3 } = await account2.getPlaceMarketOrderTx({
    marketId,
    size: closeSize,
    side: 0, // PerpetualsOrderSide.Bid (buy to close)
    collateralChange: 0,
    hasPosition: pos ? true : false,
    cancelSlTp: true,
    reduceOnly: true,
    slippage: 0.02
  });

  const closeRes = await client.signAndExecuteTransaction({
    transaction: tx3,
    signer: keypair,
    options: { showEffects: true, showEvents: true },
    requestType: "WaitForLocalExecution"
  });
  console.log("[PoC] close tx digest:", closeRes.digest);

  console.log("[PoC] done.");
}

main().catch((e) => {
  console.error("[PoC] failed:", e?.message ?? e);
  process.exitCode = 1;
});
