pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {EngineVault} from "../contracts/core/EngineVault.sol";
import {VolatilityOracle} from "../contracts/core/VolatilityOracle.sol";
import {IERC20} from "../contracts/interfaces/IERC20.sol";
import {MockPancakePair} from "./MockPancakePair.sol";

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

contract Handler is Test {
    EngineVault internal vault;
    MockERC20 internal asset;

    constructor(EngineVault vault_, MockERC20 asset_) {
        vault = vault_;
        asset = asset_;
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 1000e18);
        asset.mint(address(this), amount);
        asset.approve(address(vault), amount);
        vault.deposit(amount, address(this));
    }

    function redeem(uint256 shares) external {
        uint256 bal = vault.balanceOf(address(this));
        if (bal == 0) {
            return;
        }
        shares = bound(shares, 1, bal);
        vault.redeem(shares, address(this), address(this));
    }
}

contract EngineVaultInvariantTest is StdInvariant, Test {
    EngineVault internal vault;
    MockERC20 internal asset;
    Handler internal handler;

    function setUp() public {
        asset = new MockERC20();
        MockPancakePair pair = new MockPancakePair();
        VolatilityOracle oracle = new VolatilityOracle(address(pair), true, 60, 3);
        vault = new EngineVault(
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

        handler = new Handler(vault, asset);
        targetContract(address(handler));
    }

    function invariant_totalSupplyMatchesHandlerBalance() public view {
        assertEq(vault.totalSupply(), vault.balanceOf(address(handler)));
    }

    function invariant_totalAssetsEqualsCash() public view {
        assertEq(vault.totalAssets(), asset.balanceOf(address(vault)));
    }
}
