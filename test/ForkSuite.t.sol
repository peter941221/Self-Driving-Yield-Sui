pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IPancakeFactoryV2} from "../contracts/interfaces/IPancakeFactoryV2.sol";
import {IPancakePairV2} from "../contracts/interfaces/IPancakePairV2.sol";
import {IAsterDiamond} from "../contracts/interfaces/IAsterDiamond.sol";

contract ForkSuiteTest is Test {
    address internal constant DIAMOND = 0x1b6F2d3844C6ae7D56ceb3C3643b9060ba28FEb0;
    address internal constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    bool internal forkReady;

    function setUp() public {
        string memory rpcUrl = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            forkReady = false;
            return;
        }
        uint256 forkBlock = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkBlock);
        }
        forkReady = true;
    }

    function testForkA_AsterAlpAddressReadable() public view {
        if (!forkReady) {
            return;
        }
        address alp = IAsterDiamond(DIAMOND).ALP();
        assertTrue(alp != address(0));
    }

    function testForkB_AsterCooldownReadable() public view {
        if (!forkReady) {
            return;
        }
        uint256 cooldown = IAsterDiamond(DIAMOND).coolingDuration();
        assertGt(cooldown, 0);
    }

    function testForkC_AsterAlpPriceReadable() public view {
        if (!forkReady) {
            return;
        }
        uint256 price = IAsterDiamond(DIAMOND).alpPrice();
        assertGt(price, 0);
    }

    function testForkD_PairExists() public view {
        if (!forkReady) {
            return;
        }
        address pair = IPancakeFactoryV2(FACTORY).getPair(BTCB, USDT);
        assertTrue(pair != address(0));
    }

    function testForkE_PairReservesNonZero() public view {
        if (!forkReady) {
            return;
        }
        address pair = IPancakeFactoryV2(FACTORY).getPair(BTCB, USDT);
        if (pair == address(0)) {
            return;
        }
        (uint112 reserve0, uint112 reserve1,) = IPancakePairV2(pair).getReserves();
        assertGt(uint256(reserve0), 0);
        assertGt(uint256(reserve1), 0);
    }

    function testForkF_GetPositionsReadable() public view {
        if (!forkReady) {
            return;
        }
        (bool ok,) = DIAMOND.staticcall(
            abi.encodeWithSignature("getPositionsV2(address,address)", address(this), BTCB)
        );
        assertTrue(ok);
    }
}
