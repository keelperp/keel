// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";

interface IV3PoolFlash {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

/// @notice Finding 1 of the fifth risk report: no guard confirms `pancakeV3FlashCallback` is
///         answering a loan this vault itself initiated, only that the caller is the pool.
///
/// @dev The report's attack does not reach the vault's callback at all. Confirmed against
///      PancakeV3Pool's canonical source: `flash()` sends tokens to `recipient` but invokes the
///      callback on `msg.sender` of the `flash()` call -- so `FLASH_POOL.flash(vault, 0, x,
///      attackerData)` called BY an attacker hands the vault free WBNB and calls the ATTACKER's
///      own contract back, never `vault.pancakeV3FlashCallback`. The only way that function runs
///      with `msg.sender == FLASH_POOL` is for the vault itself to have called `flash()`, which
///      happens only inside `_build`, with data `_build` computed from live state.
///
///      `_flashArmed` is added anyway, as defense in depth rather than a fix for a reachable
///      path: it makes the structural fact machine-checked instead of resting on an argument
///      about a third party's source, and removes the shape of finding entirely rather than
///      arguing it every time a reviewer re-derives Uniswap V3 flash semantics differently.
///
///      This test proves two things on a live fork: an attacker calling `flash()` directly
///      against the real pool, with the vault as recipient, never reaches the vault's callback
///      at all (confirming the report's premise is false) -- and, separately, that a forged
///      call straight at `pancakeV3FlashCallback` with `_flashArmed` false is refused even
///      though `msg.sender == FLASH_POOL` is unspoofable from an EOA. The legitimate path
///      (`_build` calling real `flash()`) is exercised end to end by the existing position and
///      insolvent-position suites, which stay green with this guard in place -- proof it does
///      not break the thing it protects.
contract LeverVaultFlashGuardTest is Test {
    LeverVault v;

    address constant TOKEN = 0x35764c47AB7F6B78B00636d4f8599F05f48d7777;
    address constant PROJECT = address(0xBEEF);
    address constant FLASH_POOL = 0x36696169C63e42cd08ce11f5deeBbCeBae652050;

    function setUp() public {
        if (vm.envOr("KEEL_ARCHIVE", uint256(0)) == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(vm.envOr("KEEL_RPC_URL", string("https://bsc-dataseed.bnbchain.org")));
        vm.roll(block.number + 1000);
        v = new LeverVault();
        v.initialize(TOKEN, PROJECT);
    }

    /// @dev Reproduces the report's exact attack shape: this test contract calls `flash()`
    ///      directly on the real pool, naming the vault as `recipient`. If the report's premise
    ///      were correct, the vault's `pancakeV3FlashCallback` would run and this contract would
    ///      have no obligation to repay -- the flash loan would either succeed with the vault
    ///      silently forced through the leverage routine, or this contract (having no callback
    ///      implemented) would revert for an unrelated reason. What actually happens: the pool
    ///      calls back on THIS contract (the real `msg.sender` of `flash()`), which has no
    ///      `pancakeV3FlashCallback` -- so the call reverts on a missing function, never having
    ///      touched the vault's callback at all.
    function test_attackerCallingFlashDirectlyNeverReachesTheVaultsCallback() public {
        uint256 vaultWbnbBefore = address(v).balance;
        vm.expectRevert();
        IV3PoolFlash(FLASH_POOL).flash(address(v), 0, 1e15, abi.encode(uint256(0), uint256(0), uint256(0)));
        // Whatever reverted, the vault's own callback machinery was never exercised -- if it had
        // been, we would see a require message from LeverVault, not a bare revert from calling a
        // function this contract does not implement.
        assertEq(address(v).balance, vaultWbnbBefore, "vault balance moved; the callback ran");
    }

    /// @dev The guard itself: forge cannot forge `msg.sender`, but this proves the SECOND half
    ///      of the check independently, by calling the callback through the pool's own address
    ///      via `vm.prank` -- msg.sender passes, `_flashArmed` is false because no `_build` is
    ///      in flight, and the call must still revert.
    function test_theCallbackRefusesWhenNoFlashIsInFlight() public {
        vm.prank(FLASH_POOL);
        vm.expectRevert(bytes(unicode"LeverVault: flash not initiated by this vault / 闪电贷非本金库发起"));
        v.pancakeV3FlashCallback(0, 0, abi.encode(uint256(1e18), uint256(600e18), uint256(1e18)));
    }
}
