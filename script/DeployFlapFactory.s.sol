// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {BeaconProxy} from "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import {LeverVaultFactory} from "../src/flap/LeverVaultFactory.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";
import {LeverBeacon} from "../src/flap/LeverBeacon.sol";

/// @notice Deploys the Flap side only. It launches no token -- a token is created by Flap's own
///         launcher, which calls the factory through the VaultPortal.
///
/// @dev Five contracts, two of them beacons, and BOTH beacons are owned by the Flap Guardian
///      from within their own constructors. Flap's reviewer asked that every module beyond the
///      vault itself also be upgradeable, so the factory now runs behind a beacon of its own:
///
///        LeverVault      (implementation)  <- vaultBeacon   <- every vault is a BeaconProxy
///        LeverVaultFactory (implementation) <- factoryBeacon <- the factory IS a BeaconProxy
///
///      The address to register with Flap is the factory PROXY, which never changes across
///      upgrades. The vault implementation is deployed here rather than inside the factory's
///      constructor: a `new LeverVault()` reachable from the factory's runtime would carry that
///      contract's ~22kB creation code and put the factory over EIP-170's 24,576-byte limit.
contract DeployFlapFactory is Script {
    function run() external {
        vm.startBroadcast();

        LeverVault vaultImpl = new LeverVault();
        LeverBeacon vaultBeacon = new LeverBeacon(address(vaultImpl));

        LeverVaultFactory factoryImpl = new LeverVaultFactory();
        LeverBeacon factoryBeacon = new LeverBeacon(address(factoryImpl));

        // The proxy's own constructor delegatecalls initialize, so there is no block in which
        // an uninitialized factory is reachable.
        address factory = address(
            new BeaconProxy(
                address(factoryBeacon),
                abi.encodeCall(LeverVaultFactory.initialize, (address(vaultBeacon)))
            )
        );

        vm.stopBroadcast();

        // Read everything back through the deployed objects rather than trusting local ones.
        address guardian = IOwnable(address(vaultBeacon)).owner();
        require(IOwnable(address(factoryBeacon)).owner() == guardian, "factory beacon owner");
        require(LeverVaultFactory(factory).beacon() == address(vaultBeacon), "factory beacon wiring");
        require(
            IBeacon(address(factoryBeacon)).implementation() == address(factoryImpl),
            "factory beacon impl"
        );
        require(IBeacon(address(vaultBeacon)).implementation() == address(vaultImpl), "vault beacon impl");

        console2.log("chainid                ", block.chainid);
        console2.log("LeverVaultFactory      ", factory);
        console2.log("LeverFactoryBeacon     ", address(factoryBeacon));
        console2.log("LeverVaultFactory impl ", address(factoryImpl));
        console2.log("LeverBeacon            ", address(vaultBeacon));
        console2.log("LeverVault impl        ", address(vaultImpl));
        console2.log("guardian owns both     ", guardian);
    }
}

interface IBeacon { function implementation() external view returns (address); }
interface IOwnable { function owner() external view returns (address); }
