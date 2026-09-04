// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";
import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";

/// @notice Two documentation defects from the fourth risk report.
///
/// @dev Finding 1: `rebalanceCooldown()` was `pure` and unconditionally returned 1 hours, while
///      `_rebalance` enforced the real rule through the separate internal `_cooldown`, which
///      returns 0 in the urgent zone. The public getter never reported the zero-cooldown case
///      its own NatSpec documented. It now calls the same function `_rebalance` does.
///
///      Finding 3: the README claimed all three working functions "each pay a fixed bounty",
///      but rebalance's lever-up branch calls `_build(0, p)`, which borrows more and frees
///      nothing -- there is no freed BNB to compute a bounty from. The bounty is real only on
///      the deleveraging half. This is a documentation fix, not a behavior change: leaving the
///      lever-up path unpaid is fine, because it is not urgent (the position is already above
///      target, the safe direction) and the automatic path reaches it regardless.
contract LeverVaultCooldownAndBountyTest is Test {
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

    /// @dev vUSDT is a Compound V2 fork; accountBorrows is slot 16 (located by scanning for the
    ///      slot matching borrowBalanceStored, not assumed from the ABI).
    function _pushBelowUrgent() internal {
        bytes32 slot = keccak256(abi.encode(address(v), uint256(16)));
        uint256 principal = uint256(vm.load(vUSDT, slot));
        require(principal > 0, "no debt to raise");
        // health = 0.8 * L/(L-1). Urgent line is 11,300 -> L ~= 3.424x. Push debt further so
        // health is comfortably under the line rather than riding it.
        vm.store(vUSDT, slot, bytes32(principal * 1120 / 1000));
    }

    function test_rebalanceCooldownMatchesTheLiveRuleEnforcedByRebalance() public {
        _tax(5 ether);
        v.deployPending();

        // Ordinary state: 1 hour, matching what a non-urgent rebalance would enforce.
        assertEq(v.rebalanceCooldown(), 1 hours, "ordinary cooldown should be 1 hour");
        assertGe(v.healthBps(), v.URGENT_HEALTH_BPS(), "test setup should not already be urgent");

        _pushBelowUrgent();
        assertLt(v.healthBps(), v.URGENT_HEALTH_BPS(), "push did not reach the urgent zone");

        // The getter must now report zero, exactly as its own NatSpec promises.
        assertEq(v.rebalanceCooldown(), 0, "cooldown must be zero once health is below the urgent line");
    }

    function test_rebalanceScheduleDescriptionMatchesTheLeverUpBehavior() public view {
        // The on-chain schema must no longer claim a flat bounty; it must disclose that
        // levering up pays none, and that the deleverage bounty's basis is the deleveraged
        // notional rather than whatever a shrink happens to free (report six's Finding 3 --
        // wording tightened again after the lever-up branch was found able to pay a tiny
        // incidental bounty of its own, since fixed to always pay zero there instead).
        VaultUISchema memory s = v.vaultUISchema();
        assertTrue(
            _contains(s.methods[5].description, "levering up pays no bounty"),
            "schema must disclose the lever-up case"
        );
        assertTrue(
            _contains(s.methods[5].description, "deleveraged notional"),
            "schema must state the deleverage bounty's actual basis"
        );
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) { ok = false; break; }
            }
            if (ok) return true;
        }
        return false;
    }

    receive() external payable {}
}
