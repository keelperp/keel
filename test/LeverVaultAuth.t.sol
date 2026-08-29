// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";

/// @notice Rule 006 / 008 coverage for every gate on the vault. Forked because
///         `initialize` enters a Venus market, but no test here moves a position.
contract LeverVaultAuthTest is Test {
    LeverVault v;

    address constant TOKEN = 0x35764c47AB7F6B78B00636d4f8599F05f48d7777;
    address constant PROJECT = address(0xBEEF);
    address constant TRIGGER_SERVICE = 0xcf4EE25035CF883895110f367F5BA8172416a7F9;

    function setUp() public {
        // bsc-dataseed is load balanced across nodes at different heights — five calls in
        // a row spanned 19 blocks. Forge forks at one node's height and then reads state
        // from another, so Venus's stored accrual block can be AHEAD of the fork block.
        // Compound's `currentBlockNumber - accrualBlockNumberPrior` then underflows and
        // accrueInterest reverts "math error" intermittently. Rolling forward puts the
        // block number past anything a node could have recorded. Lagging the fork makes
        // it worse, not better.
        vm.roll(block.number + 1000);

        v = new LeverVault();
        v.initialize(TOKEN, PROJECT);
    }

    // -------------------------------------------------------------- initialize

    function test_initializeIsOnceOnly() public {
        vm.expectRevert(bytes(unicode"LeverVault: already initialized / 已初始化"));
        v.initialize(TOKEN, PROJECT);
    }

    function test_initializeRejectsZeroAddresses() public {
        LeverVault fresh = new LeverVault();
        vm.expectRevert(bytes(unicode"LeverVault: zero address / 地址为零"));
        fresh.initialize(address(0), PROJECT);

        LeverVault fresh2 = new LeverVault();
        vm.expectRevert(bytes(unicode"LeverVault: zero address / 地址为零"));
        fresh2.initialize(TOKEN, address(0));
    }

    function test_projectIsFixedAtInitializeAndHasNoSetter() public view {
        assertEq(v.project(), PROJECT, "project not recorded");
        // A setter would show up as a selector; assert the obvious one is absent.
        bytes4 sel = bytes4(keccak256("setProject(address)"));
        (bool ok, bytes memory ret) = address(v).staticcall(abi.encodeWithSelector(sel, address(1)));
        assertTrue(!ok && ret.length == 0, "a project setter exists");
    }

    // ----------------------------------------------------------------- rule 008

    function test_triggerRejectsEveryCallerThatIsNotTheService() public {
        vm.expectRevert(
            bytes(unicode"LeverVault: caller is not the trigger service / 调用方不是定时服务")
        );
        v.trigger(1);

        vm.prank(PROJECT);
        vm.expectRevert(
            bytes(unicode"LeverVault: caller is not the trigger service / 调用方不是定时服务")
        );
        v.trigger(1);
    }

    function test_triggerRejectsAnIdItIsNotAwaiting() public {
        assertEq(v.pendingRequestId(), 0, "should start idle");
        vm.prank(TRIGGER_SERVICE);
        vm.expectRevert(
            bytes(unicode"LeverVault: unknown or spent trigger / 未知或已消费的定时请求")
        );
        v.trigger(999999);

        vm.prank(TRIGGER_SERVICE);
        vm.expectRevert(
            bytes(unicode"LeverVault: unknown or spent trigger / 未知或已消费的定时请求")
        );
        v.trigger(0);
    }

    function test_settleSelfIsSelfOnly() public {
        vm.expectRevert(bytes(unicode"LeverVault: self only / 仅限自调用"));
        v.settleSelf(2);

        vm.prank(TRIGGER_SERVICE);
        vm.expectRevert(bytes(unicode"LeverVault: self only / 仅限自调用"));
        v.settleSelf(2);
    }

    // ------------------------------------------------------------- work guards

    function test_deployRefusesWhenThereIsNothingToDeploy() public {
        vm.expectRevert(bytes(unicode"LeverVault: nothing to deploy yet / 暂无可部署的税收"));
        v.deployPending();
    }

    function test_harvestRefusesWhenThereIsNoGain() public {
        vm.expectRevert(bytes(unicode"LeverVault: no gain to harvest yet / 暂无可分配的收益"));
        v.harvest();
    }

    function test_rebalanceRefusesWhileLeverageIsInsideTheBand() public {
        vm.expectRevert(bytes(unicode"LeverVault: leverage is inside the band / 杠杆仍在区间内"));
        v.rebalance();
    }

    function test_kickstartRefusesWhenAlreadyScheduled() public {
        vm.deal(address(v), 1 ether);
        v.kickstart();
        assertGt(v.pendingRequestId(), 0, "kickstart did not book a slot");
        vm.expectRevert(bytes(unicode"LeverVault: already scheduled / 已排定下一次结算"));
        v.kickstart();
    }

    function test_kickstartRefusesWhenTheVaultCannotPayTheFee() public {
        LeverVault broke = new LeverVault();
        broke.initialize(TOKEN, PROJECT);
        vm.expectRevert(bytes(unicode"LeverVault: could not schedule / 无法排定结算"));
        broke.kickstart();
    }

    // ------------------------------------------------------- rule 005 companion

    /// @dev The guard that keeps position operations alive. Without it, WBNB.withdraw and
    ///      vBNB.redeemUnderlying revert on their 2,300-gas stipend.
    function test_returnsFromWbnbAndVbnbAreNotCountedAsTax() public {
        address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        address vBNB = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;

        vm.deal(WBNB, 1 ether);
        vm.prank(WBNB);
        (bool ok,) = address(v).call{value: 1 ether}("");
        assertTrue(ok, "WBNB return must not revert");

        vm.deal(vBNB, 1 ether);
        vm.prank(vBNB);
        (bool ok2,) = address(v).call{value: 1 ether}("");
        assertTrue(ok2, "vBNB return must not revert");

        assertEq(v.pendingRevenue(), 0, "returned capital must not be booked as new tax");
        assertEq(v.totalReceived(), 0, "returned capital must not be booked as new tax");

        // ...and a real tax payment still is.
        vm.deal(address(this), 1 ether);
        (bool ok3,) = address(v).call{value: 1 ether}("");
        assertTrue(ok3);
        assertEq(v.pendingRevenue(), 1 ether, "real tax must still be booked");
    }

    /// @dev The stipend itself: prove the guard survives a 2,300-gas transfer.
    function test_receiveSurvivesA2300GasStipend() public {
        address WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
        vm.deal(WBNB, 1 ether);
        vm.prank(WBNB);
        (bool ok,) = address(v).call{value: 1 ether, gas: 2300}("");
        assertTrue(ok, "receive() must fit inside a .transfer() stipend for known senders");
    }

    receive() external payable {}
}
