// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";

/// @notice A stand-in for a broken or hostile `project` address: no payable receive, no
///         fallback, so any plain BNB transfer to it reverts. Exactly the shape the twelfth
///         risk report describes -- and, since `project` has no setter, permanent once set.
contract RevertingReceiver {}

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

/// @notice Twelfth risk report: `project.call{value}` reverting used to revert the whole
///         `_harvest` via `require(sent, ...)`. Since `project` is fixed at `initialize()` with
///         no setter, a broken address there bricked every harvest forever -- gain would stay
///         locked inside the leveraged position, growing liquidation exposure with no way to
///         ever recover.
///
/// @dev Fixed by attempting the project payout FIRST, before the dividend deposit, and
///      redirecting a failed send into `toHolders` rather than reverting -- holders receive the
///      full `net` gain instead of the harvest bricking entirely, and `ProjectPayoutFailed` is
///      emitted so the failure stays visible rather than silently absorbed.
contract LeverVaultProjectPayoutFailureTest is Test {
    LeverVault v;
    RevertingReceiver brokenProject;
    address div;

    address constant TOKEN = 0x35764c47AB7F6B78B00636d4f8599F05f48d7777;
    address constant vBNB = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function setUp() public {
        if (vm.envOr("KEEL_ARCHIVE", uint256(0)) == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(vm.envOr("KEEL_RPC_URL", string("https://bsc-dataseed.bnbchain.org")));
        vm.roll(block.number + 1000);
        brokenProject = new RevertingReceiver();
        v = new LeverVault();
        v.initialize(TOKEN, address(brokenProject));
        div = IFlapTaxTokenLike(TOKEN).dividendContract();
        vm.deal(address(this), 1000 ether);
    }

    function _tax(uint256 amount) internal {
        (bool ok,) = address(v).call{value: amount}("");
        require(ok, "tax failed");
    }

    function test_harvestSucceedsAndRedirectsToHoldersWhenProjectCannotReceive() public {
        _tax(5 ether);
        v.deployPending();

        IVBNBLike(vBNB).mint{value: 1 ether}();
        IERC20Like(vBNB).transfer(address(v), IERC20Like(vBNB).balanceOf(address(this)));

        uint256 gain = v.unrealisedGain();
        assertGt(gain, 0, "test setup produced no gain to harvest");

        uint256 projectBalanceBefore = address(brokenProject).balance;
        uint256 dividendWbnbBefore = IERC20Like(WBNB).balanceOf(div);
        uint256 callerBalanceBefore = address(this).balance;

        vm.recordLogs();
        uint256 bounty = v.harvest();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Nothing reached the broken address.
        assertEq(address(brokenProject).balance, projectBalanceBefore, "the broken project must not have received anything");
        assertEq(v.totalToProject(), 0, "totalToProject must not move on a failed send");

        // The caller received exactly its bounty, and the dividend contract received exactly
        // the rest -- the FULL gain, not 70% of it. Nothing is left unaccounted for.
        uint256 callerReceived = address(this).balance - callerBalanceBefore;
        assertEq(callerReceived, bounty, "caller must receive exactly the bounty");
        uint256 dividendReceived = IERC20Like(WBNB).balanceOf(div) - dividendWbnbBefore;
        assertGt(dividendReceived, 0, "holders must have received the redirected share");
        assertApproxEqRel(
            dividendReceived + bounty, gain, 0.01e18,
            "bounty plus holder share must account for the whole gain -- nothing stranded"
        );

        bool sawFailureEvent = false;
        bytes32 sig = keccak256("ProjectPayoutFailed(uint256)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == sig) sawFailureEvent = true;
        }
        assertTrue(sawFailureEvent, "ProjectPayoutFailed must be emitted");
    }

    /// @dev The report's own claim: without the fix, this call reverts and NEVER succeeds again
    ///      for this vault (project has no setter). With the fix, harvest keeps working
    ///      indefinitely regardless of the broken project.
    function test_harvestKeepsWorkingOnRepeatedCyclesDespiteTheBrokenProject() public {
        for (uint256 i = 0; i < 2; i++) {
            _tax(2 ether);
            v.deployPending();
            IVBNBLike(vBNB).mint{value: 0.5 ether}();
            IERC20Like(vBNB).transfer(address(v), IERC20Like(vBNB).balanceOf(address(this)));
            if (v.unrealisedGain() >= 0.02 ether) {
                v.harvest();
            }
        }
        assertEq(v.totalToProject(), 0, "the broken project never received anything across cycles");
    }

    receive() external payable {}
}
