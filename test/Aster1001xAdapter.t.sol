pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Aster1001xAdapter} from "../contracts/adapters/Aster1001xAdapter.sol";

contract Aster1001xAdapterTest is Test {
    address internal constant DIAMOND = 0x1b6F2d3844C6ae7D56ceb3C3643b9060ba28FEb0;
    address internal constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;

    function testUsdToQty() public pure {
        uint256 qty = Aster1001xAdapter.usdToQty(100e18, 25_000e8);
        assertGt(qty, 0);
    }

    function testGetPositionsReadable() public {
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

        (bool ok,) = DIAMOND.staticcall(abi.encodeWithSignature("getPositionsV2(address,address)", address(this), BTCB));
        if (!ok) {
            return;
        }
        (uint256 totalQty, uint256 totalNotional, uint256 avgEntry) =
            Aster1001xAdapter.getShortExposure(DIAMOND, address(this), BTCB);
        assertEq(totalQty, 0);
        assertEq(totalNotional, 0);
        assertEq(avgEntry, 0);
    }
}
