// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Min} from "./interfaces/IVenus.sol";

/// @notice Accrues trading fees in the base asset. Creator fees never expire.
contract FeeVault {
    uint256 public constant CREATOR_SHARE_BPS = 4000;
    uint256 internal constant BPS = 10_000;

    IERC20Min public immutable base;
    address public immutable bonding;
    /// @dev Immutable, unlike `owner`. Whoever can move protocol fees is fixed at deploy.
    address public immutable custody;

    mapping(address => uint256) public claimable;
    uint256 public protocolAccrued;

    /// @dev There is no POL here to lock — launch LP is burnt into LPLock forever. The one
    ///      thing the protocol *can* take is its fee share, so that is what a lock binds.
    ///      Same rules as the house LP-lock standard: off by default, custody only, one call
    ///      adds a day onto whatever is already standing, no unlock, hard ceiling.
    uint256 public constant MAX_LOCK_HORIZON = 30 days;
    uint256 public feeUnlockTime;

    event Accrued(address indexed token, address indexed creator, uint256 creatorCut, uint256 protocolCut);
    event Claimed(address indexed creator, uint256 amount);
    event FeesLocked(uint256 unlockTime);

    constructor(address _base, address _bonding, address _custody) {
        require(_custody != address(0), "custody zero");
        base = IERC20Min(_base);
        bonding = _bonding;
        custody = _custody;
    }

    /// @dev The curve transfers the fee in, then calls this to book it.
    function accrue(address token, address creator, uint256 amount) external {
        require(msg.sender == bonding, "only bonding");
        uint256 creatorCut = amount * CREATOR_SHARE_BPS / BPS;
        claimable[creator] += creatorCut;
        protocolAccrued += amount - creatorCut;
        emit Accrued(token, creator, creatorCut, amount - creatorCut);
    }

    function claim(address to) external returns (uint256 amount) {
        require(to != address(0), "to zero");
        amount = claimable[msg.sender];
        require(amount > 0, "nothing");
        claimable[msg.sender] = 0;
        require(base.transfer(to, amount), "transfer");
        emit Claimed(msg.sender, amount);
    }

    /// @notice Adds one day onto the standing lock. Never shortens it, and cannot be undone.
    ///         An expired lock is not an allowance — the next call starts from today.
    function lockFees() external returns (uint256) {
        require(msg.sender == custody, "only custody");
        uint256 base_ = block.timestamp > feeUnlockTime ? block.timestamp : feeUnlockTime;
        uint256 next = base_ + 1 days;
        require(next <= block.timestamp + MAX_LOCK_HORIZON, "over horizon");
        feeUnlockTime = next;
        emit FeesLocked(next);
        return next;
    }

    function feesAreLocked() external view returns (bool) {
        return block.timestamp < feeUnlockTime;
    }

    function sweepProtocol(address to) external returns (uint256 amount) {
        require(msg.sender == custody, "only custody");
        require(block.timestamp >= feeUnlockTime, "fees locked");
        require(to != address(0) && to != address(this), "bad recipient");
        amount = protocolAccrued;
        protocolAccrued = 0;
        if (amount > 0) require(base.transfer(to, amount), "transfer");
    }
}
