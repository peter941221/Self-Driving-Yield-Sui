pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FlashRebalancer} from "../contracts/adapters/FlashRebalancer.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockPairForLibrary {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;

    function setTokens(address token0_, address token1_) external {
        token0 = token0_;
        token1 = token1_;
    }

    function setReserves(uint112 reserve0_, uint112 reserve1_) external {
        reserve0 = reserve0_;
        reserve1 = reserve1_;
        blockTimestampLast = uint32(block.timestamp);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }
}

contract MockVault {
    bool public payFull;

    constructor(bool payFull_) {
        payFull = payFull_;
    }

    function onFlashRebalance(address, address repayToken, uint256, uint256 repayAmount) external {
        if (payFull) {
            MockERC20(repayToken).transfer(msg.sender, repayAmount);
            return;
        }
        if (repayAmount > 0) {
            MockERC20(repayToken).transfer(msg.sender, repayAmount - 1);
        }
    }
}

contract FlashRebalanceFullTest is Test {
    bytes32 internal constant INIT_CODE_HASH =
        hex"00fb7f630766e6a796048ea87d01acd3068e8ff67d078148a3fa3f4a84f69bd5";

    struct FlashSetup {
        FlashRebalancer rebalancer;
        MockERC20 borrowToken;
        MockERC20 repayToken;
        address pair;
        address vault;
        uint256 borrowAmount;
        uint256 repayAmount;
        bool borrowToken0;
    }

    function _pairFor(address factory, address tokenA, address tokenB) internal pure returns (address pair) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(
            uint160(uint256(keccak256(abi.encodePacked(hex"ff", factory, keccak256(abi.encodePacked(token0, token1)), INIT_CODE_HASH))))
        );
    }

    function _setupPair(address factory, address tokenA, address tokenB, uint112 reserveA, uint112 reserveB)
        internal
        returns (address pair, address token0, address token1)
    {
        pair = _pairFor(factory, tokenA, tokenB);
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        MockPairForLibrary impl = new MockPairForLibrary();
        vm.etch(pair, address(impl).code);

        MockPairForLibrary(pair).setTokens(token0, token1);
        MockPairForLibrary(pair).setReserves(reserveA, reserveB);
    }

    function _setupFlash(bool payFull) internal returns (FlashSetup memory setup) {
        MockERC20 token0 = new MockERC20("T0", "T0", 18);
        MockERC20 token1 = new MockERC20("T1", "T1", 18);
        address factory = address(0xF00D);

        (address pair, address ordered0, address ordered1) =
            _setupPair(factory, address(token0), address(token1), 1_000_000e18, 1_000_000e18);

        setup.borrowToken0 = true;
        setup.borrowAmount = 1_000e18;

        uint256 reserveOut = 1_000_000e18;
        uint256 reserveIn = 1_000_000e18;
        setup.repayAmount = (reserveIn * setup.borrowAmount * 1000) / ((reserveOut - setup.borrowAmount) * 998) + 1;

        MockVault vault = new MockVault(payFull);
        setup.vault = address(vault);
        setup.pair = pair;
        setup.rebalancer = new FlashRebalancer(factory, pair, address(vault));
        setup.borrowToken = MockERC20(ordered0);
        setup.repayToken = MockERC20(ordered1);

        setup.borrowToken.mint(address(setup.rebalancer), setup.borrowAmount);
        setup.repayToken.mint(address(vault), setup.repayAmount);
    }

    function testFlashBorrowAndRepaySuccess() public {
        FlashSetup memory setup = _setupFlash(true);

        FlashRebalancer.RebalanceParams memory params = FlashRebalancer.RebalanceParams({
            borrowAmount: setup.borrowAmount,
            borrowToken0: setup.borrowToken0
        });
        bytes memory data = abi.encode(params);

        vm.prank(setup.pair);
        setup.rebalancer.pancakeCall(
            address(setup.rebalancer),
            setup.borrowToken0 ? setup.borrowAmount : 0,
            setup.borrowToken0 ? 0 : setup.borrowAmount,
            data
        );

        assertEq(setup.borrowToken.balanceOf(setup.vault), setup.borrowAmount);
        assertEq(setup.repayToken.balanceOf(setup.pair), setup.repayAmount);
    }

    function testRepayInsufficientReverts() public {
        FlashSetup memory setup = _setupFlash(false);

        FlashRebalancer.RebalanceParams memory params = FlashRebalancer.RebalanceParams({
            borrowAmount: setup.borrowAmount,
            borrowToken0: setup.borrowToken0
        });
        bytes memory data = abi.encode(params);

        vm.prank(setup.pair);
        vm.expectRevert(bytes("BAL"));
        setup.rebalancer.pancakeCall(
            address(setup.rebalancer),
            setup.borrowToken0 ? setup.borrowAmount : 0,
            setup.borrowToken0 ? 0 : setup.borrowAmount,
            data
        );
    }

    function testNonPairCannotCall() public {
        FlashRebalancer rebalancer = new FlashRebalancer(address(0xF00D), address(0xBEEF), address(this));

        vm.expectRevert("INVALID_PAIR");
        rebalancer.pancakeCall(address(rebalancer), 1, 0, hex"");
    }
}
