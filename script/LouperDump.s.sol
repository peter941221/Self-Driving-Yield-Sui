pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IDiamondLoupe} from "../contracts/interfaces/IDiamondLoupe.sol";

contract LouperDump is Script {
    function run() external view {
        address diamond = vm.envOr("ASTER_DIAMOND", address(0x1b6F2d3844C6ae7D56ceb3C3643b9060ba28FEb0));
        IDiamondLoupe loupe = IDiamondLoupe(diamond);

        address[] memory facets = loupe.facetAddresses();
        console2.log("FacetCount", facets.length);

        for (uint256 i = 0; i < facets.length; i++) {
            console2.log("Facet", facets[i]);
            bytes4[] memory selectors = loupe.facetFunctionSelectors(facets[i]);
            console2.log("SelectorCount", selectors.length);
            for (uint256 j = 0; j < selectors.length; j++) {
                console2.logBytes4(selectors[j]);
            }
        }
    }
}
