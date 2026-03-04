pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EngineVault} from "../contracts/core/EngineVault.sol";
import {VolatilityOracle} from "../contracts/core/VolatilityOracle.sol";
import {IERC20} from "../contracts/interfaces/IERC20.sol";
import {MockPancakePair} from "./MockPancakePair.sol";
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

contract MockAsterDiamond {
    address public alp;
    uint256 public nav;

    constructor(address alp_) {
        alp = alp_;
    }

    function ALP() external view returns (address) {
        return alp;
    }

    function alpPrice() external view returns (uint256) {
        return nav;
    }

    function setNav(uint256 newNav) external {
        nav = newNav;
    }

    function coolingDuration() external pure returns (uint256) {
        return 0;
    }

    function lastMintedTimestamp(address) external pure returns (uint256) {
        return 0;
    }
}

contract EngineVaultRiskModeTest is Test {
    function testPriceDeviationTriggersOnlyUnwind() public {
        MockERC20 asset = new MockERC20();
        MockERC20 baseToken = new MockERC20();
        asset.mint(address(this), 1_000e18);

        address base = address(baseToken);
        MockPair pair = new MockPair(base, address(asset));
        VolatilityOracle oracle = new VolatilityOracle(address(pair), true, 60, 2);

        EngineVault vault = new EngineVault(
            EngineVault.Addresses({
                asset: IERC20(address(asset)),
                asterDiamond: address(0),
                pancakeFactory: address(0),
                v2Pair: address(pair),
                pairBase: base,
                pairQuote: address(asset),
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

        asset.approve(address(vault), 100e18);
        vault.deposit(100e18, address(this));

        uint32 t0 = uint32(block.timestamp);
        pair.setReserves(1000, 1000, t0);
        pair.setCumulative(0, 0);
        oracle.recordSnapshot();

        vm.warp(block.timestamp + 60);
        uint256 price1 = uint256(1) << 112;
        pair.setReserves(1000, 1000, uint32(block.timestamp));
        pair.setCumulative(price1 * 60, 0);
        oracle.recordSnapshot();

        vm.warp(block.timestamp + 60);
        pair.setReserves(1000, 500, uint32(block.timestamp));
        pair.setCumulative(price1 * 120, 0);

        vault.cycle();
        assertEq(uint256(vault.riskMode()), uint256(EngineVault.RiskMode.ONLY_UNWIND));
    }

    function testNavDropTriggersOnlyUnwind() public {
        MockERC20 asset = new MockERC20();
        MockERC20 alp = new MockERC20();
        MockAsterDiamond diamond = new MockAsterDiamond(address(alp));

        asset.mint(address(this), 1_000e18);
        MockPancakePair pair = new MockPancakePair();
        VolatilityOracle oracle = new VolatilityOracle(address(pair), true, 60, 3);

        EngineVault vault = new EngineVault(
            EngineVault.Addresses({
                asset: IERC20(address(asset)),
                asterDiamond: address(diamond),
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

        diamond.setNav(1e18);
        asset.approve(address(vault), 100e18);
        vault.deposit(100e18, address(this));

        vm.warp(block.timestamp + 60);
        vault.cycle();
        assertEq(uint256(vault.riskMode()), uint256(EngineVault.RiskMode.NORMAL));

        diamond.setNav(7e17);
        vm.warp(block.timestamp + 60);
        vault.cycle();
        assertEq(uint256(vault.riskMode()), uint256(EngineVault.RiskMode.ONLY_UNWIND));
    }
}
