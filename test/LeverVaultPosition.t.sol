// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";
import {IVBNB, IERC20Min} from "../src/interfaces/IVenus.sol";

/// @notice Rule 006 happy-path coverage: tax in, position built, gain distributed.
contract LeverVaultPositionTest is Test {
    LeverVault v;

    address constant TOKEN = 0x35764c47AB7F6B78B00636d4f8599F05f48d7777; // WBNB dividends
    address constant PROJECT = address(0xBEEF);
    address constant vBNB = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;
    uint256 constant WAD = 1e18;

    /// @dev These exercise multi-step Venus and PancakeSwap state, which takes ~50s of
    ///      wall clock. BSC public nodes prune state after roughly 96 seconds and there is
    ///      no free archive node, so the fork dies mid-suite with `missing trie node` —
    ///      confirmed against both a direct fork and a local anvil cache. They are gated
    ///      off by default and the same paths are covered by `tools/flap.py`, which runs
    ///      the whole lifecycle as ONE atomic eth_call against live mainnet state and is
    ///      therefore immune to pruning.
    ///
    ///      Run them with an archive RPC:
    ///        KEEL_ARCHIVE=1 forge test --match-contract LeverVaultPositionTest \
    ///          --fork-url <archive-rpc>
    function setUp() public {
        // bsc-dataseed is load balanced across nodes at different heights — five calls in
        // a row spanned 19 blocks. Forge forks at one node's height and then reads state
        // from another, so Venus's stored accrual block can be AHEAD of the fork block.
        // Compound's `currentBlockNumber - accrualBlockNumberPrior` then underflows and
        // accrueInterest reverts "math error" intermittently. Rolling forward puts the
        // block number past anything a node could have recorded. Lagging the fork makes
        // it worse, not better.
        vm.roll(block.number + 1000);

        if (vm.envOr("KEEL_ARCHIVE", uint256(0)) == 0) {
            vm.skip(true);
        }
        v = new LeverVault();
        v.initialize(TOKEN, PROJECT);
        vm.deal(address(this), 1000 ether);
    }

    function _tax(uint256 amount) internal {
        (bool ok,) = address(v).call{value: amount}("");
        require(ok, "tax failed");
    }

    function test_taxAccumulatesThenBuildsToTarget() public {
        _tax(5 ether);
        assertEq(v.pendingRevenue(), 5 ether, "tax not booked");
        assertEq(v.currentLeverage(), 0, "should hold no position yet");

        uint256 before = address(this).balance;
        uint256 bounty = v.deployPending();

        assertGt(bounty, 0, "manual caller must be paid");
        assertEq(bounty, 5 ether * 25 / 10_000, "deploy bounty is 0.25%");
        assertEq(address(this).balance, before + bounty, "bounty not received");
        // Not exactly zero any more: the build's own flash-repay swap can realise a small
        // windfall against the oracle, and that surplus is now captured in pendingRevenue
        // rather than left as untracked idle balance (Flap's seventh report, Finding 1) --
        // proven elsewhere (test/LeverVaultUntrackedSurplus.t.sol) to always equal exactly
        // what sits idle. Bound it loosely here: a large fraction left undeployed would mean
        // the build itself did not run.
        assertLt(v.pendingRevenue(), 5 ether / 20, "unreasonably large amount left undeployed");

        assertApproxEqRel(v.currentLeverage(), 2.96e18, 0.02e18, "leverage off target");
        assertGe(v.healthBps(), 12_000, "build must clear the health floor");
        assertApproxEqRel(v.nav(), 5 ether - bounty, 0.01e18, "build lost more than 1%");
    }

    function test_harvestPaysHoldersSeventyAndProjectThirty() public {
        _tax(5 ether);
        v.deployPending();

        // Appreciation, modelled the way a BNB rally actually reaches this vault: more
        // collateral on the supply leg, debt untouched. No oracle is mocked.
        IVBNB(vBNB).mint{value: 1 ether}();
        IERC20Min(vBNB).transfer(address(v), IERC20Min(vBNB).balanceOf(address(this)));

        uint256 gain = v.unrealisedGain();
        assertApproxEqRel(gain, 1 ether, 0.02e18, "vault should see the gain");

        uint256 projectBefore = PROJECT.balance;
        uint256 harvestedBefore = v.totalHarvested();

        uint256 bounty = v.harvest();
        uint256 toProject = PROJECT.balance - projectBefore;
        uint256 toHolders = v.totalHarvested() - harvestedBefore;
        uint256 freed = toProject + toHolders + bounty;

        assertApproxEqRel(freed, gain, 0.02e18, "harvest must free the gain, no more");
        assertEq(bounty, freed * 50 / 10_000, "harvest bounty is 0.5%");
        uint256 net = freed - bounty;
        assertApproxEqAbs(toProject, net * 3000 / 10_000, 2, "project share must be 30%");
        assertApproxEqAbs(toHolders, net - net * 3000 / 10_000, 2, "holder share must be 70%");

        assertGe(v.healthBps(), 12_000, "harvest must not breach the health floor");
        vm.expectRevert(bytes(unicode"LeverVault: no gain to harvest yet / 暂无可分配的收益"));
        v.harvest();
    }

    function test_automaticPathPaysNoBountyAndDeploysEverything() public {
        _tax(5 ether);
        uint256 pendingBefore = v.pendingRevenue();

        v.kickstart();
        uint256 id = v.pendingRequestId();
        assertGt(id, 0, "kickstart must book a slot");
        // The slot is bought out of revenue, so the two must move together.
        assertLt(v.pendingRevenue(), pendingBefore, "fee not taken from revenue");

        uint256 callerBefore = address(this).balance;
        vm.prank(0xcf4EE25035CF883895110f367F5BA8172416a7F9);
        v.trigger(id);

        assertEq(address(this).balance, callerBefore, "automatic path must pay no bounty");
        // Same reason as the manual path above: a small windfall from the build's own swap can
        // remain, now correctly captured rather than lost.
        assertLt(v.pendingRevenue(), 5 ether / 20, "unreasonably large amount left undeployed");
        assertApproxEqRel(v.currentLeverage(), 2.96e18, 0.02e18, "leverage off target");
        assertGt(v.pendingRequestId(), 0, "next slot must already be booked");
    }

    function test_pendingActionReportsWhatTheNextWakeWillDo() public {
        assertEq(v.pendingAction(), 0, "idle vault has nothing to do");
        _tax(5 ether);
        assertEq(v.pendingAction(), 2, "should want to build");
        v.deployPending();
        // A deploy's own flash-repay swap can leave a small windfall in pendingRevenue (Finding
        // 1, seventh report) -- if it clears MIN_DEPLOY, the selector correctly wants one more
        // pass rather than losing it, which is the fix working, not a new defect. Converges in
        // a couple of passes; more than that means something did not actually shrink.
        for (uint256 i = 0; i < 3 && v.pendingAction() == 2; i++) {
            v.deployPending();
        }
        assertEq(v.pendingAction(), 0, "nothing left after a build");
    }

    receive() external payable {}
}
