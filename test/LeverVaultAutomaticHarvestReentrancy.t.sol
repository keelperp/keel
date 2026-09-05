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

interface IFlapTaxTokenLike {
    function dividendContract() external view returns (address);
}

/// @notice `project` is the payout call `_harvest` makes to a creator-controlled address, and
///         on the automatic settlement path (trigger -> settleSelf -> _harvest) nothing sets
///         `_entered` before that call happens. `settleSelf` is external and self-only, but
///         self-only is not reentrancy-safe: `_entered` is the same storage slot regardless of
///         who called in, and prior to this fix nothing on this path ever set it.
contract ReentrantProject {
    LeverVault public vault;
    bool public armed;
    bool public reentryReverted;

    constructor(LeverVault v) {
        vault = v;
    }

    function arm() external {
        armed = true;
        reentryReverted = false;
    }

    receive() external payable {
        if (armed) {
            armed = false;
            (bool ok,) = address(vault).call(abi.encodeWithSignature("deployPending()"));
            reentryReverted = !ok;
        }
    }
}

/// @dev Isolates the reentrancy question from whether the reentrant call would have succeeded
///      on its own merits: a plain contract with no reentrant attempt, standing in for an
///      ordinary, non-hostile `project`, so the fix's effect on the honest case is also proven.
contract PlainProject {
    receive() external payable {}
}

/// @notice Thirteenth risk report: settleSelf() (external, called only via trigger()'s own
///         `this.settleSelf(action)`) carried no nonReentrant modifier, so `_entered` stayed
///         false for the whole automatic _deploy/_harvest/_rebalance call. `_harvest` calls the
///         creator-controlled `project` address before finishing (before totalHarvested is used
///         downstream, before the WBNB wrap/dividend deposit, before the health check, before
///         the bounty) -- a hostile `project` reentering deployPending() from its receive() hook
///         would find `_entered` still false and the reentrant call would go straight through,
///         letting it front-run every other caller for the deploy bounty on every scheduled
///         harvest, or -- depending on what the reentrant deploy consumes -- roll back the whole
///         automatic harvest and force holders onto the paid manual path instead.
///
/// @dev Fixed by adding `nonReentrant` to `settleSelf` itself, exactly mirroring the protection
///      `deployPending()`/`harvest()`/`rebalance()` already give their own manual callers: since
///      `_entered` is a state variable, not a call-type property, guarding the one path that
///      skipped it closes the window everywhere it is reachable, not just at the one call site
///      this report happened to name.
contract LeverVaultAutomaticHarvestReentrancyTest is Test {
    LeverVault v;
    ReentrantProject hostileProject;

    address constant TOKEN = 0x35764c47AB7F6B78B00636d4f8599F05f48d7777;
    address constant vBNB = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function setUp() public {
        if (vm.envOr("KEEL_ARCHIVE", uint256(0)) == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(vm.envOr("KEEL_RPC_URL", string("https://bsc-dataseed.bnbchain.org")));
        vm.roll(block.number + 1000);
        v = new LeverVault();
        hostileProject = new ReentrantProject(v);
        v.initialize(TOKEN, address(hostileProject));
        vm.deal(address(this), 1000 ether);
    }

    function _tax(uint256 amount) internal {
        (bool ok,) = address(v).call{value: amount}("");
        require(ok, "tax failed");
    }

    /// @dev Reproduces the automatic path exactly: trigger() reaches _harvest only through
    ///      `this.settleSelf(action)`, itself gated by `require(msg.sender == address(this))`.
    ///      Pranking as the vault is the direct way to invoke that path without standing up
    ///      Flap's whole trigger service.
    function _settleAsAutomatic(uint8 action) internal {
        vm.prank(address(v));
        v.settleSelf(action);
    }

    function test_reentrantProjectCannotWalkBackIntoDeployPendingDuringAutomaticHarvest() public {
        _tax(5 ether);
        v.deployPending();

        IVBNBLike(vBNB).mint{value: 1 ether}();
        IERC20Like(vBNB).transfer(address(v), IERC20Like(vBNB).balanceOf(address(this)));
        assertGt(v.unrealisedGain(), 0.02 ether, "test setup produced no gain to harvest");

        // Leave enough pendingRevenue that a reentrant deployPending(), if it got through the
        // guard, would fully succeed rather than reverting on its own "nothing to deploy yet"
        // check -- otherwise a passing test would prove nothing about the guard itself.
        _tax(0.05 ether);
        assertGe(v.pendingRevenue(), v.MIN_DEPLOY(), "reentrant deploy would have nothing to work with");

        hostileProject.arm();
        uint256 deployedBefore = v.totalDeployed();
        uint256 pendingBefore = v.pendingRevenue();

        _settleAsAutomatic(3); // 3 = harvest

        assertTrue(hostileProject.reentryReverted(), "the reentrant deployPending() call must have been rejected");
        assertEq(v.totalDeployed(), deployedBefore, "no reentrant deploy may have executed during the automatic harvest");
        assertEq(v.pendingRevenue(), pendingBefore, "pendingRevenue the reentrant call would have consumed must be untouched");
    }

    /// @dev The guard must not cost the honest case anything: an ordinary, non-reentrant
    ///      project still gets paid and the automatic harvest still completes normally.
    function test_automaticHarvestStillPaysAnOrdinaryProjectNormally() public {
        PlainProject plainProject = new PlainProject();
        LeverVault v2 = new LeverVault();
        v2.initialize(TOKEN, address(plainProject));

        (bool ok,) = address(v2).call{value: 5 ether}("");
        require(ok, "tax failed");
        v2.deployPending();

        IVBNBLike(vBNB).mint{value: 1 ether}();
        IERC20Like(vBNB).transfer(address(v2), IERC20Like(vBNB).balanceOf(address(this)));
        assertGt(v2.unrealisedGain(), 0.02 ether, "test setup produced no gain to harvest");

        uint256 projectBefore = address(plainProject).balance;
        vm.prank(address(v2));
        v2.settleSelf(3);

        assertGt(address(plainProject).balance, projectBefore, "the honest project must still be paid on the automatic path");
        assertGt(v2.totalToProject(), 0, "totalToProject must move for a successful automatic payout");
    }

    receive() external payable {}
}
