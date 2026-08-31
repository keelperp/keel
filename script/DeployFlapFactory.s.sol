// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {LeverVaultFactory} from "../src/flap/LeverVaultFactory.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";

/// @notice Deploys the Flap side only: the factory, and through its constructor the vault
///         implementation and the Guardian-owned beacon. It launches no token -- a token is
///         created by Flap's own launcher, which calls this factory through the VaultPortal.
///
///         One `new` is the whole deployment. LeverVaultFactory's constructor does
///         `new LeverBeacon(address(new LeverVault()))`, which is why its initcode carries
///         both children and measures 27,668 bytes.
contract DeployFlapFactory is Script {
    function run() external {
        vm.startBroadcast();
        LeverVaultFactory factory = new LeverVaultFactory();
        vm.stopBroadcast();

        address beacon = factory.beacon();
        // Read back through the deployed factory rather than trusting the local objects.
        console2.log("chainid           ", block.chainid);
        console2.log("LeverVaultFactory ", address(factory));
        console2.log("LeverBeacon       ", beacon);
        console2.log("LeverVault impl   ", IBeacon(beacon).implementation());
        console2.log("beacon owner      ", IOwnable(beacon).owner());
    }
}

interface IBeacon { function implementation() external view returns (address); }
interface IOwnable { function owner() external view returns (address); }
