// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";

/// @notice The build swap's slippage floor, which an adversarial review found was shipped with no
///         test touching it at all.
///
/// @dev The floor cannot be driven end to end in forge: it lives inside
///      `pancakeV3FlashCallback`, which only the PancakeSwap pool may call, and reaching it needs
///      the real router to move real tokens. What IS testable, and what actually decides whether
///      the constant is right, is the arithmetic around it. Two bounds pin `MAX_BUILD_SLIP_BPS`
///      and this suite fails if either is crossed:
///
///        upper — at or above the buffer the floor lands below `owed`, where
///                `require(got >= owed)` already binds, so it would constrain nothing;
///        lower — it has to clear real slippage on the 0.01% WBNB/USDT tier, measured against
///                the Venus oracle: 0.109% at 6,000 USDT, 0.131% at 30,000, 0.215% at 120,000.
contract LeverVaultBuildFloorTest is Test {
    LeverVault v;

    /// @dev The buffer `pancakeV3FlashCallback` borrows over the repayment, as basis points.
    uint256 constant BUFFER_BPS = 30;      // owed * 1003 / 1000
    uint256 constant BPS = 10_000;

    /// @dev Worst slippage measured on the venue, in bps. 120,000 USDT is far above any build a
    ///      2% tax produces in one wake, so this is the pessimistic end.
    uint256 constant MEASURED_WORST_SLIP_BPS = 22;   // 0.215%, rounded up

    function setUp() public {
        vm.chainId(56);
        v = new LeverVault();
    }

    function _floorOverOwedBps() internal view returns (uint256) {
        // floor = fair * (BPS - MAX_BUILD_SLIP_BPS) / BPS, where fair = owed * (BPS+BUFFER)/BPS.
        uint256 owed = 1e18;
        uint256 fair = owed * (BPS + BUFFER_BPS) / BPS;
        uint256 floorOut = fair * (BPS - v.MAX_BUILD_SLIP_BPS()) / BPS;
        require(floorOut > owed, "floor does not clear owed");
        return (floorOut - owed) * BPS / owed;
    }

    function test_theFloorActuallyBindsAboveTheRepaymentBound() public view {
        uint256 over = _floorOverOwedBps();
        assertGt(over, 0, "floor must sit above owed or it constrains nothing");
        // The exit path's floor, applied here, would land BELOW owed -- which is why it could not
        // simply be reused and a separate constant exists.
        uint256 exitFloor = 1e18 * (BPS + BUFFER_BPS) / BPS * (BPS - v.MAX_SWAP_SLIP_BPS()) / BPS;
        assertLt(exitFloor, 1e18, "the exit floor is expected to be useless here; that is the point");
    }

    function test_theBudgetIsUnderTheCeilingTheBufferImposes() public view {
        // Above the buffer, the floor stops binding. Off-by-one on this constant silently
        // disables the protection rather than loosening it.
        assertLt(v.MAX_BUILD_SLIP_BPS(), BUFFER_BPS, "budget at or above the buffer binds nothing");
    }

    function test_theBudgetClearsSlippageMeasuredOnTheVenue() public view {
        // Too tight and a legitimate build reverts, which strands tax rather than deploying it --
        // worse than the leak the floor prevents. The first attempt at this fix allowed only
        // 0.1495% and would have failed any build over roughly 50,000 USDT.
        assertGe(v.MAX_BUILD_SLIP_BPS(), MEASURED_WORST_SLIP_BPS,
            "budget is under measured slippage; legitimate builds would revert");
    }

    function test_theFloorCapsWhatASandwichCanTake() public view {
        // Without it a sandwich takes the whole buffer. The cap is the budget itself, and we do
        // not claim more than the buffer's size allows.
        uint256 withoutFloor = BUFFER_BPS;
        uint256 withFloor = v.MAX_BUILD_SLIP_BPS() * (BPS + BUFFER_BPS) / BPS;
        assertLt(withFloor, withoutFloor, "the floor must reduce the extractable amount");
    }
}
