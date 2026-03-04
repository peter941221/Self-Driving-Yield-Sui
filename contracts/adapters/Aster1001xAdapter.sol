pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IAsterDiamond} from "../interfaces/IAsterDiamond.sol";
import {ITradingReader} from "../interfaces/ITradingReader.sol";

library Aster1001xAdapter {
    function openShort(
        address diamond,
        address pairBase,
        address tokenIn,
        uint256 marginAmount,
        uint256 qty,
        uint256 worstPrice
    ) internal {
        require(marginAmount <= type(uint96).max, "MARGIN_TOO_LARGE");
        IAsterDiamond.OpenDataInput memory data = IAsterDiamond.OpenDataInput({
            pairBase: pairBase,
            isLong: false,
            tokenIn: tokenIn,
            amountIn: uint96(marginAmount),
            qty: uint80(qty),
            price: uint64(worstPrice),
            stopLoss: 0,
            takeProfit: 0,
            broker: 0
        });

        require(IERC20(tokenIn).approve(diamond, marginAmount), "APPROVE");
        IAsterDiamond(diamond).openMarketTrade(data);
    }

    function closeTrade(address diamond, bytes32 tradeHash) internal {
        IAsterDiamond(diamond).closeTrade(tradeHash);
    }

    function addMargin(address diamond, bytes32 tradeHash, address tokenIn, uint96 amount) internal {
        require(IERC20(tokenIn).approve(diamond, amount), "APPROVE");
        IAsterDiamond(diamond).addMargin(tradeHash, amount);
    }

    function getPositions(address diamond, address account, address pairBase)
        internal
        view
        returns (ITradingReader.Position[] memory positions)
    {
        positions = ITradingReader(diamond).getPositionsV2(account, pairBase);
    }

    function getHedgeBaseQty(address diamond, address account, address pairBase)
        internal
        view
        returns (uint256 baseQty)
    {
        ITradingReader.Position[] memory positions = getPositions(diamond, account, pairBase);
        for (uint256 i = 0; i < positions.length; i++) {
            if (!positions[i].isLong) {
                baseQty += positions[i].qty;
            }
        }
    }

    function getShortExposure(address diamond, address account, address pairBase)
        internal
        view
        returns (uint256 totalQty, uint256 totalNotional, uint256 avgEntryPrice)
    {
        ITradingReader.Position[] memory positions = getPositions(diamond, account, pairBase);
        for (uint256 i = 0; i < positions.length; i++) {
            if (!positions[i].isLong) {
                totalQty += positions[i].qty;
                totalNotional += uint256(positions[i].qty) * uint256(positions[i].entryPrice);
            }
        }

        if (totalQty > 0) {
            avgEntryPrice = totalNotional / totalQty;
        }
    }

    function usdToQty(uint256 usdAmount, uint256 price1e8) internal pure returns (uint256 qty1e10) {
        if (price1e8 == 0) {
            return 0;
        }
        qty1e10 = (usdAmount * 1e10) / price1e8;
    }
}
