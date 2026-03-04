pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IAsterDiamond} from "../interfaces/IAsterDiamond.sol";

library AsterAlpAdapter {
    function mintAlp(address diamond, address tokenIn, uint256 amount, uint256 minAlp, bool stake)
        internal
        returns (uint256 alpReceived)
    {
        require(IERC20(tokenIn).approve(diamond, amount), "APPROVE");
        alpReceived = IAsterDiamond(diamond).mintAlp(tokenIn, amount, minAlp, stake);
    }

    function burnAlp(address diamond, address tokenOut, uint256 alpAmount, uint256 minOut)
        internal
        returns (uint256 tokenReceived)
    {
        require(canBurn(diamond), "ALP_COOLDOWN");
        tokenReceived = IAsterDiamond(diamond).burnAlp(tokenOut, alpAmount, minOut, address(this));
    }

    function getAlpBalance(address diamond, address account) internal view returns (uint256) {
        address alpToken = IAsterDiamond(diamond).ALP();
        return IERC20(alpToken).balanceOf(account);
    }

    function canBurn(address diamond) internal view returns (bool) {
        uint256 cooldown = IAsterDiamond(diamond).coolingDuration();
        (bool ok, bytes memory data) =
            diamond.staticcall(abi.encodeWithSignature("lastMintedTimestamp(address)", address(this)));
        if (!ok || data.length < 32) {
            return false;
        }
        uint256 lastMint = abi.decode(data, (uint256));
        return block.timestamp >= lastMint + cooldown;
    }

    function getAlpNAV(address diamond) internal view returns (uint256) {
        return IAsterDiamond(diamond).alpPrice();
    }

    function getAlpValueInUsd(address diamond, address account) internal view returns (uint256) {
        uint256 balance = getAlpBalance(diamond, account);
        uint256 nav = getAlpNAV(diamond);
        return (balance * nav) / 1e18;
    }
}
