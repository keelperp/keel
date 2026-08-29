// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";

/// @notice Resolves the Flap Guardian for the current chain. Kept next to the beacon so
///         the upgrade authority is decided by chain id and not by a constructor argument.
library LeverGuardian {
    function resolve() internal view returns (address guardian) {
        uint256 chainId = block.chainid;
        if (chainId == 56) {
            guardian = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
        } else if (chainId == 97) {
            guardian = 0x76Fa8C526f8Bc27ba6958B76DeEf92a0dbE46950;
        } else if (chainId == 4663 || chainId == 46630) {
            guardian = 0x0000b48720d3B4ED6BC5031768B07F2b59270000;
        }
        require(guardian != address(0), unicode"LeverBeacon: unsupported chain / 不支持的链");
    }
}

/// @title LeverBeacon — the upgrade authority for every LeverVault
/// @notice Ownership goes to the Flap Guardian in the constructor and never to the deployer.
///         Rule 009 exempts proxy vaults from emergency-withdraw functions precisely because
///         this is the emergency mechanism, so it must be Guardian-only from block one.
contract LeverBeacon is UpgradeableBeacon {
    constructor(address implementation_) UpgradeableBeacon(implementation_) {
        address guardian = LeverGuardian.resolve();
        require(guardian != address(0), unicode"LeverBeacon: guardian is zero / Guardian 为零地址");
        _transferOwnership(guardian);
    }
}
