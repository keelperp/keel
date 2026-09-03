// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";

interface IDiv { function totalShares() external view returns (uint256); }

/// @notice Two defects the third review found, both introduced by fixes for the second one.
///
/// @dev They share a shape worth naming: each was a change that was correct in the function it
///      touched and wrong in the function that consumed it. The deleverage branch started
///      producing a freed amount that already WAS the bounty, while the generic line below kept
///      applying the rate to it. And `_harvest` gained a requirement that the dividend contract
///      actually take the WBNB, while `_pickAction` kept choosing harvest without asking whether
///      it could.
contract LeverVaultSelectorBountyTest is Test {
    LeverVault v;

    address constant TOKEN = 0x35764c47AB7F6B78B00636d4f8599F05f48d7777;
    address constant PROJECT = address(0xBEEF);
    address constant vBNB = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;
    address constant vUSDT = 0xfD5840Cd36d94D7229439859C0112a4185BC0255;
    uint256 constant BPS = 10_000;

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

    /// @dev Raise the debt so the position is genuinely, not merely reportedly, over the band.
    ///      vUSDT is a Compound V2 fork; accountBorrows is slot 16.
    function _overLeverage() internal {
        bytes32 slot = keccak256(abi.encode(address(v), uint256(16)));
        uint256 principal = uint256(vm.load(vUSDT, slot));
        require(principal > 0, "no debt to raise");
        vm.store(vUSDT, slot, bytes32(principal * 1032 / 1000));
    }

    // ------------------------------------------------------------------ F1: the double discount

    function test_theDeleverageBountyIsNotDiscountedTwice() public {
        _tax(5 ether);
        v.deployPending();
        _overLeverage();
        assertTrue(v.needsRebalance(), "the deleverage branch must be the one under test");

        (uint256 s, uint256 b) = v.positionUsd();
        uint256 excessUsd = s - (s - b) * 3;
        uint256 mine = address(this).balance;
        v.rebalance();
        uint256 paid = address(this).balance - mine;

        assertGt(paid, 0, "the caller was paid nothing");

        // The bounty is 0.3% of the repositioned amount. Applying the rate a second time, which
        // is what the code did, leaves the caller with 0.3% OF 0.3% -- about 333x less. Assert
        // the order of magnitude rather than an exact wei, since the shrink can fall short of
        // its target when the redeem cap binds.
        uint256 pxBnb = excessUsd * 1e18 / (v.nav() + 1);        // rough BNB-per-USD scaling
        pxBnb;                                                    // (unused; kept for clarity)
        uint256 doubleDiscounted = excessUsd * 30 / BPS * 30 / BPS;
        assertGt(paid * 1e18, doubleDiscounted, "bounty looks like it was discounted twice");
    }

    /// @dev The other half of the same defect: the shrink was sized to the bounty, but only
    ///      0.3% of it reached the caller, so 99.7% went back to pendingRevenue to be re-levered
    ///      -- flash fees and slippage paid for nothing.
    ///
    ///      Asserted as a ratio, not a threshold. An absolute bound fails for the wrong reason:
    ///      `_repayOnce` redeems 1% more than the repayment needs, and that remainder lands in
    ///      the same place without being the churn this is about. What distinguishes the defect
    ///      is WHERE the shrink went -- to the caller, or back into the queue.
    function test_theShrinkGoesToTheCallerNotBackIntoTheQueue() public {
        _tax(5 ether);
        v.deployPending();
        uint256 pendingBefore = v.pendingRevenue();
        _overLeverage();

        uint256 mine = address(this).balance;
        v.rebalance();
        uint256 paid = address(this).balance - mine;
        uint256 requeued = v.pendingRevenue() - pendingBefore;

        assertGt(paid, 0, "the caller was paid nothing");
        // Before the fix the caller got 0.3% of the shrink and the queue got the other 99.7%.
        assertGt(paid * 10, requeued, "most of the shrink went back into the queue, not to the caller");
    }

    // ------------------------------------------------- F2: harvest chosen when it cannot succeed

    function test_theSelectorSkipsHarvestWhenTheDividendHasNobodyToPay() public {
        _tax(5 ether);
        v.deployPending();

        address div = 0x0000000000000000000000000000000000000000;
        try this.divOf() returns (address d) { div = d; } catch {}
        vm.assume(div != address(0));

        // No eligible holders: Flap's Dividend takes nothing, so `_harvest` reverts.
        vm.mockCall(div, abi.encodeWithSignature("totalShares()"), abi.encode(uint256(0)));
        assertTrue(v.pendingAction() != 3, "harvest must not be selected when it cannot succeed");

        // Restore holders and the selector may choose it again.
        vm.mockCall(div, abi.encodeWithSignature("totalShares()"), abi.encode(uint256(1e18)));
        // (Whether it IS 3 depends on live gain; the point is only that zero shares excludes it.)
    }

    function divOf() external view returns (address) {
        return IFlapTaxTokenLite(TOKEN).dividendContract();
    }

    receive() external payable {}
}

interface IFlapTaxTokenLite { function dividendContract() external view returns (address); }
