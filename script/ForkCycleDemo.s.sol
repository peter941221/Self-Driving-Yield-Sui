pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {EngineVault} from "../contracts/core/EngineVault.sol";
import {VolatilityOracle} from "../contracts/core/VolatilityOracle.sol";
import {IERC20} from "../contracts/interfaces/IERC20.sol";
import {IAsterDiamond} from "../contracts/interfaces/IAsterDiamond.sol";
import {IPancakePairV2} from "../contracts/interfaces/IPancakePairV2.sol";
import {IPancakeFactoryV2} from "../contracts/interfaces/IPancakeFactoryV2.sol";

contract ForkCycleDemo is Script, StdCheats {
    function run() external {
        string memory rpcUrl = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpcUrl).length > 0) {
            vm.createSelectFork(rpcUrl);
        }

        address usdt = vm.envOr("USDT", address(0x55d398326f99059fF775485246999027B3197955));
        address btcb = vm.envOr("BTCB", address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c));
        address wbnb = vm.envOr("WBNB", address(0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c));
        address diamond = vm.envOr("ASTER_DIAMOND", address(0x1b6F2d3844C6ae7D56ceb3C3643b9060ba28FEb0));
        address factory = vm.envOr("PANCAKE_FACTORY", address(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73));
        address pair = vm.envOr("BTCB_USDT_PAIR", address(0x3F803EC2b816Ea7F06EC76aA2B6f2532F9892d62));
        address bnbUsdtPair = IPancakeFactoryV2(factory).getPair(wbnb, usdt);

        bool baseIsToken0 = IPancakePairV2(pair).token0() == btcb;
        VolatilityOracle oracle = new VolatilityOracle(pair, baseIsToken0, 300, 3);

        EngineVault vault = new EngineVault(
            EngineVault.Addresses({
                asset: IERC20(usdt),
                asterDiamond: address(0),
                pancakeFactory: factory,
                v2Pair: pair,
                pairBase: btcb,
                pairQuote: usdt,
                bnbUsdtPair: bnbUsdtPair,
                volatilityOracle: oracle,
                flashRebalancer: address(0)
            }),
            EngineVault.Config({
                enableExternalCalls: true,
                minCycleInterval: 60,
                rebalanceThresholdBps: 500,
                deltaBandBps: 200,
                profitBountyBps: 1000,
                maxBountyBps: 50,
                bufferCapBps: 2000,
                calmAlpBps: 0,
                calmLpBps: 9700,
                normalAlpBps: 0,
                normalLpBps: 9700,
                stormAlpBps: 0,
                stormLpBps: 9700,
                safeCycleThreshold: 3,
                maxGasPrice: 0,
                swapSlippageBps: 50
            })
        );

        deal(usdt, address(this), 100_000e18);
        IERC20(usdt).approve(address(vault), 50_000e18);
        uint256 shares = vault.deposit(50_000e18, address(this));

        vm.warp(block.timestamp + 60);
        vault.cycle();

        console2.log("Shares", shares);
        console2.log("Regime", uint256(vault.currentRegime()));
        console2.log("TotalAssets", vault.totalAssets());
        console2.log("VaultQuote", IERC20(usdt).balanceOf(address(vault)));
        console2.log("VaultBase", IERC20(btcb).balanceOf(address(vault)));

        bool hedgeOk = _attemptHedge(diamond, btcb, usdt, pair, baseIsToken0);
        console2.log("HedgeAttempt", hedgeOk);
    }

    function _attemptHedge(address diamond, address btcb, address usdt, address pair, bool baseIsToken0)
        internal
        returns (bool hedgeOk)
    {
        (uint112 r0, uint112 r1,) = IPancakePairV2(pair).getReserves();
        uint256 price1e8 = baseIsToken0 ? (uint256(r1) * 1e8) / uint256(r0) : (uint256(r0) * 1e8) / uint256(r1);
        uint256 margin = 100e18;
        uint256 qty = price1e8 == 0 ? 0 : (margin * 1e10) / price1e8;

        IERC20(usdt).approve(diamond, margin);
        IAsterDiamond.OpenDataInput memory data = IAsterDiamond.OpenDataInput({
            pairBase: btcb,
            isLong: false,
            tokenIn: usdt,
            amountIn: uint96(margin),
            qty: uint80(qty),
            price: uint64(price1e8),
            stopLoss: 0,
            takeProfit: 0,
            broker: 0
        });

        try IAsterDiamond(diamond).openMarketTrade(data) {
            hedgeOk = true;
        } catch {
            hedgeOk = false;
        }
    }
}
