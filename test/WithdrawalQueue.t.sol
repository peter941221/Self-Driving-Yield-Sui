pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EngineVault} from "../contracts/core/EngineVault.sol";
import {WithdrawalQueue} from "../contracts/core/WithdrawalQueue.sol";
import {VolatilityOracle} from "../contracts/core/VolatilityOracle.sol";
import {IERC20} from "../contracts/interfaces/IERC20.sol";
import {MockPair} from "./MockPair.sol";

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "BAL");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOW");
        allowance[from][msg.sender] = allowed - amount;
        require(balanceOf[from] >= amount, "BAL");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract WithdrawalQueueTest is Test {
    function testRequestAndClaim() public {
        MockERC20 asset = new MockERC20();
        asset.mint(address(this), 100e18);

        MockPair pair = new MockPair(address(0xA), address(0xB));
        VolatilityOracle oracle = new VolatilityOracle(address(pair), true, 60, 3);
        EngineVault vault = new EngineVault(
            EngineVault.Addresses({
                asset: IERC20(address(asset)),
                asterDiamond: address(0),
                pancakeFactory: address(0),
                v2Pair: address(0),
                pairBase: address(0),
                pairQuote: address(0),
                bnbUsdtPair: address(0),
                volatilityOracle: oracle,
                flashRebalancer: address(0)
            }),
            EngineVault.Config({
                enableExternalCalls: false,
                minCycleInterval: 60,
                rebalanceThresholdBps: 500,
                deltaBandBps: 200,
                profitBountyBps: 1000,
                maxBountyBps: 50,
                bufferCapBps: 2000,
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

        WithdrawalQueue queue = new WithdrawalQueue(vault, IERC20(address(asset)), 50, 100);

        asset.approve(address(vault), 100e18);
        uint256 shares = vault.deposit(100e18, address(this));

        vault.approve(address(queue), shares);
        uint256 requestId = queue.requestWithdraw(shares, address(this));

        uint256 beforeBalance = asset.balanceOf(address(this));
        queue.claimWithdraw(requestId);
        uint256 afterBalance = asset.balanceOf(address(this));

        assertGt(afterBalance, beforeBalance);
        assertEq(vault.balanceOf(address(this)), 0);
    }
}
