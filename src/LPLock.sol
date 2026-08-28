// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Holds graduated LP tokens. There is deliberately no withdrawal function —
///         not a timelock, not a long lock, no function at all. Read the bytecode.
contract LPLock {
    event Locked(address indexed pair, uint256 amount);

    function note(address pair, uint256 amount) external {
        emit Locked(pair, amount);
    }
}
