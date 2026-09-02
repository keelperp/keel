// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";

interface IVUSDT {
    function borrowBalanceStored(address) external view returns (uint256);
}

/// @notice The accounting identity Flap's reviewer found broken: deleveraging must move BNB
///         between costBasis and pendingRevenue, not add it to one of them.
///
/// @dev `_nav` counts idle balance, so when `_shrinkBy` pulls capital out of the position the
///      NAV does not change -- the BNB simply moves from the Venus leg to the vault's own
///      balance. Booking it as pending revenue while leaving costBasis alone therefore raises
///      `costBasis + pendingRevenue` by the freed amount out of nowhere, and `_deploy` then
///      runs `costBasis += work` on the same BNB, making the inflation permanent. Every later
///      `_gain` sits lower by that amount and `harvest` stops paying holders.
///
///      This is checked as an identity rather than against a hard-coded number: whatever the
///      unwind frees, the basis may only fall by the bounty that genuinely left the vault.
contract LeverVaultRebalanceBasisTest is Test {
    LeverVault v;

    address constant TOKEN = 0x35764c47AB7F6B78B00636d4f8599F05f48d7777;
    address constant PROJECT = address(0xBEEF);
    address constant vBNB = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;
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

    /// @dev Make the position genuinely over-leveraged rather than merely reported so.
    ///      `_health` and `_leverage` both read `_positionUsd`, so mocking one moves the other
    ///      and the closing health check can never pass -- the unwind has to really deleverage.
    ///
    ///      Raise the debt rather than cut the collateral. Venus's vBNB is a Compound V2 fork;
    ///      cutting `accountTokens` also cuts what the unwind is allowed to redeem, and the
    ///      first attempt at this left the position untouched at 3.151x before and after.
    ///      Raising `accountBorrows[vault].principal` (vUSDT slot 16, located by scanning for
    ///      the slot pair that matches `borrowBalanceStored`) leaves the collateral real, so
    ///      repaying genuinely brings health back.
    function _reallyOverLeverage() internal {
        bytes32 slot = keccak256(abi.encode(address(v), uint256(16)));
        uint256 principal = uint256(vm.load(vUSDT, slot));
        require(principal > 0, "no debt to raise");
        // leverage = s/(s-b). At 3.00x, b = 2s/3; 3.2x needs b = 0.6875s, up 3.125%.
        vm.store(vUSDT, slot, bytes32(principal * 1032 / 1000));
    }

    function test_deleveragingMovesCapitalBetweenBasisAndPending_itDoesNotInventIt() public {
        _tax(5 ether);
        v.deployPending();

        uint256 basisBefore = v.costBasis() + v.pendingRevenue();
        assertGt(basisBefore, 0, "nothing was deployed");

        _reallyOverLeverage();
        assertTrue(v.needsRebalance(), "the deleveraging branch must be the one under test");

        uint256 levBefore = v.currentLeverage();
        uint256 debtBefore = IVUSDT(vUSDT).borrowBalanceStored(address(v));
        (uint256 s0, uint256 b0) = v.positionUsd();
        // x = s - (s-b)*TARGET is the debt that has to go, in USD.
        uint256 needUsd = s0 - (s0 - b0) * 3;
        uint256 mine = address(this).balance;
        v.rebalance();
        uint256 bounty = address(this).balance - mine;

        // The unwind has to have actually run, or the identity below is vacuous.
        assertGt(bounty, 0, "no bounty paid, so the unwind freed nothing");
        assertGt(v.pendingRevenue(), 0, "nothing was booked, so nothing was tested");
        // Not merely "lower": the deleverage has to LAND on the target. A proportional shrink
        // cannot move leverage at all, and what the old code reached was decided by how much of
        // the tail redeem the health cap blocked -- 2.83x with it fully blocked, 3.15x with it
        // fully open, never the 3.00x it was aiming at.
        uint256 lev = v.currentLeverage();
        assertLt(lev, levBefore, "leverage did not come down");
        assertApproxEqRel(lev, 3e18, 0.02e18, "deleverage did not land on the 3x target");

        // Landing on the target is not enough: the proportional model reached it too, but only
        // by over-repaying and then redeeming part of it back, paying PancakeSwap on both legs.
        // The repayment must be close to what the algebra actually requires.
        uint256 repaidUsd = (debtBefore - IVUSDT(vUSDT).borrowBalanceStored(address(v)))
            * (b0 * 1e18 / debtBefore) / 1e18;
        assertLt(repaidUsd, needUsd * 2, "repaid far more debt than the target required");

        // The bounty is the only BNB that genuinely left, and it was never part of the basis
        // on either side -- it shows up as a fall in NAV, which is what it is. Everything else
        // moved from costBasis to pendingRevenue, so the sum is unchanged.
        assertEq(
            v.costBasis() + v.pendingRevenue(),
            basisBefore,
            "deleveraging moved capital into pendingRevenue without taking it out of costBasis"
        );
    }

    /// @dev The permanent half of the defect: redeploying the freed BNB must not grow the
    ///      basis, because that BNB was already paid for once.
    function test_redeployingFreedCapitalDoesNotGrowTheBasisASecondTime() public {
        _tax(5 ether);
        v.deployPending();
        _reallyOverLeverage();

        uint256 mine = address(this).balance;
        v.rebalance();
        uint256 bounty = address(this).balance - mine;
        uint256 basisAfterRebalance = v.costBasis() + v.pendingRevenue();

        if (v.pendingRevenue() >= 0.01 ether) {
            mine = address(this).balance;
            v.deployPending();
            uint256 deployBounty = address(this).balance - mine;
            assertEq(
                v.costBasis() + v.pendingRevenue() + deployBounty,
                basisAfterRebalance,
                "redeploying freed capital counted the same BNB twice"
            );
        }
        assertGt(bounty, 0, "rebalance paid no bounty, so the path did not run");
    }

    receive() external payable {}
}
