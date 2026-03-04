pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EngineVault} from "../contracts/core/EngineVault.sol";
import {WithdrawalQueue} from "../contracts/core/WithdrawalQueue.sol";
import {VolatilityOracle} from "../contracts/core/VolatilityOracle.sol";
import {IERC20} from "../contracts/interfaces/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockAsterDiamond {
    address public alpToken;
    uint256 public alpPrice;
    uint256 public cooldown;
    uint256 public lastMinted;

    constructor(address alpToken_) {
        alpToken = alpToken_;
        alpPrice = 1e18;
    }

    function ALP() external view returns (address) {
        return alpToken;
    }

    function coolingDuration() external view returns (uint256) {
        return cooldown;
    }

    function lastMintedTimestamp(address) external view returns (uint256) {
        return lastMinted;
    }
}

contract WithdrawalQueueEdgeTest is Test {
    function _deployVault(address asterDiamond) internal returns (EngineVault vault, MockERC20 asset) {
        asset = new MockERC20("USDT", "USDT", 18);
        vault = new EngineVault(
            EngineVault.Addresses({
                asset: IERC20(address(asset)),
                asterDiamond: asterDiamond,
                pancakeFactory: address(0),
                v2Pair: address(0),
                pairBase: address(0),
                pairQuote: address(0),
                bnbUsdtPair: address(0),
                volatilityOracle: VolatilityOracle(address(0)),
                flashRebalancer: address(0)
            }),
            EngineVault.Config({
                enableExternalCalls: false,
                minCycleInterval: 0,
                rebalanceThresholdBps: 500,
                deltaBandBps: 200,
                profitBountyBps: 0,
                maxBountyBps: 10000,
                bufferCapBps: 10000,
                calmAlpBps: 4000,
                calmLpBps: 5700,
                normalAlpBps: 6000,
                normalLpBps: 3700,
                stormAlpBps: 8000,
                stormLpBps: 1700,
                safeCycleThreshold: 3,
                maxGasPrice: 0,
                swapSlippageBps: 50
            })
        );
    }

    function testUnwindTriggeredWhenNoLiquidity() public {
        MockERC20 alp = new MockERC20("ALP", "ALP", 18);
        MockAsterDiamond diamond = new MockAsterDiamond(address(alp));
        (EngineVault vault, MockERC20 asset) = _deployVault(address(diamond));
        WithdrawalQueue queue = new WithdrawalQueue(vault, IERC20(address(asset)), 0, 0);

        address user = address(0xA11CE);
        asset.mint(user, 100e18);

        vm.startPrank(user);
        asset.approve(address(vault), 100e18);
        uint256 shares = vault.deposit(100e18, user);
        vault.approve(address(queue), shares);
        uint256 requestId = queue.requestWithdraw(shares, user);
        vm.stopPrank();

        uint256 vaultBalance = asset.balanceOf(address(vault));
        vm.startPrank(address(vault));
        asset.transfer(address(0xBEEF), vaultBalance);
        vm.stopPrank();

        alp.mint(address(vault), 100e18);

        uint256 assetsOwed = vault.previewRedeem(shares);
        vm.expectEmit(true, true, true, true, address(vault));
        emit EngineVault.UnwindForWithdraw(assetsOwed);
        queue.claimWithdraw(requestId);
    }

    function testClosedRequestCannotBeClaimedAgain() public {
        (EngineVault vault, MockERC20 asset) = _deployVault(address(0));
        WithdrawalQueue queue = new WithdrawalQueue(vault, IERC20(address(asset)), 0, 0);

        address user = address(0xB0B);
        asset.mint(user, 100e18);

        vm.startPrank(user);
        asset.approve(address(vault), 100e18);
        uint256 shares = vault.deposit(100e18, user);
        vault.approve(address(queue), shares);
        uint256 requestId = queue.requestWithdraw(shares, user);
        queue.claimWithdraw(requestId);
        vm.stopPrank();

        vm.expectRevert("CLOSED");
        queue.claimWithdraw(requestId);
    }

    function testMultipleRequestsIndependent() public {
        (EngineVault vault, MockERC20 asset) = _deployVault(address(0));
        WithdrawalQueue queue = new WithdrawalQueue(vault, IERC20(address(asset)), 0, 0);

        address user1 = address(0x1111);
        address user2 = address(0x2222);
        asset.mint(user1, 100e18);
        asset.mint(user2, 100e18);

        vm.startPrank(user1);
        asset.approve(address(vault), 100e18);
        uint256 shares1 = vault.deposit(100e18, user1);
        vault.approve(address(queue), shares1);
        uint256 req1 = queue.requestWithdraw(50e18, user1);
        vm.stopPrank();

        vm.startPrank(user2);
        asset.approve(address(vault), 100e18);
        uint256 shares2 = vault.deposit(100e18, user2);
        vault.approve(address(queue), shares2);
        uint256 req2 = queue.requestWithdraw(50e18, user2);
        vm.stopPrank();

        queue.claimWithdraw(req1);
        queue.claimWithdraw(req2);

        assertEq(asset.balanceOf(user1), 50e18);
        assertEq(asset.balanceOf(user2), 50e18);
    }
}
