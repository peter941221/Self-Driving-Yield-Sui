pragma solidity ^0.8.24;

interface ITradingReader {
    struct Position {
        bytes32 positionHash;
        string pair;
        address pairBase;
        address marginToken;
        bool isLong;
        uint96 margin;
        uint80 qty;
        uint64 entryPrice;
        uint64 stopLoss;
        uint64 takeProfit;
        uint96 openFee;
        uint96 executionFee;
        int256 fundingFee;
        uint40 timestamp;
        uint96 holdingFee;
    }

    function getPositionByHashV2(bytes32 tradeHash) external view returns (Position memory);

    function getPositionsV2(address user, address pairBase) external view returns (Position[] memory);
}
