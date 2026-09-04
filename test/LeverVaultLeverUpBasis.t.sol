// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";

/// @notice Finding 2 of the sixth risk report: the lever-up branch of `_rebalance` folds the
///         flash build's own 0.3% over-borrow buffer leftover into `pendingRevenue` without the
///         offsetting `costBasis` decrement the deleverage branch already had -- so `_deploy`
///         later runs `costBasis += work` on a leftover that never represented new capital,
///         inflating `basis` and suppressing `_gain` a second time on top of the operation's real
///         (small, fee-driven) cost.
///
/// @dev The fix generalises the deleverage branch's existing treatment to both branches: `rest`
///      moving into `pendingRevenue` is now always matched by the same amount leaving
///      `costBasis`, so `costBasis + pendingRevenue` is invariant across a rebalance regardless
///      of direction, and `_gain` (nav minus that sum) moves only by what `nav` itself did --
///      the operation's real net cost, nothing folded in on top of it. Paired with the fix to
///      Finding 3, which zeroes the lever-up bounty outright, nothing leaves the vault on this
///      branch at all, so the invariant here is exact, not approximate.
contract LeverVaultLeverUpBasisTest is Test {
    LeverVault v;

    address constant TOKEN = 0x35764c47AB7F6B78B00636d4f8599F05f48d7777;
    address constant PROJECT = address(0xBEEF);
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

    /// @dev Pushes leverage below the band's lower edge by reducing debt, the mirror image of
    ///      the over-leverage helper used elsewhere this session. vUSDT is a Compound V2 fork;
    ///      accountBorrows is slot 16 (located by scanning for the slot matching
    ///      borrowBalanceStored, not assumed from the ABI).
    function _underLeverage() internal {
        bytes32 slot = keccak256(abi.encode(address(v), uint256(16)));
        uint256 principal = uint256(vm.load(vUSDT, slot));
        require(principal > 0, "no debt to cut");
        // 3x -> below 2.85x needs roughly an 8% debt cut; leave real margin.
        vm.store(vUSDT, slot, bytes32(principal * 850 / 1000));
    }

    function test_basisIsInvariantAcrossALeverUpRebalance() public {
        _tax(5 ether);
        v.deployPending();
        _underLeverage();
        assertTrue(v.needsRebalance(), "the lever-up branch must be the one under test");
        assertLt(v.currentLeverage(), 3e18, "must actually be under-leveraged, not over");

        uint256 basisBefore = v.costBasis() + v.pendingRevenue();
        uint256 mine = address(this).balance;
        v.rebalance();
        uint256 paid = address(this).balance - mine;

        assertEq(paid, 0, "lever-up must pay no bounty");
        assertEq(
            v.costBasis() + v.pendingRevenue(),
            basisBefore,
            "lever-up rebalance moved basis net -- the flash buffer leftover was double-booked"
        );
    }

    receive() external payable {}
}
