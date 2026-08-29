// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LevVault} from "./LevVault.sol";

/// @notice Deploys LevVaults and is the only authority on which ones are real.
///
///         A curve must never accept a caller-supplied vault address. `targetLeverage() > 0`
///         proves an interface exists, not that the contract is ours — anyone could pass a
///         look-alike whose `mint()` keeps the deposit. Provenance has to come from a
///         registry the caller cannot write to.
///
///         The creation code arrives as calldata rather than being embedded, because an
///         embedded child grows the factory byte for byte: with LevVault inlined this
///         contract reached 23,921 bytes, 655 short of EIP-170, and every future line in
///         the vault would have pushed it over — a limit that only shows up on a real
///         deploy. Passing the code in and hashing it keeps the factory small AND keeps
///         provenance exact: only the one build whose hash was fixed at construction can
///         ever be deployed here.
contract VaultFactory {
    /// @dev Immutable. Whoever may list new vaults is fixed at deploy and cannot be transferred.
    address public immutable curator;
    /// @dev keccak256 of the approved LevVault creation code, without constructor args.
    bytes32 public immutable vaultCodeHash;

    mapping(address => bool) public isVault;
    address[] public vaults;

    event VaultCreated(address indexed vault, address indexed collateral, uint256 leverage, bool isLong);

    constructor(address _curator, bytes32 _vaultCodeHash) {
        require(_curator != address(0), "curator zero");
        require(_vaultCodeHash != bytes32(0), "code hash zero");
        curator = _curator;
        vaultCodeHash = _vaultCodeHash;
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function create(bytes calldata creationCode, LevVault.Config calldata c)
        external
        returns (address vault)
    {
        require(msg.sender == curator, "only curator");
        require(keccak256(creationCode) == vaultCodeHash, "unapproved code");

        bytes memory initCode = abi.encodePacked(creationCode, abi.encode(c));
        assembly {
            vault := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(vault != address(0), "create failed");

        isVault[vault] = true;
        vaults.push(vault);
        emit VaultCreated(vault, c.collateral_, c.targetLeverage_, c.isLong_);
    }
}
