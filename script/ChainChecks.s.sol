pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPancakeFactoryV2} from "../contracts/interfaces/IPancakeFactoryV2.sol";
import {IPancakePairV2} from "../contracts/interfaces/IPancakePairV2.sol";
import {IAsterDiamond} from "../contracts/interfaces/IAsterDiamond.sol";

contract ChainChecks is Script {
    function run() external view {
        address diamond = vm.envOr("ASTER_DIAMOND", address(0x1b6F2d3844C6ae7D56ceb3C3643b9060ba28FEb0));
        address factory = vm.envOr("PANCAKE_FACTORY", address(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73));
        address btcb = vm.envOr("BTCB", address(0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c));
        address usdt = vm.envOr("USDT", address(0x55d398326f99059fF775485246999027B3197955));

        address pair = IPancakeFactoryV2(factory).getPair(btcb, usdt);
        console2.log("Diamond", diamond);
        console2.log("Pair", pair);

        if (pair != address(0)) {
            (uint112 r0, uint112 r1,) = IPancakePairV2(pair).getReserves();
            console2.log("Token0", IPancakePairV2(pair).token0());
            console2.log("Token1", IPancakePairV2(pair).token1());
            console2.log("Reserve0", uint256(r0));
            console2.log("Reserve1", uint256(r1));
        }

        address alp = IAsterDiamond(diamond).ALP();
        console2.log("ALP", alp);
        console2.log("Cooldown", IAsterDiamond(diamond).coolingDuration());

        (bool ok, bytes memory data) =
            diamond.staticcall(abi.encodeWithSignature("lastMintedTimestamp(address)", address(this)));
        if (ok && data.length >= 32) {
            console2.log("LastMint", abi.decode(data, (uint256)));
        } else {
            console2.log("LastMint", uint256(0));
        }
    }
}
