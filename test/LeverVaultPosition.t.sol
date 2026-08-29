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
        assertEq(v.pendingRevenue(), 0, "revenue not fully deployed");

        assertApproxEqRel(v.currentLeverage(), 2.96e18, 0.02e18, "leverage off target");
        assertGe(v.healthBps(), 12_000, "build must clear the health floor");
        assertApproxEqRel(v.nav(), 5 ether - bounty, 0.01e18, "build lost more than 1%");
    }

    function test_harvestPaysHoldersSixtyAndProjectForty() public {
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
        assertApproxEqAbs(toProject, net * 4000 / 10_000, 2, "project share must be 40%");
        assertApproxEqAbs(toHolders, net - net * 4000 / 10_000, 2, "holder share must be 60%");

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
        assertEq(v.pendingRevenue(), 0, "automatic path must deploy everything");
        assertApproxEqRel(v.currentLeverage(), 2.96e18, 0.02e18, "leverage off target");
        assertGt(v.pendingRequestId(), 0, "next slot must already be booked");
    }

    function test_pendingActionReportsWhatTheNextWakeWillDo() public {
        assertEq(v.pendingAction(), 0, "idle vault has nothing to do");
        _tax(5 ether);
        assertEq(v.pendingAction(), 2, "should want to build");
        v.deployPending();
        assertEq(v.pendingAction(), 0, "nothing left after a build");
    }

    receive() external payable {}
}
