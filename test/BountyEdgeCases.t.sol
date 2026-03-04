pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EngineVault} from "../contracts/core/EngineVault.sol";
import {VolatilityOracle} from "../contracts/core/VolatilityOracle.sol";
import {IERC20} from "../contracts/interfaces/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockPricePair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setReserves(uint112 reserve0_, uint112 reserve1_) external {
        reserve0 = reserve0_;
        reserve1 = reserve1_;
        blockTimestampLast = uint32(block.timestamp);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }
}

contract BountyEdgeCasesTest is Test {
    function _deployVault(uint16 profitBountyBps, uint16 maxBountyBps, uint16 bufferCapBps, uint256 maxGasPrice)
        internal
        returns (EngineVault vault, MockERC20 asset, MockPricePair pair)
    {
        asset = new MockERC20("USDT", "USDT", 18);
        MockERC20 bnb = new MockERC20("BNB", "BNB", 18);
        pair = new MockPricePair(address(asset), address(bnb));

        vault = new EngineVault(
            EngineVault.Addresses({
                asset: IERC20(address(asset)),
                asterDiamond: address(0),
                pancakeFactory: address(0),
                v2Pair: address(0),
                pairBase: address(0),
                pairQuote: address(0),
                bnbUsdtPair: address(pair),
                volatilityOracle: VolatilityOracle(address(0)),
                flashRebalancer: address(0)
            }),
            EngineVault.Config({
                enableExternalCalls: false,
                minCycleInterval: 0,
                rebalanceThresholdBps: 500,
                deltaBandBps: 200,
                profitBountyBps: profitBountyBps,
                maxBountyBps: maxBountyBps,
                bufferCapBps: bufferCapBps,
                calmAlpBps: 4000,
                calmLpBps: 5700,
                normalAlpBps: 6000,
                normalLpBps: 3700,
                stormAlpBps: 8000,
                stormLpBps: 1700,
                safeCycleThreshold: 3,
                maxGasPrice: maxGasPrice,
                swapSlippageBps: 50
            })
        );
    }

    function testBountyGasPriceCapped() public {
        (EngineVault vault, MockERC20 asset, MockPricePair pair) = _deployVault(0, 10000, 10000, 5 gwei);

        pair.setReserves(300e18, 1e18);
        asset.mint(address(vault), 1000e18);

        vm.txGasPrice(100 gwei);
        uint256 gasPriceUsed = 5 gwei;
        uint256 bnbPrice = 300e18;
        uint256 minBounty = (gasPriceUsed * 500_000 * bnbPrice) / 1e18;
        minBounty = (minBounty * 150) / 100;

        address caller = address(0xCA11);
        vm.prank(caller);
        vault.cycle();

        assertEq(asset.balanceOf(caller), minBounty);
    }

    function testBountyProfitZeroUsesGasOnly() public {
        (EngineVault vault, MockERC20 asset, MockPricePair pair) = _deployVault(1000, 10000, 10000, 5 gwei);

        pair.setReserves(300e18, 1e18);
        asset.mint(address(vault), 1000e18);

        vm.txGasPrice(5 gwei);
        address caller = address(0xCA11);
        vm.prank(caller);
        vault.cycle();

        uint256 beforeBalance = asset.balanceOf(caller);
        vm.prank(caller);
        vault.cycle();

        uint256 bnbPrice = 300e18;
        uint256 minBounty = (5 gwei * 500_000 * bnbPrice) / 1e18;
        minBounty = (minBounty * 150) / 100;

        assertEq(asset.balanceOf(caller) - beforeBalance, minBounty);
    }

    function testBountyCappedByBuffer() public {
        (EngineVault vault, MockERC20 asset,) = _deployVault(10000, 10000, 100, 0);

        asset.mint(address(vault), 1000e18);

        address caller = address(0xCA11);
        vm.prank(caller);
        vault.cycle();

        assertEq(asset.balanceOf(caller), 10e18);
    }
}
