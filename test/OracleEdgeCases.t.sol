pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VolatilityOracle} from "../contracts/core/VolatilityOracle.sol";
import {EngineVault} from "../contracts/core/EngineVault.sol";
import {IERC20} from "../contracts/interfaces/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockOraclePair {
    address public token0;
    address public token1;

    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setReserves(uint112 r0, uint112 r1, uint32 ts) external {
        reserve0 = r0;
        reserve1 = r1;
        blockTimestampLast = ts;
    }

    function setCumulative(uint256 p0, uint256 p1) external {
        price0CumulativeLast = p0;
        price1CumulativeLast = p1;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }
}

contract OracleEdgeCasesTest is Test {
    function testColdStartEngineForcesNormal() public {
        MockOraclePair pair = new MockOraclePair(address(0xA), address(0xB));
        pair.setReserves(1000, 1000, uint32(block.timestamp));
        pair.setCumulative(0, 0);

        VolatilityOracle oracle = new VolatilityOracle(address(pair), true, 60, 3);
        MockERC20 asset = new MockERC20("USDT", "USDT", 18);

        EngineVault vault = new EngineVault(
            EngineVault.Addresses({
                asset: IERC20(address(asset)),
                asterDiamond: address(0),
                pancakeFactory: address(0),
                v2Pair: address(0),
                pairBase: address(0),
                pairQuote: address(0),
                bnbUsdtPair: address(0),
                volatilityOracle: oracle,
                flashRebalancer: address(0)
            }),
            EngineVault.Config({
                enableExternalCalls: false,
                minCycleInterval: 0,
                rebalanceThresholdBps: 500,
                deltaBandBps: 200,
                profitBountyBps: 0,
                maxBountyBps: 10000,
                bufferCapBps: 10000,
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

        vault.cycle();
        assertEq(uint256(vault.currentRegime()), uint256(VolatilityOracle.Regime.NORMAL));
    }

    function testFlatPricesYieldCalm() public {
        MockOraclePair pair = new MockOraclePair(address(0xA), address(0xB));
        VolatilityOracle oracle = new VolatilityOracle(address(pair), true, 60, 3);

        uint32 t0 = uint32(block.timestamp);
        pair.setReserves(1000, 1000, t0);
        pair.setCumulative(0, 0);
        oracle.recordSnapshot();

        vm.warp(block.timestamp + 60);
        uint256 price1 = uint256(100) << 112;
        pair.setReserves(1000, 1000, uint32(block.timestamp));
        pair.setCumulative(price1 * 60, 0);
        oracle.recordSnapshot();

        vm.warp(block.timestamp + 60);
        pair.setReserves(1000, 1000, uint32(block.timestamp));
        pair.setCumulative(price1 * 120, 0);
        oracle.recordSnapshot();

        assertEq(oracle.getVolatilityBps(), 0);
        assertEq(uint256(oracle.getRegime()), uint256(VolatilityOracle.Regime.CALM));
    }

    function testExtremeJumpGoesStorm() public {
        MockOraclePair pair = new MockOraclePair(address(0xA), address(0xB));
        VolatilityOracle oracle = new VolatilityOracle(address(pair), true, 60, 3);

        uint32 t0 = uint32(block.timestamp);
        pair.setReserves(1000, 1000, t0);
        pair.setCumulative(0, 0);
        oracle.recordSnapshot();

        vm.warp(block.timestamp + 60);
        uint256 price1 = uint256(50) << 112;
        pair.setReserves(1000, 1000, uint32(block.timestamp));
        pair.setCumulative(price1 * 60, 0);
        oracle.recordSnapshot();

        vm.warp(block.timestamp + 60);
        uint256 price2 = uint256(500) << 112;
        pair.setReserves(1000, 1000, uint32(block.timestamp));
        pair.setCumulative(price1 * 60 + price2 * 60, 0);
        oracle.recordSnapshot();

        assertEq(uint256(oracle.getRegime()), uint256(VolatilityOracle.Regime.STORM));
        assertGt(oracle.getVolatilityBps(), 300);
    }
}
