pragma solidity ^0.8.24;

interface IAsterDiamond {
    struct OpenDataInput {
        address pairBase;
        bool isLong;
        address tokenIn;
        uint96 amountIn;
        uint80 qty;
        uint64 price;
        uint64 stopLoss;
        uint64 takeProfit;
        uint24 broker;
    }

    function openMarketTrade(OpenDataInput calldata data) external;

    function closeTrade(bytes32 tradeHash) external;

    function addMargin(bytes32 tradeHash, uint96 amount) external;

    function mintAlp(address tokenIn, uint256 amount, uint256 minAlp, bool stake) external returns (uint256 alpOut);

    function burnAlp(address tokenOut, uint256 alpAmount, uint256 minOut, address receiver)
        external
        returns (uint256 tokenOutAmount);

    function ALP() external view returns (address);

    function coolingDuration() external view returns (uint256);

    function lastMintedTimestamp(address account) external view returns (uint256);

    function alpPrice() external view returns (uint256);

    // Minimal interface covering functions used by this vault. Full ABI available via Louper.
}
