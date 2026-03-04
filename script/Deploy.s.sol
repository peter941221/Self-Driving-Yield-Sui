pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {EngineVault} from "../contracts/core/EngineVault.sol";
import {VolatilityOracle} from "../contracts/core/VolatilityOracle.sol";
import {WithdrawalQueue} from "../contracts/core/WithdrawalQueue.sol";
import {FlashRebalancer} from "../contracts/adapters/FlashRebalancer.sol";
import {IERC20} from "../contracts/interfaces/IERC20.sol";
import {IPancakePairV2} from "../contracts/interfaces/IPancakePairV2.sol";
import {IPancakeFactoryV2} from "../contracts/interfaces/IPancakeFactoryV2.sol";

contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address usdt = vm.envAddress("USDT");
        address btcb = vm.envAddress("BTCB");
        address diamond = vm.envOr("ASTER_DIAMOND", address(0));
        address factory = vm.envAddress("PANCAKE_FACTORY");
        address pair = vm.envAddress("BTCB_USDT_PAIR");
        address wbnb = vm.envOr("WBNB", address(0));
        address bnbUsdtPair = vm.envOr("BNB_USDT_PAIR", address(0));

        if (bnbUsdtPair == address(0) && wbnb != address(0) && factory != address(0)) {
            bnbUsdtPair = IPancakeFactoryV2(factory).getPair(wbnb, usdt);
        }

        bool baseIsToken0 = IPancakePairV2(pair).token0() == btcb;

        vm.startBroadcast(deployerKey);

        VolatilityOracle oracle = new VolatilityOracle(pair, baseIsToken0, 300, 3);

        EngineVault vault = new EngineVault(
            EngineVault.Addresses({
                asset: IERC20(usdt),
                asterDiamond: diamond,
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
                minCycleInterval: 300,
                rebalanceThresholdBps: 500,
                deltaBandBps: 200,
                profitBountyBps: 1000,
                maxBountyBps: 50,
                bufferCapBps: 2000,
                calmAlpBps: 4000,
                calmLpBps: 5700,
                normalAlpBps: 6000,
                normalLpBps: 3700,
                stormAlpBps: 8000,
                stormLpBps: 1700,
                safeCycleThreshold: 3,
                maxGasPrice: 0,
                swapSlippageBps: 50
            })
        );

        WithdrawalQueue queue = new WithdrawalQueue(vault, IERC20(usdt), 30, 100);
        FlashRebalancer rebalancer = new FlashRebalancer(factory, pair, address(vault));

        vm.stopBroadcast();

        console2.log("VolatilityOracle", address(oracle));
        console2.log("EngineVault", address(vault));
        console2.log("WithdrawalQueue", address(queue));
        console2.log("FlashRebalancer", address(rebalancer));
    }
}
