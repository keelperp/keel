// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";
import {LeverVaultFactory} from "../src/flap/LeverVaultFactory.sol";
import {LeverBeacon} from "../src/flap/LeverBeacon.sol";
import {VaultUISchema, VaultDataSchema} from "../src/flap/IVaultSchemasV1.sol";

/// @notice Rule 006 coverage for the surfaces a Flap UI reads, plus the factory guards
///         that do not need Venus. Runs without a fork: `vm.chainId(56)` is enough for
///         the Guardian lookup, and nothing here calls `initialize`.
contract LeverVaultSchemaTest is Test {
    LeverVault vault;
    LeverVaultFactory factory;

    address constant BSC_GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;
    /// @dev The VaultPortal, NOT the token Portal (0xe2cE6ab8...). They are different
    ///      contracts and guessing cost a red test here rather than a dead factory later.
    address constant VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;

    function setUp() public {
        vm.chainId(56);
        vault = new LeverVault();
        factory = new LeverVaultFactory();
    }

    // ---------------------------------------------------------------- rule 001/006

    function test_descriptionIsNonEmpty() public view {
        assertGt(bytes(vault.description()).length, 0, "description() must not be empty");
    }

    function test_vaultUISchemaDescribesEveryUserFacingMethod() public view {
        VaultUISchema memory s = vault.vaultUISchema();
        assertGt(bytes(s.vaultType).length, 0, "vaultType empty");
        assertGt(bytes(s.description).length, 0, "schema description empty");
        assertEq(s.methods.length, 6, "method count drifted from the surface");

        uint256 writes;
        for (uint256 i = 0; i < s.methods.length; i++) {
            assertGt(bytes(s.methods[i].name).length, 0, "method name empty");
            assertGt(bytes(s.methods[i].description).length, 0, "method description empty");
            assertEq(s.methods[i].outputs.length, 1, "every method here returns one value");
            assertGt(bytes(s.methods[i].outputs[0].fieldType).length, 0, "fieldType empty");
            if (s.methods[i].isWriteMethod) writes++;
        }
        // nav / currentLeverage / healthBps are reads; deployPending / harvest / rebalance write.
        assertEq(writes, 3, "write flags drifted");
    }

    /// @dev The schema is what a generic UI renders, so a name that does not resolve to a
    ///      real selector renders a button that can only ever revert. Compare against the
    ///      compiler's own selectors — a staticcall probe cannot tell "no such function"
    ///      from "this one writes state".
    function test_everySchemaMethodNameResolvesToARealSelector() public view {
        VaultUISchema memory s = vault.vaultUISchema();
        bytes4[6] memory expected = [
            LeverVault.nav.selector,
            LeverVault.currentLeverage.selector,
            LeverVault.healthBps.selector,
            LeverVault.deployPending.selector,
            LeverVault.harvest.selector,
            LeverVault.rebalance.selector
        ];
        assertEq(s.methods.length, expected.length, "schema length drifted from the checked set");
        for (uint256 i = 0; i < s.methods.length; i++) {
            bytes4 fromName = bytes4(keccak256(bytes(string.concat(s.methods[i].name, "()"))));
            assertEq(fromName, expected[i], "schema name does not match the contract's selector");
        }
    }

    // ------------------------------------------------------------------- rule 002

    function test_factoryDataSchemaMatchesNewVaultAbi() public view {
        VaultDataSchema memory s = factory.vaultDataSchema();
        assertGt(bytes(s.description).length, 0, "factory schema description empty");
        assertEq(s.fields.length, 1, "vaultData is one address");
        assertEq(s.fields[0].fieldType, "address", "vaultData field type drifted");
        assertEq(s.isArray, false);
    }

    function test_onlyNativeBnbIsSupportedAsQuote() public view {
        assertTrue(factory.isQuoteTokenSupported(address(0)), "native BNB must be supported");
        assertFalse(
            factory.isQuoteTokenSupported(0x55d398326f99059fF775485246999027B3197955), "USDT must be rejected"
        );
    }

    function test_newVaultRejectsEveryCallerThatIsNotThePortal() public {
        vm.expectRevert(
            bytes(unicode"LeverVaultFactory: caller is not the VaultPortal / 调用方不是 VaultPortal")
        );
        factory.newVault(address(0xA11CE), address(0), address(0xB0B), abi.encode(address(0xCAFE)));

        vm.prank(BSC_GUARDIAN);
        vm.expectRevert(
            bytes(unicode"LeverVaultFactory: caller is not the VaultPortal / 调用方不是 VaultPortal")
        );
        factory.newVault(address(0xA11CE), address(0), address(0xB0B), abi.encode(address(0xCAFE)));
    }

    function test_portalCallStillValidatesEveryArgument() public {
        vm.startPrank(VAULT_PORTAL);

        vm.expectRevert(bytes(unicode"LeverVaultFactory: tax token is zero / 税收代币为零地址"));
        factory.newVault(address(0), address(0), address(0xB0B), abi.encode(address(0xCAFE)));

        vm.expectRevert(
            bytes(unicode"LeverVaultFactory: quote must be native BNB / 计价资产必须是原生 BNB")
        );
        factory.newVault(address(0xA11CE), address(0xBEEF), address(0xB0B), abi.encode(address(0xCAFE)));

        vm.expectRevert(bytes(unicode"LeverVaultFactory: creator is zero / 创建者为零地址"));
        factory.newVault(address(0xA11CE), address(0), address(0), abi.encode(address(0xCAFE)));

        vm.expectRevert(bytes(unicode"LeverVaultFactory: invalid vault data / 金库数据无效"));
        factory.newVault(address(0xA11CE), address(0), address(0xB0B), hex"1234");

        vm.expectRevert(bytes(unicode"LeverVaultFactory: project is zero / 项目地址为零"));
        factory.newVault(address(0xA11CE), address(0), address(0xB0B), abi.encode(address(0)));

        vm.stopPrank();
    }

    // ------------------------------------------------------------------- rule 009

    /// @dev Proxy vaults are exempt from emergency withdraws *because* the beacon is the
    ///      emergency mechanism. That only holds if the Guardian owns it from block one.
    function test_beaconIsOwnedByTheGuardianNotTheDeployer() public view {
        LeverBeacon beacon = LeverBeacon(factory.beacon());
        assertEq(beacon.owner(), BSC_GUARDIAN, "upgrade authority must be the Guardian");
        assertTrue(beacon.owner() != address(this), "deployer must not retain upgrade authority");
        assertTrue(beacon.implementation() != address(0), "beacon has no implementation");
    }

    function test_beaconRefusesAnUnsupportedChain() public {
        vm.chainId(1);
        vm.expectRevert(bytes(unicode"LeverBeacon: unsupported chain / 不支持的链"));
        new LeverBeacon(address(vault));
    }
}
