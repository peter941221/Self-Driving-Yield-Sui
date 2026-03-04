pragma solidity ^0.8.24;

contract MockPair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
        reserve0 = 1;
        reserve1 = 1;
        blockTimestampLast = uint32(block.timestamp);
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
