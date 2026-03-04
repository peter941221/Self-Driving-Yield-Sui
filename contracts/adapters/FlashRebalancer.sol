pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IPancakePairV2} from "../interfaces/IPancakePairV2.sol";
import {PancakeLibrary} from "../libs/PancakeLibrary.sol";

interface IFlashRebalanceHook {
    function onFlashRebalance(address tokenBorrowed, address repayToken, uint256 borrowedAmount, uint256 repayAmount)
        external;
}

contract FlashRebalancer {
    address public immutable factory;
    address public immutable pair;
    address public immutable vault;

    constructor(address factory_, address pair_, address vault_) {
        require(factory_ != address(0), "ZERO_FACTORY");
        require(pair_ != address(0), "ZERO_PAIR");
        require(vault_ != address(0), "ZERO_VAULT");
        factory = factory_;
        pair = pair_;
        vault = vault_;
    }

    struct RebalanceParams {
        uint256 borrowAmount;
        bool borrowToken0;
    }

    function executeFlashRebalance(RebalanceParams calldata params) external {
        require(msg.sender == vault, "ONLY_VAULT");
        uint256 amount0Out = params.borrowToken0 ? params.borrowAmount : 0;
        uint256 amount1Out = params.borrowToken0 ? 0 : params.borrowAmount;
        IPancakePairV2(pair).swap(amount0Out, amount1Out, address(this), abi.encode(params));
    }

    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external {
        require(msg.sender == pair, "INVALID_PAIR");
        require(sender == address(this), "INVALID_SENDER");

        RebalanceParams memory params = abi.decode(data, (RebalanceParams));
        require(params.borrowAmount == (params.borrowToken0 ? amount0 : amount1), "AMOUNT_MISMATCH");

        address token0 = IPancakePairV2(pair).token0();
        address token1 = IPancakePairV2(pair).token1();

        address tokenBorrowed = params.borrowToken0 ? token0 : token1;
        uint256 borrowed = params.borrowToken0 ? amount0 : amount1;

        address repayToken = params.borrowToken0 ? token1 : token0;
        address[] memory path = new address[](2);
        path[0] = repayToken;
        path[1] = tokenBorrowed;
        uint256 repayAmount = PancakeLibrary.getAmountsIn(factory, borrowed, path)[0];

        require(IERC20(tokenBorrowed).transfer(vault, borrowed), "TRANSFER_BORROW");
        IFlashRebalanceHook(vault).onFlashRebalance(tokenBorrowed, repayToken, borrowed, repayAmount);

        require(IERC20(repayToken).transfer(msg.sender, repayAmount), "TRANSFER_REPAY");
    }
}
