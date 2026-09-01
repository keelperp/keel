// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {BeaconProxy} from "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";
import {LeverVaultFactory} from "../src/flap/LeverVaultFactory.sol";
import {LeverBeacon} from "../src/flap/LeverBeacon.sol";

/// @notice What Flap's reviewer asked for: everything beyond the vault is upgradeable too, and
///         the Guardian -- nobody else -- holds that authority.
///
/// @dev Runs without a fork. `vm.chainId(56)` is all the Guardian lookup needs.
contract LeverVaultUpgradeableTest is Test {
    address constant BSC_GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;

    LeverVault vaultImpl;
    LeverBeacon vaultBeacon;
    LeverVaultFactory factoryImpl;
    LeverBeacon factoryBeacon;
    LeverVaultFactory factory;

    function setUp() public {
        vm.chainId(56);
        vaultImpl = new LeverVault();
        vaultBeacon = new LeverBeacon(address(vaultImpl));
        factoryImpl = new LeverVaultFactory();
        factoryBeacon = new LeverBeacon(address(factoryImpl));
        factory = LeverVaultFactory(
            address(
                new BeaconProxy(
                    address(factoryBeacon),
                    abi.encodeCall(LeverVaultFactory.initialize, (address(vaultBeacon)))
                )
            )
        );
    }

    // ------------------------------------------------- both modules are Guardian-upgradeable

    function test_bothBeaconsAreOwnedByTheGuardianNotTheDeployer() public view {
        assertEq(vaultBeacon.owner(), BSC_GUARDIAN, "vault beacon owner");
        assertEq(factoryBeacon.owner(), BSC_GUARDIAN, "factory beacon owner");
        assertTrue(vaultBeacon.owner() != address(this), "deployer must not hold vault beacon");
        assertTrue(factoryBeacon.owner() != address(this), "deployer must not hold factory beacon");
    }

    function test_theGuardianCanReplaceTheFactoryImplementation() public {
        LeverVaultFactory next = new LeverVaultFactory();
        vm.prank(BSC_GUARDIAN);
        factoryBeacon.upgradeTo(address(next));
        assertEq(factoryBeacon.implementation(), address(next), "factory not upgraded");
    }

    function test_nobodyButTheGuardianCanReplaceTheFactoryImplementation() public {
        LeverVaultFactory next = new LeverVaultFactory();
        vm.expectRevert();
        factoryBeacon.upgradeTo(address(next));

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        factoryBeacon.upgradeTo(address(next));
    }

    /// @dev The reason the factory holds `beacon` in storage rather than as an `immutable`.
    ///      An immutable lives in the implementation's bytecode, so an upgrade would hand new
    ///      vaults a different beacon than the live ones use, silently splitting the estate.
    function test_anUpgradeKeepsTheRegistryAndTheBeaconWiring() public {
        assertEq(factory.beacon(), address(vaultBeacon), "wiring before");

        LeverVaultFactory next = new LeverVaultFactory();
        vm.prank(BSC_GUARDIAN);
        factoryBeacon.upgradeTo(address(next));

        assertEq(factory.beacon(), address(vaultBeacon), "beacon wiring lost across upgrade");
        assertEq(factory.vaultCount(), 0, "registry lost across upgrade");
    }

    function test_theRegisteredAddressSurvivesAnUpgrade() public {
        address registered = address(factory);
        LeverVaultFactory next = new LeverVaultFactory();
        vm.prank(BSC_GUARDIAN);
        factoryBeacon.upgradeTo(address(next));
        assertEq(address(factory), registered, "the address Flap registers must never move");
        assertEq(factory.factorySpecVersion(), "v2.2", "factory still answers after upgrade");
    }

    // ------------------------------------------------------------------ initialize is guarded

    function test_initializeCannotBeCalledTwice() public {
        vm.expectRevert(bytes(unicode"LeverVaultFactory: already initialized / 已初始化"));
        factory.initialize(address(vaultBeacon));
    }

    /// @dev A misconfigured beacon is as bad as a hostile one: it would mean the Guardian
    ///      cannot upgrade the vaults this factory creates.
    function test_initializeRefusesABeaconTheGuardianDoesNotOwn() public {
        UpgradeableBeacon rogue = new UpgradeableBeacon(address(vaultImpl));
        LeverVaultFactory impl = new LeverVaultFactory();
        LeverBeacon fb = new LeverBeacon(address(impl));
        vm.expectRevert();
        new BeaconProxy(address(fb), abi.encodeCall(LeverVaultFactory.initialize, (address(rogue))));
    }

    function test_initializeRefusesTheZeroBeacon() public {
        LeverVaultFactory impl = new LeverVaultFactory();
        LeverBeacon fb = new LeverBeacon(address(impl));
        vm.expectRevert();
        new BeaconProxy(address(fb), abi.encodeCall(LeverVaultFactory.initialize, (address(0))));
    }

    /// @dev The implementation contract is locked in its own constructor so it cannot be
    ///      initialized directly and left sitting there looking like a live factory.
    function test_theImplementationItselfCannotBeInitialized() public {
        assertEq(factoryImpl.beacon(), address(0xdead), "implementation not locked");
        vm.expectRevert(bytes(unicode"LeverVaultFactory: already initialized / 已初始化"));
        factoryImpl.initialize(address(vaultBeacon));
    }

    // --------------------------------------------------------------------- no other authority

    function test_thereIsNoOwnerOrAdminAnywhereButTheGuardian() public {
        (bool ok,) = address(factory).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "the factory must expose no owner of its own");
        (ok,) = address(factory).staticcall(abi.encodeWithSignature("admin()"));
        assertFalse(ok, "the factory must expose no admin");
    }
}
