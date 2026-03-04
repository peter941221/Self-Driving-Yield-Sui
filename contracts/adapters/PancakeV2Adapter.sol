pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IPancakeRouterV2} from "../interfaces/IPancakeRouterV2.sol";
import {IPancakeFactoryV2} from "../interfaces/IPancakeFactoryV2.sol";
import {IPancakePairV2} from "../interfaces/IPancakePairV2.sol";

library PancakeV2Adapter {
    address internal constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;

    function addLiquidity(address tokenA, address tokenB, uint256 amountA, uint256 amountB, uint256 slippageBps)
        internal
        returns (uint256 liquidity)
    {
        require(IERC20(tokenA).approve(ROUTER, amountA), "APPROVE_A");
        require(IERC20(tokenB).approve(ROUTER, amountB), "APPROVE_B");

        uint256 minA = (amountA * (10000 - slippageBps)) / 10000;
        uint256 minB = (amountB * (10000 - slippageBps)) / 10000;

        (uint256 usedA, uint256 usedB, uint256 lpOut) = IPancakeRouterV2(ROUTER).addLiquidity(
            tokenA, tokenB, amountA, amountB, minA, minB, address(this), block.timestamp + 300
        );
        require(usedA > 0 && usedB > 0 && lpOut > 0, "ZERO_LIQ");
        liquidity = lpOut;
    }

    function removeLiquidity(address tokenA, address tokenB, uint256 liquidity, uint256 slippageBps)
        internal
        returns (uint256 amountA, uint256 amountB)
    {
        address pair = IPancakeFactoryV2(FACTORY).getPair(tokenA, tokenB);
        require(IERC20(pair).approve(ROUTER, liquidity), "APPROVE_LP");

        (uint256 expectedA, uint256 expectedB) = getUnderlyingAmountsForTokens(pair, address(this), tokenA);
        uint256 minA = (expectedA * (10000 - slippageBps)) / 10000;
        uint256 minB = (expectedB * (10000 - slippageBps)) / 10000;

        (amountA, amountB) = IPancakeRouterV2(ROUTER).removeLiquidity(
            tokenA, tokenB, liquidity, minA, minB, address(this), block.timestamp + 300
        );
    }

    function getUnderlyingAmounts(address pair, address account) internal view returns (uint256 amt0, uint256 amt1) {
        uint256 lpBal = IERC20(pair).balanceOf(account);
        (uint112 r0, uint112 r1, uint32 blockTimestampLast) = IPancakePairV2(pair).getReserves();
        if (blockTimestampLast == 0) {
            return (0, 0);
        }
        uint256 ts = IERC20(pair).totalSupply();
        if (ts == 0) {
            return (0, 0);
        }
        amt0 = (lpBal * uint256(r0)) / ts;
        amt1 = (lpBal * uint256(r1)) / ts;
    }

    function getUnderlyingAmountsForTokens(address pair, address account, address tokenA)
        internal
        view
        returns (uint256 amtA, uint256 amtB)
    {
        (uint256 amt0, uint256 amt1) = getUnderlyingAmounts(pair, account);
        address token0 = IPancakePairV2(pair).token0();
        if (tokenA == token0) {
            amtA = amt0;
            amtB = amt1;
        } else {
            amtA = amt1;
            amtB = amt0;
        }
    }

    function getSpotPrice1e18(address pair) internal view returns (uint256 price1e18) {
        (uint112 r0, uint112 r1, uint32 blockTimestampLast) = IPancakePairV2(pair).getReserves();
        if (blockTimestampLast == 0 || r0 == 0) {
            return 0;
        }
        price1e18 = (uint256(r1) * 1e18) / uint256(r0);
    }

    function swapExactTokensForTokens(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOutMin)
        internal
        returns (uint256 amountOut)
    {
        require(IERC20(tokenIn).approve(ROUTER, amountIn), "APPROVE_SWAP");
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        uint256[] memory amounts = IPancakeRouterV2(ROUTER).swapExactTokensForTokens(
            amountIn, amountOutMin, path, address(this), block.timestamp + 300
        );
        amountOut = amounts[amounts.length - 1];
    }
}
