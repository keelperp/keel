// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";

/// @notice The state Flap's reviewer asked about: supply has fallen to or below debt.
///
///         Health is then necessarily below the urgent line, so the selector wants a rescue.
///         But a rescue runs `_rebalance`, which requires `needsRebalance()`, and at supply <=
///         debt `_leverage` returns 0 so that is false. Before this was fixed the selector
///         picked the rescue on every wake, it reverted every time, and the deploy that could
///         actually recover the position was never reached.
contract LeverVaultInsolventTest is Test {
    LeverVault v;

    address constant TOKEN = 0x35764c47AB7F6B78B00636d4f8599F05f48d7777;
    address constant PROJECT = address(0xBEEF);
    address constant vBNB = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;
    address constant vUSDT = 0xfD5840Cd36d94D7229439859C0112a4185BC0255;

    function setUp() public {
        vm.createSelectFork(vm.envOr("KEEL_RPC_URL", string("https://bsc-dataseed.bnbchain.org")));
        vm.roll(block.number + 1000);
        v = new LeverVault();
        v.initialize(TOKEN, PROJECT);
    }

    /// @dev Drive supply below debt by mocking what the vault reads back from Venus.
    function _makeInsolvent() internal {
        // A little collateral...
        vm.mockCall(vBNB, abi.encodeWithSignature("balanceOf(address)", address(v)),
                    abi.encode(uint256(1e8)));
        vm.mockCall(vBNB, abi.encodeWithSignature("exchangeRateStored()"),
                    abi.encode(uint256(1e18)));
        // ...against far more debt.
        vm.mockCall(vUSDT, abi.encodeWithSignature("borrowBalanceStored(address)", address(v)),
                    abi.encode(uint256(100_000e18)));
    }

    function test_underwaterPositionReportsZeroLeverageAndNoRebalance() public {
        _makeInsolvent();
        assertEq(v.currentLeverage(), 0, "supply <= debt must read as zero leverage");
        assertFalse(v.needsRebalance(), "a rescue cannot run in this state");
    }

    function test_theSelectorDoesNotLockOnAnActionThatCannotRun() public {
        _makeInsolvent();
        // Nothing banked yet: there is genuinely nothing to do, and the vault must say so
        // rather than naming a rescue it cannot perform.
        assertEq(v.pendingAction(), 0, "with no revenue the wake has no runnable action");

        // Now bank some tax. The recoverable action is the deploy, and the selector must
        // reach it instead of stopping at the rescue.
        (bool ok,) = address(v).call{value: 1 ether}("");
        require(ok, "funding failed");
        assertEq(v.pendingAction(), 2, "the selector must offer the deploy, not a doomed rescue");
    }

    /// @dev The escape hatch the reviewer identified stays open: deployPending is external and
    ///      permissionless, so it never depended on the selector in the first place.
    function test_manualDeployIsStillReachableWhileUnderwater() public {
        _makeInsolvent();
        (bool ok,) = address(v).call{value: 1 ether}("");
        require(ok, "funding failed");
        // It reverts here because a mocked position cannot actually be rebuilt, but it reverts
        // on the health floor rather than on a permission or a require nobody can satisfy.
        vm.expectRevert();
        v.deployPending();
    }
}
