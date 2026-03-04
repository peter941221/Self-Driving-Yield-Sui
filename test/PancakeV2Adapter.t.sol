pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PancakeV2Adapter} from "../contracts/adapters/PancakeV2Adapter.sol";
import {IPancakeFactoryV2} from "../contracts/interfaces/IPancakeFactoryV2.sol";

contract PancakeV2AdapterHarness {
    function spotPrice1e18(address pair) external view returns (uint256) {
        return PancakeV2Adapter.getSpotPrice1e18(pair);
    }

    function underlying(address pair, address account) external view returns (uint256 amt0, uint256 amt1) {
        return PancakeV2Adapter.getUnderlyingAmounts(pair, account);
    }
}

contract PancakeV2AdapterTest is Test {
    address internal constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    PancakeV2AdapterHarness internal harness;
    address internal pair;

    function setUp() public {
        string memory rpcUrl = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            return;
        }
        uint256 forkBlock = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork(rpcUrl);
        } else {
            vm.createSelectFork(rpcUrl, forkBlock);
        }

        harness = new PancakeV2AdapterHarness();
        pair = IPancakeFactoryV2(FACTORY).getPair(BTCB, USDT);
    }

    function testSpotPriceNonZero() public view {
        if (pair == address(0)) {
            return;
        }
        uint256 price = harness.spotPrice1e18(pair);
        assertGt(price, 0);
    }

    function testUnderlyingZeroForNoLP() public view {
        if (pair == address(0)) {
            return;
        }
        (uint256 amt0, uint256 amt1) = harness.underlying(pair, address(this));
        assertEq(amt0, 0);
        assertEq(amt1, 0);
    }
}
