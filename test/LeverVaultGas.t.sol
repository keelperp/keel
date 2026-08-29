// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";

/// @notice Rule 005: receive() must stay under 1,000,000 gas on every path, because the
///         Flap Portal forwards tax with a plain call and a revert or an overrun breaks
///         tax collection for the token permanently.
contract LeverVaultGasTest is Test {
    LeverVault vault;
    address constant TOKEN = 0xE1cE50807dcFe16774B6cc38E1c315019E977777;
    address constant PROJECT = address(0xBEEF);

    function setUp() public {
        vault = new LeverVault();
        vault.initialize(TOKEN, PROJECT);
    }

    function test_receiveUnder1M() public {
        vm.deal(address(this), 10 ether);

        uint256 g0 = gasleft();
        (bool ok,) = address(vault).call{value: 1 ether}("");
        uint256 firstCall = g0 - gasleft();
        assertTrue(ok, "receive() reverted");

        uint256 g1 = gasleft();
        (bool ok2,) = address(vault).call{value: 1 ether}("");
        uint256 warmCall = g1 - gasleft();
        assertTrue(ok2, "receive() reverted on the warm path");

        emit log_named_uint("receive gas, cold storage", firstCall);
        emit log_named_uint("receive gas, warm storage", warmCall);
        emit log_named_uint("rule 005 limit           ", 1_000_000);

        assertLe(firstCall, 1_000_000, "receive() exceeds the 1M cap");
        assertLe(warmCall, 1_000_000, "receive() exceeds the 1M cap on the warm path");
        // The rule calls anything over 100k unnecessarily expensive.
        assertLe(firstCall, 100_000, "receive() should be far cheaper than the cap");

        assertEq(vault.pendingRevenue(), 2 ether, "tax did not accumulate");
        assertEq(vault.totalReceived(), 2 ether, "lifetime total did not accumulate");
    }

    /// @notice receive() must not revert even when the vault has never been funded or the
    ///         position is empty — a reverting receive() bricks the token's tax collection.
    function test_receiveNeverReverts() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 wei}("");
        assertTrue(ok, "receive() reverted on a 1 wei transfer");
        (bool ok2,) = address(vault).call{value: 0}("");
        assertTrue(ok2, "receive() reverted on a zero-value transfer");
    }
}
