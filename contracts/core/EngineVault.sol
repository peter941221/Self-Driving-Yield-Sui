pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IPancakePairV2} from "../interfaces/IPancakePairV2.sol";
import {VolatilityOracle} from "./VolatilityOracle.sol";
import {AsterAlpAdapter} from "../adapters/AsterAlpAdapter.sol";
import {Aster1001xAdapter} from "../adapters/Aster1001xAdapter.sol";
import {PancakeV2Adapter} from "../adapters/PancakeV2Adapter.sol";
import {FlashRebalancer, IFlashRebalanceHook} from "../adapters/FlashRebalancer.sol";
import {PancakeLibrary} from "../libs/PancakeLibrary.sol";
import {MathLib} from "../libs/MathLib.sol";
import {ITradingReader} from "../interfaces/ITradingReader.sol";

contract EngineVault is IFlashRebalanceHook {
    using MathLib for uint256;

    IERC20 public immutable asset;
    address public immutable asterDiamond;
    address public immutable pancakeFactory;
    address public immutable v2Pair;
    address public immutable pairBase;
    address public immutable pairQuote;
    address public immutable bnbUsdtPair;
    address public immutable flashRebalancer;
    VolatilityOracle public immutable volatilityOracle;
    bool public immutable enableExternalCalls;
    bool public immutable baseIsToken0;

    uint256 public immutable minCycleInterval;
    uint16 public immutable rebalanceThresholdBps;
    uint16 public immutable deltaBandBps;
    uint16 public immutable profitBountyBps;
    uint16 public immutable maxBountyBps;
    uint16 public immutable bufferCapBps;
    uint16 public immutable calmAlpBps;
    uint16 public immutable calmLpBps;
    uint16 public immutable normalAlpBps;
    uint16 public immutable normalLpBps;
    uint16 public immutable stormAlpBps;
    uint16 public immutable stormLpBps;
    uint8 public immutable safeCycleThreshold;
    uint256 public immutable maxGasPrice;
    uint16 public immutable swapSlippageBps;

    uint256 public lastCycleTimestamp;
    uint256 public lastTotalAssets;
    uint256 public lastKnownNav;
    uint8 public safeCycleCount;
    bool private inFlashRebalance;
    address public flashBorrowedToken;
    uint256 public flashBorrowedAmount;
    uint256 private reentrancyLock;

    enum RiskMode {
        NORMAL,
        ONLY_UNWIND
    }

    RiskMode public riskMode;

    VolatilityOracle.Regime public currentRegime;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event CycleExecuted(address indexed caller, VolatilityOracle.Regime regime, uint256 bounty, uint256 timestamp);
    event RegimeSwitched(VolatilityOracle.Regime oldRegime, VolatilityOracle.Regime newRegime, uint256 volatilityBps);
    event RiskModeChanged(RiskMode oldMode, RiskMode newMode);
    event RebalancePlanned(int256 alpDelta, int256 lpDelta, uint256 totalValue);
    event FlashBorrowed(address indexed token, uint256 amount);
    event FlashRepaid(address indexed token, uint256 amount);
    event UnwindForWithdraw(uint256 amount);

    modifier nonReentrant() {
        require(reentrancyLock == 0, "REENTRANCY");
        reentrancyLock = 1;
        _;
        reentrancyLock = 0;
    }

    struct Addresses {
        IERC20 asset;
        address asterDiamond;
        address pancakeFactory;
        address v2Pair;
        address pairBase;
        address pairQuote;
        address bnbUsdtPair;
        VolatilityOracle volatilityOracle;
        address flashRebalancer;
    }

    struct Config {
        bool enableExternalCalls;
        uint256 minCycleInterval;
        uint16 rebalanceThresholdBps;
        uint16 deltaBandBps;
        uint16 profitBountyBps;
        uint16 maxBountyBps;
        uint16 bufferCapBps;
        uint16 calmAlpBps;
        uint16 calmLpBps;
        uint16 normalAlpBps;
        uint16 normalLpBps;
        uint16 stormAlpBps;
        uint16 stormLpBps;
        uint8 safeCycleThreshold;
        uint256 maxGasPrice;
        uint16 swapSlippageBps;
    }

    constructor(Addresses memory addresses, Config memory config) {
        asset = addresses.asset;
        asterDiamond = addresses.asterDiamond;
        pancakeFactory = addresses.pancakeFactory;
        v2Pair = addresses.v2Pair;
        pairBase = addresses.pairBase;
        pairQuote = addresses.pairQuote;
        bnbUsdtPair = addresses.bnbUsdtPair;
        volatilityOracle = addresses.volatilityOracle;
        flashRebalancer = addresses.flashRebalancer;
        enableExternalCalls = config.enableExternalCalls;
        minCycleInterval = config.minCycleInterval;
        rebalanceThresholdBps = config.rebalanceThresholdBps;
        deltaBandBps = config.deltaBandBps;
        profitBountyBps = config.profitBountyBps;
        maxBountyBps = config.maxBountyBps;
        bufferCapBps = config.bufferCapBps;
        calmAlpBps = config.calmAlpBps;
        calmLpBps = config.calmLpBps;
        normalAlpBps = config.normalAlpBps;
        normalLpBps = config.normalLpBps;
        stormAlpBps = config.stormAlpBps;
        stormLpBps = config.stormLpBps;
        safeCycleThreshold = config.safeCycleThreshold;
        maxGasPrice = config.maxGasPrice;
        swapSlippageBps = config.swapSlippageBps;
        currentRegime = VolatilityOracle.Regime.NORMAL;

        if (addresses.v2Pair != address(0) && addresses.pairBase != address(0)) {
            baseIsToken0 = IPancakePairV2(addresses.v2Pair).token0() == addresses.pairBase;
        } else {
            baseIsToken0 = false;
        }
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ALLOWANCE");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        require(assets > 0, "ZERO_ASSETS");
        shares = previewDeposit(assets);
        require(shares > 0, "ZERO_SHARES");

        totalSupply += shares;
        balanceOf[receiver] += shares;

        require(asset.transferFrom(msg.sender, address(this), assets), "TRANSFER_IN");
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "ZERO_SHARES");
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) {
                require(allowed >= shares, "ALLOWANCE");
                allowance[owner][msg.sender] = allowed - shares;
            }
        }

        assets = previewRedeem(shares);
        balanceOf[owner] -= shares;
        totalSupply -= shares;

        require(asset.transfer(receiver, assets), "TRANSFER_OUT");
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function totalAssets() public view returns (uint256) {
        (uint256 alpValue, uint256 lpValue, uint256 cashValue) = _getPortfolioValues();
        return alpValue + lpValue + cashValue;
    }

    function previewDeposit(uint256 assets) public view returns (uint256 shares) {
        uint256 supply = totalSupply;
        uint256 total = totalAssets();
        return supply == 0 || total == 0 ? assets : (assets * supply) / total;
    }

    function previewRedeem(uint256 shares) public view returns (uint256 assets) {
        uint256 supply = totalSupply;
        uint256 total = totalAssets();
        return supply == 0 || total == 0 ? 0 : (shares * total) / supply;
    }

    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function cycle() external nonReentrant {
        require(block.timestamp >= lastCycleTimestamp + minCycleInterval, "CYCLE_INTERVAL");

        _updateRegime();
        _circuitBreakerCheck();
        _rebalanceAssets();
        _rebalanceHedge();

        uint256 bounty = _calculateBounty();
        if (bounty > 0) {
            require(asset.transfer(msg.sender, bounty), "BOUNTY_TRANSFER");
        }

        lastCycleTimestamp = block.timestamp;
        lastTotalAssets = totalAssets();
        emit CycleExecuted(msg.sender, currentRegime, bounty, block.timestamp);
    }

    // slither-disable-next-line reentrancy-no-eth
    function onFlashRebalance(address tokenBorrowed, address repayToken, uint256 borrowedAmount, uint256 repayAmount)
        external
        nonReentrant
    {
        require(msg.sender == flashRebalancer, "ONLY_REBALANCER");
        require(tokenBorrowed != address(0), "ZERO_BORROW");
        if (!enableExternalCalls) {
            require(IERC20(repayToken).transfer(msg.sender, repayAmount), "FLASH_REPAY");
            return;
        }

        inFlashRebalance = true;
        flashBorrowedToken = tokenBorrowed;
        flashBorrowedAmount = borrowedAmount;
        emit FlashBorrowed(tokenBorrowed, borrowedAmount);
        _removeAllLp();
        _rebalanceAssets();
        _rebalanceHedge();
        inFlashRebalance = false;

        flashBorrowedToken = address(0);
        flashBorrowedAmount = 0;
        emit FlashRepaid(repayToken, repayAmount);

        _ensureRepayToken(repayToken, repayAmount);
        require(IERC20(repayToken).transfer(msg.sender, repayAmount), "FLASH_REPAY");
    }

    function unwindForWithdraw(uint256 amount) external nonReentrant {
        if (!enableExternalCalls) {
            emit UnwindForWithdraw(amount);
            return;
        }
        if (asterDiamond != address(0) && pairBase != address(0)) {
            ITradingReader.Position[] memory positions =
                Aster1001xAdapter.getPositions(asterDiamond, address(this), pairBase);
            for (uint256 i = 0; i < positions.length; i++) {
                Aster1001xAdapter.closeTrade(asterDiamond, positions[i].positionHash);
            }
        }

        if (v2Pair != address(0) && pairBase != address(0) && pairQuote != address(0)) {
            uint256 lpBal = IERC20(v2Pair).balanceOf(address(this));
            if (lpBal > 0) {
                PancakeV2Adapter.removeLiquidity(pairBase, pairQuote, lpBal, 50);
            }
        }

        if (asterDiamond != address(0) && AsterAlpAdapter.canBurn(asterDiamond)) {
            uint256 alpBal = AsterAlpAdapter.getAlpBalance(asterDiamond, address(this));
            if (alpBal > 0) {
                AsterAlpAdapter.burnAlp(asterDiamond, address(asset), alpBal, 0);
            }
        }

        emit UnwindForWithdraw(amount);
    }

    // slither-disable-next-line reentrancy-benign
    function _updateRegime() internal {
        if (address(volatilityOracle) == address(0) || volatilityOracle.pair() == address(0)) {
            return;
        }

        volatilityOracle.recordSnapshot();
        VolatilityOracle.Regime newRegime = currentRegime;
        if (volatilityOracle.snapshotCount() < volatilityOracle.minSamples()) {
            newRegime = VolatilityOracle.Regime.NORMAL;
        } else {
            newRegime = volatilityOracle.getRegime();
        }

        if (newRegime != currentRegime) {
            emit RegimeSwitched(currentRegime, newRegime, volatilityOracle.getVolatilityBps());
            currentRegime = newRegime;
        }
    }

    function _circuitBreakerCheck() internal {
        bool triggered = false;

        if (asterDiamond != address(0)) {
            uint256 nav = AsterAlpAdapter.getAlpNAV(asterDiamond);
            if (nav > 0 && lastKnownNav > 0) {
                uint256 navDropBps = (lastKnownNav - nav) * 10000 / lastKnownNav;
                if (navDropBps > 1000) {
                    triggered = true;
                }
            }
            if (nav > 0) {
                lastKnownNav = nav;
            }
        }

        uint256 oraclePrice = _getOraclePrice1e18();
        uint256 spotPrice = _getBasePrice1e18();
        if (oraclePrice > 0 && spotPrice > 0) {
            uint256 deviationBps = MathLib.absDiff(oraclePrice, spotPrice) * 10000 / oraclePrice;
            if (deviationBps > 500) {
                triggered = true;
            }
        }

        if (triggered && riskMode != RiskMode.ONLY_UNWIND) {
            RiskMode old = riskMode;
            riskMode = RiskMode.ONLY_UNWIND;
            safeCycleCount = 0;
            emit RiskModeChanged(old, riskMode);
        }

        if (!triggered && riskMode == RiskMode.ONLY_UNWIND) {
            safeCycleCount++;
            if (safeCycleCount >= safeCycleThreshold) {
                RiskMode oldMode = riskMode;
                riskMode = RiskMode.NORMAL;
                safeCycleCount = 0;
                emit RiskModeChanged(oldMode, riskMode);
            }
        }
    }

    function _rebalanceAssets() internal {
        (uint256 alpValue, uint256 lpValue, uint256 cashValue) = _getPortfolioValues();
        uint256 totalValue = alpValue + lpValue + cashValue;
        if (totalValue == 0) {
            return;
        }

        (uint16 targetAlpBps, uint16 targetLpBps) = _computeTargetAllocation();
        uint256 targetAlpValue = totalValue * targetAlpBps / 10000;
        uint256 targetLpValue = totalValue * targetLpBps / 10000;

        int256 alpDelta = int256(targetAlpValue) - int256(alpValue);
        int256 lpDelta = int256(targetLpValue) - int256(lpValue);

        uint256 alpDeviation = MathLib.absDiff(targetAlpValue, alpValue);
        uint256 lpDeviation = MathLib.absDiff(targetLpValue, lpValue);
        uint256 deviation = alpDeviation > lpDeviation ? alpDeviation : lpDeviation;
        uint256 deviationBps = deviation * 10000 / totalValue;
        if (deviationBps < rebalanceThresholdBps) {
            return;
        }

        emit RebalancePlanned(alpDelta, lpDelta, totalValue);

        if (!enableExternalCalls) {
            return;
        }

        if (riskMode == RiskMode.ONLY_UNWIND) {
            if (alpDelta < 0) {
                _reduceAlp(uint256(-alpDelta));
            }
            if (lpDelta < 0) {
                _reduceLp(uint256(-lpDelta));
            }
            return;
        }

        if (
            enableExternalCalls && !inFlashRebalance && flashRebalancer != address(0)
                && currentRegime == VolatilityOracle.Regime.STORM
        ) {
            uint256 borrowAmount = _calcFlashBorrowAmount(lpDelta, totalValue);
            if (borrowAmount > 0) {
                FlashRebalancer(flashRebalancer).executeFlashRebalance(
                    FlashRebalancer.RebalanceParams({borrowAmount: borrowAmount, borrowToken0: baseIsToken0})
                );
                return;
            }
        }

        if (alpDelta > 0) {
            _increaseAlp(uint256(alpDelta));
        } else if (alpDelta < 0) {
            _reduceAlp(uint256(-alpDelta));
        }

        if (lpDelta > 0) {
            _increaseLp(uint256(lpDelta));
        } else if (lpDelta < 0) {
            _reduceLp(uint256(-lpDelta));
        }
    }

    function _rebalanceHedge() internal {
        if (!enableExternalCalls || asterDiamond == address(0) || v2Pair == address(0) || pairBase == address(0)) {
            return;
        }

        (uint256 amtBase, uint256 amtQuote) =
            PancakeV2Adapter.getUnderlyingAmountsForTokens(v2Pair, address(this), pairBase);
        // slither-disable-next-line divide-before-multiply
        uint256 lpBaseQty1e10 = (amtBase * 1e10) / 1e18;
        (uint256 hedgeQty1e10, uint256 hedgeNotional, uint256 avgEntryPrice) =
            Aster1001xAdapter.getShortExposure(asterDiamond, address(this), pairBase);
        if (amtBase == 0 && amtQuote == 0) {
            return;
        }
        if (hedgeNotional == 0 && avgEntryPrice == 0) {
            hedgeNotional = 0;
        }
        if (lpBaseQty1e10 == 0) {
            return;
        }

        // slither-disable-next-line divide-before-multiply
        uint256 band = (lpBaseQty1e10 * deltaBandBps) / 10000;
        if (lpBaseQty1e10 > hedgeQty1e10 + band) {
            uint256 deltaQty = lpBaseQty1e10 - hedgeQty1e10;
            uint256 price1e8 = _getBasePrice1e8();
            uint256 usdNotional = deltaQty * price1e8;
            uint256 margin = usdNotional / 10;
            uint256 cashBalance = asset.balanceOf(address(this));
            if (margin > cashBalance) margin = cashBalance;
            if (margin > 0 && price1e8 > 0) {
                Aster1001xAdapter.openShort(asterDiamond, pairBase, address(asset), margin, deltaQty, price1e8);
            }
        } else if (hedgeQty1e10 > lpBaseQty1e10 + band) {
            ITradingReader.Position[] memory positions =
                Aster1001xAdapter.getPositions(asterDiamond, address(this), pairBase);
            for (uint256 i = 0; i < positions.length; i++) {
                Aster1001xAdapter.closeTrade(asterDiamond, positions[i].positionHash);
            }
        }
    }

    function _increaseAlp(uint256 value) internal {
        if (asterDiamond == address(0)) {
            return;
        }
        uint256 cashBalance = asset.balanceOf(address(this));
        uint256 amount = value > cashBalance ? cashBalance : value;
        if (amount == 0) {
            return;
        }
        uint256 alpReceived = AsterAlpAdapter.mintAlp(asterDiamond, address(asset), amount, 0, false);
        if (alpReceived == 0) {
            return;
        }
    }

    function _reduceAlp(uint256 value) internal {
        if (asterDiamond == address(0)) {
            return;
        }
        if (!AsterAlpAdapter.canBurn(asterDiamond)) {
            return;
        }
        uint256 nav = AsterAlpAdapter.getAlpNAV(asterDiamond);
        if (nav == 0) {
            return;
        }
        uint256 alpToBurn = (value * 1e18) / nav;
        if (alpToBurn == 0) {
            return;
        }
        uint256 tokenReceived = AsterAlpAdapter.burnAlp(asterDiamond, address(asset), alpToBurn, 0);
        if (tokenReceived == 0) {
            return;
        }
    }

    function _increaseLp(uint256 value) internal {
        if (v2Pair == address(0) || pairBase == address(0) || pairQuote == address(0)) {
            return;
        }
        uint256 basePrice = _getBasePrice1e18();
        if (basePrice == 0) {
            return;
        }
        uint256 quoteBalance = asset.balanceOf(address(this));
        uint256 baseBalance = IERC20(pairBase).balanceOf(address(this));
        if (quoteBalance == 0 && baseBalance == 0) {
            return;
        }

        uint256 quoteTarget = value / 2;
        // slither-disable-next-line divide-before-multiply
        uint256 baseTarget = quoteTarget * 1e18 / basePrice;

        if (baseBalance < baseTarget && quoteBalance > quoteTarget) {
            uint256 baseShort = baseTarget - baseBalance;
            uint256 quoteToSwap = baseShort * basePrice / 1e18;
            uint256 maxSwap = quoteBalance > quoteTarget ? quoteBalance - quoteTarget : 0;
            if (quoteToSwap > maxSwap) {
                quoteToSwap = maxSwap;
            }
            if (quoteToSwap > 0) {
                _swapQuoteToBase(quoteToSwap);
            }
        } else if (quoteBalance < quoteTarget && baseBalance > baseTarget) {
            uint256 quoteShort = quoteTarget - quoteBalance;
            uint256 baseToSwap = quoteShort * 1e18 / basePrice;
            uint256 maxSwapBase = baseBalance > baseTarget ? baseBalance - baseTarget : 0;
            if (baseToSwap > maxSwapBase) {
                baseToSwap = maxSwapBase;
            }
            if (baseToSwap > 0) {
                _swapBaseToQuote(baseToSwap);
            }
        }

        quoteBalance = asset.balanceOf(address(this));
        baseBalance = IERC20(pairBase).balanceOf(address(this));
        uint256 quoteToUse = quoteBalance > quoteTarget ? quoteTarget : quoteBalance;
        uint256 baseToUse = baseBalance > baseTarget ? baseTarget : baseBalance;
        if (quoteToUse == 0 || baseToUse == 0) {
            return;
        }

        (uint256 reserveBase, uint256 reserveQuote) = PancakeLibrary.getReserves(pancakeFactory, pairBase, pairQuote);
        if (reserveBase > 0 && reserveQuote > 0) {
            uint256 quoteOptimal = PancakeLibrary.quote(baseToUse, reserveBase, reserveQuote);
            if (quoteOptimal <= quoteToUse) {
                quoteToUse = quoteOptimal;
            } else {
                uint256 baseOptimal = PancakeLibrary.quote(quoteToUse, reserveQuote, reserveBase);
                baseToUse = baseOptimal;
            }
        }

        if (quoteToUse == 0 || baseToUse == 0) {
            return;
        }

        uint256 liquidity = PancakeV2Adapter.addLiquidity(pairBase, pairQuote, baseToUse, quoteToUse, swapSlippageBps);
        if (liquidity == 0) {
            return;
        }
    }

    function _reduceLp(uint256 value) internal {
        if (v2Pair == address(0) || pairBase == address(0) || pairQuote == address(0)) {
            return;
        }
        uint256 lpBal = IERC20(v2Pair).balanceOf(address(this));
        if (lpBal == 0) {
            return;
        }
        (uint256 alpValue, uint256 lpValue, uint256 cashValue) = _getPortfolioValues();
        uint256 totalValue = alpValue + lpValue + cashValue;
        if (lpValue == 0 || totalValue == 0) {
            return;
        }
        uint256 liquidityToRemove = (lpBal * value) / lpValue;
        if (liquidityToRemove > lpBal) {
            liquidityToRemove = lpBal;
        }
        if (liquidityToRemove == 0) {
            return;
        }
        (uint256 amountA, uint256 amountB) =
            PancakeV2Adapter.removeLiquidity(pairBase, pairQuote, liquidityToRemove, swapSlippageBps);
        if (amountA == 0 && amountB == 0) {
            return;
        }
    }

    function _removeAllLp() internal {
        if (v2Pair == address(0) || pairBase == address(0) || pairQuote == address(0)) {
            return;
        }
        uint256 lpBal = IERC20(v2Pair).balanceOf(address(this));
        if (lpBal == 0) {
            return;
        }
        (uint256 amountA, uint256 amountB) =
            PancakeV2Adapter.removeLiquidity(pairBase, pairQuote, lpBal, swapSlippageBps);
        if (amountA == 0 && amountB == 0) {
            return;
        }
    }

    function _swapQuoteToBase(uint256 amountIn) internal returns (uint256 amountOut) {
        if (pancakeFactory == address(0) || pairBase == address(0) || pairQuote == address(0)) {
            return 0;
        }
        (uint256 reserveIn, uint256 reserveOut) = PancakeLibrary.getReserves(pancakeFactory, pairQuote, pairBase);
        uint256 expectedOut = PancakeLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
        uint256 minOut = expectedOut * (10000 - swapSlippageBps) / 10000;
        amountOut = PancakeV2Adapter.swapExactTokensForTokens(pairQuote, pairBase, amountIn, minOut);
    }

    function _swapBaseToQuote(uint256 amountIn) internal returns (uint256 amountOut) {
        if (pancakeFactory == address(0) || pairBase == address(0) || pairQuote == address(0)) {
            return 0;
        }
        (uint256 reserveIn, uint256 reserveOut) = PancakeLibrary.getReserves(pancakeFactory, pairBase, pairQuote);
        uint256 expectedOut = PancakeLibrary.getAmountOut(amountIn, reserveIn, reserveOut);
        uint256 minOut = expectedOut * (10000 - swapSlippageBps) / 10000;
        amountOut = PancakeV2Adapter.swapExactTokensForTokens(pairBase, pairQuote, amountIn, minOut);
    }

    function _swapForExact(address tokenIn, address tokenOut, uint256 amountOut) internal returns (uint256 amountIn) {
        if (pancakeFactory == address(0)) {
            return 0;
        }
        (uint256 reserveIn, uint256 reserveOut) = PancakeLibrary.getReserves(pancakeFactory, tokenIn, tokenOut);
        amountIn = PancakeLibrary.getAmountIn(amountOut, reserveIn, reserveOut);
        uint256 actualOut = PancakeV2Adapter.swapExactTokensForTokens(tokenIn, tokenOut, amountIn, amountOut);
        if (actualOut < amountOut) {
            return 0;
        }
    }

    function _ensureRepayToken(address repayToken, uint256 repayAmount) internal {
        uint256 balance = IERC20(repayToken).balanceOf(address(this));
        if (balance >= repayAmount) {
            return;
        }

        uint256 shortfall = repayAmount - balance;
        if (repayToken == pairQuote && pairBase != address(0)) {
            _swapForExact(pairBase, pairQuote, shortfall);
        } else if (repayToken == pairBase && pairQuote != address(0)) {
            _swapForExact(pairQuote, pairBase, shortfall);
        }

        require(IERC20(repayToken).balanceOf(address(this)) >= repayAmount, "FLASH_REPAY");
    }

    function _calcFlashBorrowAmount(int256 lpDelta, uint256 totalValue) internal view returns (uint256 borrowAmount) {
        if (lpDelta == 0 || v2Pair == address(0)) {
            return 0;
        }
        uint256 absDelta = lpDelta > 0 ? uint256(lpDelta) : uint256(-lpDelta);
        if (absDelta < (totalValue * rebalanceThresholdBps) / 10000) {
            return 0;
        }
        uint256 basePrice = _getBasePrice1e18();
        if (basePrice == 0) {
            return 0;
        }
        uint256 borrowValue = absDelta / 2;
        // slither-disable-next-line divide-before-multiply
        borrowAmount = (borrowValue * 1e18) / basePrice;

        (uint112 r0, uint112 r1, uint32 blockTimestampLast) = IPancakePairV2(v2Pair).getReserves();
        if (blockTimestampLast == 0) {
            return 0;
        }
        uint256 reserveBase = baseIsToken0 ? uint256(r0) : uint256(r1);
        uint256 cap = reserveBase / 10;
        if (borrowAmount > cap) {
            borrowAmount = cap;
        }
    }

    function _calculateBounty() internal view returns (uint256) {
        uint256 currentAssets = totalAssets();
        uint256 profitSinceLastCycle = currentAssets > lastTotalAssets ? currentAssets - lastTotalAssets : 0;
        uint256 profitBounty = (profitSinceLastCycle * profitBountyBps) / 10000;

        uint256 gasPriceUsed = tx.gasprice > maxGasPrice ? maxGasPrice : tx.gasprice;
        uint256 minBounty = 0;
        uint256 bnbPrice = _getBnbPrice1e18();
        if (bnbPrice > 0) {
            uint256 estimatedGas = 500_000;
            minBounty = (gasPriceUsed * estimatedGas * bnbPrice) / 1e18;
            // slither-disable-next-line divide-before-multiply
            minBounty = (minBounty * 150) / 100;
        }

        uint256 bounty = profitBounty > minBounty ? profitBounty : minBounty;
        uint256 maxBounty = (currentAssets * maxBountyBps) / 10000;
        uint256 bufferCap = (currentAssets * bufferCapBps) / 10000;

        if (bounty > maxBounty) bounty = maxBounty;
        if (bounty > bufferCap) bounty = bufferCap;

        uint256 cashBalance = asset.balanceOf(address(this));
        if (bounty > cashBalance) bounty = cashBalance;
        return bounty;
    }

    function _getPortfolioValues() internal view returns (uint256 alpValue, uint256 lpValue, uint256 cashValue) {
        if (asterDiamond != address(0)) {
            alpValue = AsterAlpAdapter.getAlpValueInUsd(asterDiamond, address(this));
        }

        uint256 basePrice = _getBasePrice1e18();
        if (v2Pair != address(0) && pairBase != address(0)) {
            (uint256 amtBase, uint256 amtQuote) =
                PancakeV2Adapter.getUnderlyingAmountsForTokens(v2Pair, address(this), pairBase);
            uint256 baseValue = basePrice == 0 ? 0 : (amtBase * basePrice) / 1e18;
            lpValue = baseValue + amtQuote;
        }

        uint256 quoteBalance = asset.balanceOf(address(this));
        uint256 baseBalance = pairBase == address(0) ? 0 : IERC20(pairBase).balanceOf(address(this));
        if (flashBorrowedAmount > 0) {
            if (flashBorrowedToken == pairQuote) {
                quoteBalance = quoteBalance > flashBorrowedAmount ? quoteBalance - flashBorrowedAmount : 0;
            } else if (flashBorrowedToken == pairBase) {
                baseBalance = baseBalance > flashBorrowedAmount ? baseBalance - flashBorrowedAmount : 0;
            }
        }
        uint256 baseValueCash = basePrice == 0 ? 0 : (baseBalance * basePrice) / 1e18;
        cashValue = quoteBalance + baseValueCash;
    }

    function _computeTargetAllocation() internal view returns (uint16 alpBps, uint16 lpBps) {
        if (currentRegime == VolatilityOracle.Regime.CALM) {
            alpBps = calmAlpBps;
            lpBps = calmLpBps;
        } else if (currentRegime == VolatilityOracle.Regime.NORMAL) {
            alpBps = normalAlpBps;
            lpBps = normalLpBps;
        } else {
            alpBps = stormAlpBps;
            lpBps = stormLpBps;
        }
    }

    function _getBasePrice1e18() internal view returns (uint256) {
        if (v2Pair == address(0)) {
            return 0;
        }
        (uint112 r0, uint112 r1, uint32 blockTimestampLast) = IPancakePairV2(v2Pair).getReserves();
        if (blockTimestampLast == 0 || r0 == 0 || r1 == 0) {
            return 0;
        }
        return baseIsToken0 ? (uint256(r1) * 1e18) / uint256(r0) : (uint256(r0) * 1e18) / uint256(r1);
    }

    function _getBasePrice1e8() internal view returns (uint256) {
        uint256 price1e18 = _getBasePrice1e18();
        return price1e18 / 1e10;
    }

    function _getBnbPrice1e18() internal view returns (uint256) {
        if (bnbUsdtPair == address(0)) {
            return 0;
        }
        address token0 = IPancakePairV2(bnbUsdtPair).token0();
        (uint112 r0, uint112 r1, uint32 blockTimestampLast) = IPancakePairV2(bnbUsdtPair).getReserves();
        if (blockTimestampLast == 0 || r0 == 0 || r1 == 0) {
            return 0;
        }
        if (token0 == address(asset)) {
            return (uint256(r0) * 1e18) / uint256(r1);
        }
        return (uint256(r1) * 1e18) / uint256(r0);
    }

    function _getOraclePrice1e18() internal view returns (uint256) {
        if (address(volatilityOracle) == address(0)) {
            return 0;
        }
        return volatilityOracle.getTwapPrice1e18();
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
