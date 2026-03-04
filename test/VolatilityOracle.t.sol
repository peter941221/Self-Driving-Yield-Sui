pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {VolatilityOracle} from "../contracts/core/VolatilityOracle.sol";

contract MockPancakePair {
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

contract VolatilityOracleTest is Test {
    function testTwapPriceFromLatestSnapshots() public {
        MockPancakePair pair = new MockPancakePair(address(0xA), address(0xB));
        VolatilityOracle oracle = new VolatilityOracle(address(pair), true, 60, 2);

        uint32 t0 = uint32(block.timestamp);
        pair.setReserves(1000, 1000, t0);
        pair.setCumulative(0, 0);
        oracle.recordSnapshot();

        vm.warp(block.timestamp + 60);
        uint256 price1 = uint256(100) << 112;
        pair.setReserves(1000, 1000, uint32(block.timestamp));
        pair.setCumulative(price1 * 60, 0);
        oracle.recordSnapshot();

        uint256 twap = oracle.getTwapPrice1e18();
        assertEq(twap, 100e18);
    }

    function testRegimeSwitchToStorm() public {
        MockPancakePair pair = new MockPancakePair(address(0xA), address(0xB));
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
        uint256 price2 = uint256(200) << 112;
        pair.setReserves(1000, 1000, uint32(block.timestamp));
        pair.setCumulative(price1 * 60 + price2 * 60, 0);
        oracle.recordSnapshot();

        uint256 vol = oracle.getVolatilityBps();
        assertGt(vol, 300);
        assertEq(uint256(oracle.getRegime()), uint256(VolatilityOracle.Regime.STORM));
    }
}
