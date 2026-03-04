pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AsterAlpAdapter} from "../contracts/adapters/AsterAlpAdapter.sol";
import {IAsterDiamond} from "../contracts/interfaces/IAsterDiamond.sol";

contract AsterAlpAdapterHarness {
    function alpBalance(address diamond, address account) external view returns (uint256) {
        return AsterAlpAdapter.getAlpBalance(diamond, account);
    }

    function canBurn(address diamond) external view returns (bool) {
        return AsterAlpAdapter.canBurn(diamond);
    }
}

contract AsterAlpAdapterTest is Test {
    address internal constant DIAMOND = 0x1b6F2d3844C6ae7D56ceb3C3643b9060ba28FEb0;

    AsterAlpAdapterHarness internal harness;

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

        harness = new AsterAlpAdapterHarness();
    }

    function testAlpBalanceReadable() public view {
        if (address(harness) == address(0)) {
            return;
        }
        (bool ok,) = DIAMOND.staticcall(abi.encodeWithSignature("ALP()"));
        if (!ok) {
            return;
        }
        uint256 balance = harness.alpBalance(DIAMOND, address(this));
        assertEq(balance, 0);
    }

    function testCanBurnReadable() public view {
        if (address(harness) == address(0)) {
            return;
        }
        (bool ok,) = DIAMOND.staticcall(abi.encodeWithSignature("coolingDuration()"));
        if (!ok) {
            return;
        }
        harness.canBurn(DIAMOND);
    }
}
