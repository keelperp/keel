// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";

interface IVBNBLike {
    function mint() external payable;
}

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Eleventh risk report: BNB forced into the vault outside `receive()` -- the only real
///         path is `selfdestruct`, which the EVM delivers with no callback at all, so nothing a
///         contract writes can hook it -- used to raise `nav` with no matching entry in
///         `pendingRevenue`. Under the old `_gain = nav - (costBasis + pendingRevenue)`, that
///         untracked balance read as market profit, and `_shrinkBy(gain, p)` would free that
///         much MORE from the levered position than it had actually earned, landing the
///         remaining position value BELOW `costBasis` by exactly the donated amount -- a genuine
///         loss of principal, not merely a mis-attributed one.
///
/// @dev `vm.deal` sets a balance directly, the same way a `selfdestruct` credit lands: no call,
///      no `receive()`, nothing for the vault to observe. That makes it the right tool to
///      reproduce this exact vector rather than an approximation of it.
///
///      Fixed by decoupling `_gain` from idle balance entirely: it now reads
///      `_nav(p) - address(this).balance` (position-only equity, the same figure `_shrinkBy`
///      itself targets) against `costBasis`, rather than blending the FULL nav (position plus
///      idle) against `costBasis + pendingRevenue`. That blend was only correct while idle
///      balance exactly equalled `pendingRevenue` -- an invariant every internal source now
///      maintains, but one no contract can enforce against an external `selfdestruct`. Immune
///      to idle-balance mismatches from any source now, present or future, rather than needing
///      a matching fix at each new one.
contract LeverVaultDonationImmunityTest is Test {
    LeverVault v;

    address constant TOKEN = 0x35764c47AB7F6B78B00636d4f8599F05f48d7777;
    address constant PROJECT = address(0xBEEF);
    address constant vBNB = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;

    function setUp() public {
        if (vm.envOr("KEEL_ARCHIVE", uint256(0)) == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(vm.envOr("KEEL_RPC_URL", string("https://bsc-dataseed.bnbchain.org")));
        vm.roll(block.number + 1000);
        v = new LeverVault();
        v.initialize(TOKEN, PROJECT);
        vm.deal(address(this), 1000 ether);
    }

    function _tax(uint256 amount) internal {
        (bool ok,) = address(v).call{value: amount}("");
        require(ok, "tax failed");
    }

    function test_forceSentBnbIsNotCountedAsGain() public {
        _tax(5 ether);
        v.deployPending();

        uint256 pendingBefore = v.pendingRevenue();
        vm.deal(address(v), address(v).balance + 2 ether);
        assertEq(v.pendingRevenue(), pendingBefore, "a forced credit must not touch pendingRevenue");
        assertEq(v.unrealisedGain(), 0, "a forced donation must not read as market gain");
    }

    /// @dev The property that actually matters: a harvest triggered by REAL appreciation must
    ///      not pull the position's own equity below what was genuinely invested, even with an
    ///      untracked donation sitting in the balance at the same time.
    function test_harvestNeverDropsPositionEquityBelowCostBasisDespiteADonation() public {
        _tax(5 ether);
        v.deployPending();

        vm.deal(address(v), address(v).balance + 2 ether);

        // Real appreciation, modelled the same way the existing harvest test does: more
        // collateral on the supply leg, debt untouched. No oracle mocked.
        IVBNBLike(vBNB).mint{value: 1 ether}();
        IERC20Like(vBNB).transfer(address(v), IERC20Like(vBNB).balanceOf(address(this)));

        uint256 gain = v.unrealisedGain();
        assertApproxEqRel(gain, 1 ether, 0.05e18, "gain must reflect only real appreciation, not the donation");

        v.harvest();

        uint256 positionEquity = v.nav() - address(v).balance;
        assertGe(
            positionEquity + 2,
            v.costBasis(),
            "harvest left position equity below costBasis -- the donation was spent as if earned"
        );
    }

    receive() external payable {}
}
