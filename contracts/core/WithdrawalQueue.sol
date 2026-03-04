pragma solidity ^0.8.24;

import {EngineVault} from "./EngineVault.sol";
import {IERC20} from "../interfaces/IERC20.sol";

contract WithdrawalQueue {
    struct Request {
        address receiver;
        uint256 shares;
        uint256 claimedShares;
        uint256 requestedAt;
        bool closed;
    }

    EngineVault public immutable vault;
    IERC20 public immutable asset;

    uint16 public immutable claimBountyBps;
    uint16 public immutable maxClaimBountyBps;

    uint256 public nextRequestId;
    mapping(uint256 => Request) public requests;
    uint256 private reentrancyLock;

    event WithdrawRequested(address indexed caller, uint256 indexed requestId, uint256 shares);
    event WithdrawClaimed(
        address indexed caller,
        uint256 indexed requestId,
        uint256 sharesRedeemed,
        uint256 assetsTransferred,
        uint256 bounty
    );

    modifier nonReentrant() {
        require(reentrancyLock == 0, "REENTRANCY");
        reentrancyLock = 1;
        _;
        reentrancyLock = 0;
    }

    constructor(EngineVault vault_, IERC20 asset_, uint16 claimBountyBps_, uint16 maxClaimBountyBps_) {
        vault = vault_;
        asset = asset_;
        claimBountyBps = claimBountyBps_;
        maxClaimBountyBps = maxClaimBountyBps_;
    }

    function requestWithdraw(uint256 shares, address receiver) external nonReentrant returns (uint256 requestId) {
        require(shares > 0, "ZERO_SHARES");
        require(receiver != address(0), "ZERO_RECEIVER");

        requestId = nextRequestId++;
        requests[requestId] =
            Request({receiver: receiver, shares: shares, claimedShares: 0, requestedAt: block.timestamp, closed: false});
        require(vault.transferFrom(msg.sender, address(this), shares), "TRANSFER_SHARES");

        emit WithdrawRequested(msg.sender, requestId, shares);
    }

    function claimWithdraw(uint256 requestId) external nonReentrant {
        Request storage req = requests[requestId];
        require(!req.closed, "CLOSED");
        require(req.shares > 0, "INVALID_REQUEST");

        uint256 remainingShares = req.shares - req.claimedShares;
        if (remainingShares == 0) {
            req.closed = true;
            return;
        }

        uint256 assetsOwed = vault.previewRedeem(remainingShares);
        uint256 available = asset.balanceOf(address(vault));

        if (available == 0) {
            vault.unwindForWithdraw(assetsOwed);
            return;
        }

        uint256 assetsToWithdraw = available >= assetsOwed ? assetsOwed : available;
        uint256 sharesToRedeem = vault.previewDeposit(assetsToWithdraw);
        if (sharesToRedeem > remainingShares) {
            sharesToRedeem = remainingShares;
        }
        if (sharesToRedeem == 0) {
            return;
        }

        req.claimedShares += sharesToRedeem;
        if (req.claimedShares >= req.shares) {
            req.closed = true;
        }

        uint256 assetsReceived = vault.redeem(sharesToRedeem, address(this), address(this));
        uint256 bounty = _calculateClaimBounty(assetsReceived);
        uint256 toReceiver = assetsReceived - bounty;

        if (bounty > 0) {
            require(asset.transfer(msg.sender, bounty), "BOUNTY_TRANSFER");
        }
        require(asset.transfer(req.receiver, toReceiver), "RECEIVER_TRANSFER");

        emit WithdrawClaimed(msg.sender, requestId, sharesToRedeem, assetsReceived, bounty);

        if (available < assetsOwed) {
            vault.unwindForWithdraw(assetsOwed - assetsToWithdraw);
        }
    }

    function _calculateClaimBounty(uint256 assetsReceived) internal view returns (uint256) {
        if (claimBountyBps == 0) {
            return 0;
        }
        uint256 bounty = (assetsReceived * claimBountyBps) / 10000;
        uint256 maxBounty = (assetsReceived * maxClaimBountyBps) / 10000;
        return bounty > maxBounty ? maxBounty : bounty;
    }
}
