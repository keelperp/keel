// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "./ERC20.sol";

/// @notice One launch's ERC-20. Fixed supply, no tax, no blacklist, no owner.
///         Before graduation transfers are confined to the curve, so nobody can
///         seed a rival pool and strand the launch. That guard lifts once and
///         can never be re-armed.
contract LaunchToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    address public immutable bonding;
    bool public unrestricted;

    string public description;
    string public image;
    string[3] public links;

    constructor(
        string memory _name,
        string memory _symbol,
        string memory _description,
        string memory _image,
        string[3] memory _links
    ) ERC20(_name, _symbol) {
        bonding = msg.sender;
        description = _description;
        image = _image;
        links = _links;
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice Called once by the curve at graduation. There is no way back.
    function lift() external {
        require(msg.sender == bonding, "only bonding");
        unrestricted = true;
    }

    function _guard(address from, address to) internal view {
        if (unrestricted) return;
        require(from == bonding || to == bonding, "pre-graduation");
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _guard(msg.sender, to);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _guard(from, to);
        return super.transferFrom(from, to, amount);
    }
}
