// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LevVault} from "./LevVault.sol";

/// @notice Deploys LevVaults and is the only authority on which ones are real.
///
///         A curve must never accept a caller-supplied vault address. `targetLeverage() > 0`
///         proves an interface exists, not that the contract is ours — anyone could pass a
///         look-alike whose `mint()` keeps the deposit. Provenance has to come from a
///         registry the caller cannot write to.
contract VaultFactory {
    /// @dev Immutable. Whoever may list new vaults is fixed at deploy and cannot be transferred.
    address public immutable curator;

    mapping(address => bool) public isVault;
    address[] public vaults;

    event VaultCreated(address indexed vault, address indexed collateral, uint256 leverage, bool isLong);

    constructor(address _curator) {
        require(_curator != address(0), "curator zero");
        curator = _curator;
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function create(LevVault.Config calldata c) external returns (address vault) {
        require(msg.sender == curator, "only curator");
        LevVault v = new LevVault(c);
        vault = address(v);
        isVault[vault] = true;
        vaults.push(vault);
        emit VaultCreated(vault, c.collateral_, c.targetLeverage_, c.isLong_);
    }
}
