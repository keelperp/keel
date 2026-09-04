// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";

interface IERC20BalanceOf {
    function balanceOf(address) external view returns (uint256);
}

/// @notice Seventh risk report, Finding 1: untracked idle BNB inflates `_gain`, so a later
///         `harvest` shrinks the position by more than it actually gained.
///
/// @dev The report cited three sources. Two turned out to need different fixes than the one it
///      proposed for all three, established by reading `_nav` precisely rather than assuming:
///
///      `_nav`'s `idle = address(this).balance` is NATIVE balance only. WBNB left by
///      `_repayOnce`'s tail (`_buyBnb` on an overshoot) is an ERC20 balance `_nav` cannot see at
///      all -- it does not inflate `_gain`, it is simply stranded, permanently invisible to
///      every view the vault exposes. `_shrinkBy` already swept this at its own tail;
///      `_deleverBy` did not, so a deleverage or an urgent rescue left it behind. Fixed by
///      extracting the sweep and calling it from both.
///
///      `_schedule`'s floor-to-zero fee handling moves `gain` in the OPPOSITE direction from what
///      the report claims -- it very slightly understates gain, not inflates it, because
///      `pendingRevenue` can fall by less than the fee that actually left the balance. Not a
///      principal-leakage bug.
///
///      The real gain-inflation source was `_deploy`'s own build: unlike `_rebalance`, which
///      already captured its own flash-build's leftover buffer into `pendingRevenue` (offset
///      against `costBasis`, fixed two rounds ago), `_deploy` did not -- so a deploy's own
///      surplus raised `nav` with no offsetting entry in `basis` at all, and a later `harvest`
///      would shrink the position by more than the position's own market gain.
contract LeverVaultUntrackedSurplusTest is Test {
    LeverVault v;

    address constant TOKEN = 0x35764c47AB7F6B78B00636d4f8599F05f48d7777;
    address constant PROJECT = address(0xBEEF);
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant vUSDT = 0xfD5840Cd36d94D7229439859C0112a4185BC0255;

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

    /// @dev Fix A. A real flash build's own buffer surplus must land in pendingRevenue with the
    ///      same amount taken out of costBasis -- so `costBasis + pendingRevenue` rises by
    ///      exactly `work`, never by `work` plus whatever the build happened to hand back.
    function test_deployLeavesNoNativeBalanceOutsidePendingRevenue() public {
        // `_shrinkBy(gain, p)` always frees exactly `gain` from the position, by construction --
        // whatever `gain` reads as, right or wrong -- so an inflated `gain` does not make
        // `harvest` over-redeem principal the way the report describes; it still frees exactly
        // what `_gain` says. The real consequence is the opposite direction and shows up later:
        // any of the build's own flash-buffer surplus that is not captured in `pendingRevenue`
        // is capital `_deploy` will never pick up again (nothing else scans raw balance), and
        // `costBasis` stays inflated by that same amount relative to what the position is
        // actually worth, permanently suppressing every later `_gain` read until the position
        // climbs back over it. So the property to hold is not "gain reads zero" -- a build's
        // own swap can legitimately realise a small windfall against the oracle -- it is that
        // NOTHING is left invisible: every wei of idle native balance a deploy produces must be
        // sitting in pendingRevenue, ready for the next deploy to pick back up.
        _tax(5 ether);
        v.deployPending();
        assertEq(
            address(v).balance,
            v.pendingRevenue(),
            "deploy left native balance that pendingRevenue does not account for -- stranded capital"
        );
    }

    /// @dev Pushes leverage above the band by raising debt (vUSDT accountBorrows, slot 16,
    ///      located by scanning for the slot matching borrowBalanceStored).
    function _overLeverage() internal {
        bytes32 slot = keccak256(abi.encode(address(v), uint256(16)));
        uint256 principal = uint256(vm.load(vUSDT, slot));
        require(principal > 0, "no debt to raise");
        vm.store(vUSDT, slot, bytes32(principal * 1032 / 1000));
    }

    /// @dev Fix B. A deleverage's own repay-loop overshoot must not leave WBNB dust behind.
    function test_deleverageSweepsItsOwnWbnbDust() public {
        _tax(5 ether);
        v.deployPending();
        _overLeverage();
        assertTrue(v.needsRebalance(), "the deleveraging branch must be the one under test");

        v.rebalance();

        assertEq(
            IERC20BalanceOf(WBNB).balanceOf(address(v)),
            0,
            "deleverage left WBNB dust behind, invisible to nav"
        );
    }

    receive() external payable {}
}
