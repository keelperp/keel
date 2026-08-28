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

    event Accrued(address indexed token, address indexed creator, uint256 creatorCut, uint256 protocolCut);
    event Claimed(address indexed creator, uint256 amount);

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

    function sweepProtocol(address to) external returns (uint256 amount) {
        require(msg.sender == custody, "only custody");
        require(to != address(0) && to != address(this), "bad recipient");
        amount = protocolAccrued;
        protocolAccrued = 0;
        if (amount > 0) require(base.transfer(to, amount), "transfer");
    }
}
