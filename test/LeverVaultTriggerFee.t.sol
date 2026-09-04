// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";

interface IFee {
    function getFee() external view returns (uint256);
}

/// @notice Finding 1 of the sixth risk report: `trigger()` picks the action from the pre-fee
///         `pendingRevenue`, then `_schedule` deducts the trigger fee from it -- so a deploy
///         chosen when `pendingRevenue` sat in `[MIN_DEPLOY, MIN_DEPLOY + fee)` finds, once
///         `settleSelf` actually runs, that the fee had already eaten the balance below
///         `MIN_DEPLOY`. The wake spent a real fee and produced nothing, and because a chosen
///         action schedules the fast 5-minute cadence rather than the hourly one, this can repeat
///         several times before `pendingRevenue` drains far enough to fall back to idle.
///
/// @dev Fixed by having `_pickAction` reserve the fee before comparing to `MIN_DEPLOY`, the same
///      saturating way `_schedule` itself subtracts it -- so the threshold this function checks
///      is the one `_deploy` will actually see once the fee is gone.
contract LeverVaultTriggerFeeTest is Test {
    LeverVault v;

    address constant TOKEN = 0x35764c47AB7F6B78B00636d4f8599F05f48d7777;
    address constant PROJECT = address(0xBEEF);
    address constant TRIGGER_SERVICE = 0xcf4EE25035CF883895110f367F5BA8172416a7F9;
    uint256 constant MIN_DEPLOY = 0.01 ether;

    function setUp() public {
        if (vm.envOr("KEEL_ARCHIVE", uint256(0)) == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(vm.envOr("KEEL_RPC_URL", string("https://bsc-dataseed.bnbchain.org")));
        vm.roll(block.number + 1000);
        v = new LeverVault();
        v.initialize(TOKEN, PROJECT);
        vm.deal(address(this), 100 ether);
    }

    function _tax(uint256 amount) internal {
        (bool ok,) = address(v).call{value: amount}("");
        require(ok, "tax failed");
    }

    /// @dev Lands `pendingRevenue` exactly one wei inside the buggy band: at the threshold, but
    ///      with less than one fee's worth of room above it.
    function test_selectorDoesNotPickDeployWhenTheFeeWouldStarveIt() public {
        uint256 fee = IFee(TRIGGER_SERVICE).getFee();
        vm.assume(fee > 0);

        // Exactly at MIN_DEPLOY: comfortably inside [MIN_DEPLOY, MIN_DEPLOY + fee).
        _tax(MIN_DEPLOY);
        assertEq(v.pendingRevenue(), MIN_DEPLOY, "tax not booked");

        // The pre-fee balance alone qualifies for a deploy...
        assertGe(v.pendingRevenue(), MIN_DEPLOY, "test setup should qualify before the fee");
        // ...but the fee that `_schedule` is about to spend would eat it below the floor, so the
        // selector must decline to pick it.
        assertEq(v.pendingAction(), 0, "selector picked deploy that the fee would immediately starve");
    }

    /// @dev Comfortably above the band: the fee is a rounding error against the balance, and a
    ///      deploy must still be picked and must still succeed once run.
    function test_selectorStillPicksDeployWellAboveTheBand() public {
        uint256 fee = IFee(TRIGGER_SERVICE).getFee();
        _tax(MIN_DEPLOY + fee * 100);
        assertEq(v.pendingAction(), 2, "a comfortably-funded deploy must still be picked");
    }

    receive() external payable {}
}
