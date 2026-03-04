pragma solidity ^0.8.24;

contract MockPancakePair {
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    uint256 private price0CumulativeLast_;
    uint256 private price1CumulativeLast_;

    function setReserves(uint112 reserve0_, uint112 reserve1_, uint32 blockTimestampLast_) external {
        reserve0 = reserve0_;
        reserve1 = reserve1_;
        blockTimestampLast = blockTimestampLast_;
    }

    function setCumulatives(uint256 price0_, uint256 price1_) external {
        price0CumulativeLast_ = price0_;
        price1CumulativeLast_ = price1_;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function price0CumulativeLast() external view returns (uint256) {
        return price0CumulativeLast_;
    }

    function price1CumulativeLast() external view returns (uint256) {
        return price1CumulativeLast_;
    }
}
