pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EngineVault} from "../contracts/core/EngineVault.sol";
import {IERC20} from "../contracts/interfaces/IERC20.sol";
import {VolatilityOracle} from "../contracts/core/VolatilityOracle.sol";
import {MockERC20} from "./MockERC20.sol";

contract MockVolatilityOracle {
    address public pair;
    bool public baseIsToken0;
    uint8 public minSamples;
    uint8 public snapshotCount;
    VolatilityOracle.Regime public regime;
    uint256 public volatilityBps;
    uint256 public twapPrice1e18;

    constructor(uint8 minSamples_, VolatilityOracle.Regime regime_) {
        pair = address(0x1111);
        baseIsToken0 = true;
        minSamples = minSamples_;
        regime = regime_;
        twapPrice1e18 = 1e18;
    }

    function recordSnapshot() external {
        snapshotCount++;
    }

    function setRegime(VolatilityOracle.Regime regime_) external {
        regime = regime_;
    }

    function setSnapshotCount(uint8 count) external {
        snapshotCount = count;
    }

    function setTwapPrice(uint256 price) external {
        twapPrice1e18 = price;
    }

    function setVolatilityBps(uint256 vol) external {
        volatilityBps = vol;
    }

    function getRegime() external view returns (VolatilityOracle.Regime) {
        return regime;
    }

    function getVolatilityBps() external view returns (uint256) {
        return volatilityBps;
    }

    function getTwapPrice1e18() external view returns (uint256) {
        return twapPrice1e18;
    }
}

contract MockPairFull {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }

    function setReserves(uint112 reserve0_, uint112 reserve1_) external {
        reserve0 = reserve0_;
        reserve1 = reserve1_;
        blockTimestampLast = uint32(block.timestamp);
    }

    function setTotalSupply(uint256 totalSupply_) external {
        totalSupply = totalSupply_;
    }

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }
}

contract MockAsterDiamond {
    address public alpToken;
    uint256 public cooldown;
    uint256 public lastMintedTimestampValue;
    uint256 public alpPrice;

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
        return lastMintedTimestampValue;
    }

    function setAlpPrice(uint256 price) external {
        alpPrice = price;
    }

    function setLastMintedTimestamp(uint256 ts) external {
        lastMintedTimestampValue = ts;
    }

    function setCooldown(uint256 cooldown_) external {
        cooldown = cooldown_;
    }

    function mintAlp(address, uint256 amount, uint256, bool) external returns (uint256) {
        MockERC20(alpToken).mint(msg.sender, amount);
        return amount;
    }

    function burnAlp(address, uint256 alpAmount, uint256, address) external pure returns (uint256) {
        return alpAmount;
    }
}

contract CycleFullPathTest is Test {
    function _deployVault(VolatilityOracle.Regime regime, uint256 minCycleInterval)
        internal
        returns (
            EngineVault vault,
            MockVolatilityOracle oracle,
            MockERC20 asset,
            MockERC20 base,
            MockERC20 alp,
            MockPairFull pair,
            MockAsterDiamond diamond
        )
    {
        asset = new MockERC20("USDT", "USDT", 18);
        base = new MockERC20("BTCB", "BTCB", 18);
        alp = new MockERC20("ALP", "ALP", 18);
        pair = new MockPairFull(address(base), address(asset));
        diamond = new MockAsterDiamond(address(alp));
        oracle = new MockVolatilityOracle(1, regime);

        vault = new EngineVault(
            EngineVault.Addresses({
                asset: IERC20(address(asset)),
                asterDiamond: address(diamond),
                pancakeFactory: address(0xBEEF),
                v2Pair: address(pair),
                pairBase: address(base),
                pairQuote: address(asset),
                bnbUsdtPair: address(0),
                volatilityOracle: VolatilityOracle(address(oracle)),
                flashRebalancer: address(0)
            }),
            EngineVault.Config({
                enableExternalCalls: false,
                minCycleInterval: minCycleInterval,
                rebalanceThresholdBps: 50,
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

    function testCycleNormalRebalancePlan() public {
        (EngineVault vault, MockVolatilityOracle oracle, MockERC20 asset,, MockERC20 alp, MockPairFull pair,) =
            _deployVault(VolatilityOracle.Regime.NORMAL, 0);

        alp.mint(address(vault), 600e18);
        asset.mint(address(vault), 100e18);
        pair.setReserves(500e18, 500e18);
        pair.setTotalSupply(1000e18);
        pair.setBalance(address(vault), 300e18);

        oracle.setSnapshotCount(1);

        vm.expectEmit(true, true, true, true, address(vault));
        emit EngineVault.RebalancePlanned(0, int256(70e18), 1000e18);
        vault.cycle();

        assertEq(uint256(vault.currentRegime()), uint256(VolatilityOracle.Regime.NORMAL));
    }

    function testCycleStormRebalancePlan() public {
        (EngineVault vault, MockVolatilityOracle oracle, MockERC20 asset,, MockERC20 alp, MockPairFull pair,) =
            _deployVault(VolatilityOracle.Regime.STORM, 0);

        alp.mint(address(vault), 500e18);
        asset.mint(address(vault), 100e18);
        pair.setReserves(500e18, 500e18);
        pair.setTotalSupply(1000e18);
        pair.setBalance(address(vault), 400e18);

        oracle.setSnapshotCount(1);

        vm.expectEmit(true, true, true, true, address(vault));
        emit EngineVault.RebalancePlanned(int256(300e18), int256(-230e18), 1000e18);
        vault.cycle();

        assertEq(uint256(vault.currentRegime()), uint256(VolatilityOracle.Regime.STORM));
    }

    function testCycleIntervalRevert() public {
        (EngineVault vault,,, MockERC20 base,, MockPairFull pair,) = _deployVault(VolatilityOracle.Regime.NORMAL, 60);

        pair.setReserves(500e18, 500e18);
        pair.setTotalSupply(1000e18);
        pair.setBalance(address(vault), 1e18);
        base.mint(address(vault), 1e18);

        vm.warp(100);
        vault.cycle();

        vm.expectRevert("CYCLE_INTERVAL");
        vault.cycle();
    }

    function testRegimeSwitchOverThreeCycles() public {
        (EngineVault vault, MockVolatilityOracle oracle,,,, MockPairFull pair,) =
            _deployVault(VolatilityOracle.Regime.NORMAL, 1);

        pair.setReserves(500e18, 500e18);
        pair.setTotalSupply(1000e18);
        pair.setBalance(address(vault), 1e18);

        oracle.setSnapshotCount(1);

        vm.warp(100);
        oracle.setRegime(VolatilityOracle.Regime.NORMAL);
        vault.cycle();
        assertEq(uint256(vault.currentRegime()), uint256(VolatilityOracle.Regime.NORMAL));

        vm.warp(102);
        oracle.setRegime(VolatilityOracle.Regime.STORM);
        vault.cycle();
        assertEq(uint256(vault.currentRegime()), uint256(VolatilityOracle.Regime.STORM));

        vm.warp(104);
        oracle.setRegime(VolatilityOracle.Regime.CALM);
        vault.cycle();
        assertEq(uint256(vault.currentRegime()), uint256(VolatilityOracle.Regime.CALM));
    }
}
