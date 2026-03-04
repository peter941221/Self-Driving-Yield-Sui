pragma solidity ^0.8.24;

import {PancakeOracleLibrary} from "../libs/PancakeOracleLibrary.sol";
import {MathLib} from "../libs/MathLib.sol";

contract VolatilityOracle {
    using MathLib for uint256;

    struct PriceSnapshot {
        uint32 timestamp;
        uint256 priceCumulative;
    }

    uint8 public constant WINDOW_SIZE = 24;

    PriceSnapshot[WINDOW_SIZE] public snapshots;
    uint8 public snapshotIndex;
    uint8 public snapshotCount;

    uint32 public immutable minSnapshotInterval;
    uint8 public immutable minSamples;

    address public immutable pair;
    bool public immutable baseIsToken0;

    enum Regime {
        CALM,
        NORMAL,
        STORM
    }

    constructor(address pair_, bool baseIsToken0_, uint32 minSnapshotInterval_, uint8 minSamples_) {
        require(pair_ != address(0), "ZERO_PAIR");
        pair = pair_;
        baseIsToken0 = baseIsToken0_;
        minSnapshotInterval = minSnapshotInterval_;
        minSamples = minSamples_;
    }

    function recordSnapshot() external {
        PriceSnapshot memory last = snapshots[(snapshotIndex + WINDOW_SIZE - 1) % WINDOW_SIZE];
        if (last.timestamp != 0 && block.timestamp - last.timestamp < minSnapshotInterval) {
            return;
        }

        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) =
            PancakeOracleLibrary.currentCumulativePrices(pair);
        uint256 priceCumulative = baseIsToken0 ? price0Cumulative : price1Cumulative;

        snapshots[snapshotIndex] = PriceSnapshot(blockTimestamp, priceCumulative);
        snapshotIndex = (snapshotIndex + 1) % WINDOW_SIZE;
        if (snapshotCount < WINDOW_SIZE) {
            snapshotCount++;
        }
    }

    function getVolatilityBps() external view returns (uint256) {
        if (snapshotCount < minSamples) {
            return 0;
        }

        uint256 sumSquaredReturns = 0;
        uint256 count = 0;
        uint256 prevPrice = 0;

        for (uint8 i = 1; i < snapshotCount; i++) {
            uint8 curr = (snapshotIndex + WINDOW_SIZE - i) % WINDOW_SIZE;
            uint8 prev = (snapshotIndex + WINDOW_SIZE - i - 1) % WINDOW_SIZE;

            PriceSnapshot memory currSnap = snapshots[curr];
            PriceSnapshot memory prevSnap = snapshots[prev];
            if (currSnap.timestamp == 0 || prevSnap.timestamp == 0) {
                continue;
            }

            uint256 price = _twapPrice1e18(prevSnap, currSnap);
            if (prevPrice == 0) {
                prevPrice = price;
                continue;
            }

            int256 returnBps = int256((price * 10000) / prevPrice) - 10000;
            uint256 squared = uint256(returnBps >= 0 ? returnBps : -returnBps);
            sumSquaredReturns += squared * squared;
            count++;
            prevPrice = price;
        }

        if (count == 0) {
            return 0;
        }

        return MathLib.sqrt(sumSquaredReturns / count);
    }

    function getRegime() external view returns (Regime) {
        uint256 vol = this.getVolatilityBps();
        if (vol < 100) {
            return Regime.CALM;
        }
        if (vol < 300) {
            return Regime.NORMAL;
        }
        return Regime.STORM;
    }

    function getTwapPrice1e18() external view returns (uint256 price1e18) {
        if (snapshotCount < 2) {
            return 0;
        }

        uint8 currIndex = (snapshotIndex + WINDOW_SIZE - 1) % WINDOW_SIZE;
        uint8 prevIndex = (snapshotIndex + WINDOW_SIZE - 2) % WINDOW_SIZE;
        PriceSnapshot memory currSnap = snapshots[currIndex];
        PriceSnapshot memory prevSnap = snapshots[prevIndex];
        if (currSnap.timestamp == 0 || prevSnap.timestamp == 0) {
            return 0;
        }

        if (currSnap.timestamp <= prevSnap.timestamp) {
            return 0;
        }

        return _twapPrice1e18(prevSnap, currSnap);
    }

    function _twapPrice1e18(PriceSnapshot memory prev, PriceSnapshot memory curr)
        internal
        pure
        returns (uint256 price1e18)
    {
        uint256 timeElapsed = uint256(curr.timestamp - prev.timestamp);
        if (timeElapsed == 0) {
            return 0;
        }
        uint256 priceAverage = (curr.priceCumulative - prev.priceCumulative) / timeElapsed;
        // slither-disable-next-line divide-before-multiply
        price1e18 = (priceAverage * 1e18) / (2 ** 112);
    }
}
