// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import "forge-std/Test.sol";
import {LeverVault} from "../src/flap/LeverVault.sol";

contract FlapDeployTest is Test {
    LeverVault v;

    function setUp() public {
        // initialize() enters Venus markets, so this suite needs live BSC state. Creating the
        // fork here instead of relying on a --fork-url flag means a plain `forge test` passes
        // too, which is what rule 006 asks a reviewer to run.
        vm.createSelectFork(vm.envOr("KEEL_RPC_URL", string("https://bsc-dataseed.bnbchain.org")));
        v = new LeverVault();
        v.initialize(0xE1cE50807dcFe16774B6cc38E1c315019E977777, address(0xBEEF));
    }

    function test_deploy() public {
        vm.deal(address(this), 100 ether);
        (bool ok,) = address(v).call{value: 5 ether}("");
        assertTrue(ok);
        uint256 b = v.deployPending();
        emit log_named_decimal_uint("bounty", b, 18);
        emit log_named_decimal_uint("nav", v.nav(), 18);
        emit log_named_decimal_uint("leverage", v.currentLeverage(), 18);
        emit log_named_uint("health bps", v.healthBps());
    }
    receive() external payable {}
}
