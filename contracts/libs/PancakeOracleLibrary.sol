pragma solidity ^0.8.24;

import {IPancakePairV2} from "../interfaces/IPancakePairV2.sol";

library PancakeOracleLibrary {
    function currentBlockTimestamp() internal view returns (uint32) {
        return uint32(block.timestamp);
    }

    function currentCumulativePrices(address pair)
        internal
        view
        returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp)
    {
        blockTimestamp = currentBlockTimestamp();
        price0Cumulative = IPancakePairV2(pair).price0CumulativeLast();
        price1Cumulative = IPancakePairV2(pair).price1CumulativeLast();

        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = IPancakePairV2(pair).getReserves();
        if (blockTimestampLast != blockTimestamp && reserve0 > 0 && reserve1 > 0) {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast;
            // slither-disable-next-line divide-before-multiply
            uint256 price0 = (uint256(reserve1) << 112) / uint256(reserve0);
            // slither-disable-next-line divide-before-multiply
            uint256 price1 = (uint256(reserve0) << 112) / uint256(reserve1);
            price0Cumulative += price0 * timeElapsed;
            price1Cumulative += price1 * timeElapsed;
        }
    }
}
