// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LeverVault} from "../src/flap/LeverVault.sol";
import {IVBNB, IERC20Min} from "../src/interfaces/IVenus.sol";

/// @notice Tax in -> leveraged BNB position -> gain out, as one atomic eth_call against
///         live BNB Chain state. BSC prunes state after ~96s and has no free archive node,
///         so a multi-step fork test cannot survive; one call can.
contract FlapProbe {
    address constant TOKEN = 0xE1cE50807dcFe16774B6cc38E1c315019E977777;
    address constant PROJECT = address(0xBEEF);

    struct Out {
        uint256 pendingAfterTax;
        uint256 deployBounty;
        uint256 navAfter;
        uint256 leverage;
        uint256 health;
        uint256 supplyUsd;
        uint256 borrowUsd;
        uint256 costBasis;
        uint256 gasReceive;
        uint256 gasDeploy;
    }

    function run(uint256 tax) external returns (Out memory o) {
        LeverVault v = new LeverVault();
        v.initialize(TOKEN, PROJECT);

        uint256 g0 = gasleft();
        (bool ok,) = address(v).call{value: tax}("");
        o.gasReceive = g0 - gasleft();
        require(ok, "receive failed");
        o.pendingAfterTax = v.pendingRevenue();

        uint256 g1 = gasleft();
        o.deployBounty = v.deployPending();
        o.gasDeploy = g1 - gasleft();

        o.navAfter = v.nav();
        o.leverage = v.currentLeverage();
        o.health = v.healthBps();
        (o.supplyUsd, o.borrowUsd) = v.positionUsd();
        o.costBasis = v.costBasis();
    }

    /// @notice Walk the path one stage at a time and report the last stage that survived.
    ///         An empty revert says only that something decoded nothing; this says where.
    function step(uint256 tax, uint8 upTo) external returns (uint8 reached, string memory note) {
        LeverVault v = new LeverVault();
        reached = 1;
        if (upTo == 1) return (reached, "constructed");

        v.initialize(TOKEN, PROJECT);
        reached = 2;
        if (upTo == 2) return (reached, "initialized");

        (bool ok,) = address(v).call{value: tax}("");
        require(ok, "receive failed");
        reached = 3;
        if (upTo == 3) return (reached, "tax received");

        v.positionUsd();
        v.nav();
        v.healthBps();
        reached = 4;
        if (upTo == 4) return (reached, "views ok");

        try v.deployPending() returns (uint256) {
            reached = 5;
            return (reached, "deployed");
        } catch Error(string memory reason) {
            return (reached, reason);
        } catch (bytes memory raw) {
            return (reached, raw.length == 0 ? "EMPTY REVERT in deployPending" : "non-string revert");
        }
    }

    struct HarvestOut {
        uint256 navBeforeGain;
        uint256 navAfterGain;
        uint256 gainSeen;
        uint256 harvestBounty;
        uint256 totalHarvested;
        uint256 navAfterHarvest;
        uint256 healthAfter;
        uint256 toProject;
        uint256 noGainGuard; // 1 when a second harvest correctly refuses
    }

    /// @notice Build, make the position appreciate, then harvest into dividends.
    /// @dev Appreciation is simulated by handing the vault extra vBNB collateral — that
    ///      raises the supply leg without touching debt, which is exactly what a BNB rally
    ///      does to this position. No oracle is mocked.
    function harvestPath(uint256 tax, uint256 gain, address token_) external returns (HarvestOut memory h) {
        LeverVault v = new LeverVault();
        v.initialize(token_, PROJECT);
        (bool ok,) = address(v).call{value: tax}("");
        require(ok, "receive failed");
        v.deployPending();
        h.navBeforeGain = v.nav();

        IVBNB(vBNB_).mint{value: gain}();
        IERC20Min(vBNB_).transfer(address(v), IERC20Min(vBNB_).balanceOf(address(this)));
        h.navAfterGain = v.nav();
        h.gainSeen = v.unrealisedGain();

        h.harvestBounty = v.harvest();
        h.totalHarvested = v.totalHarvested();
        h.toProject = v.totalToProject();
        h.navAfterHarvest = v.nav();
        h.healthAfter = v.healthBps();

        try v.harvest() returns (uint256) {
            h.noGainGuard = 0;
        } catch {
            h.noGainGuard = 1;
        }
    }

    address constant vBNB_ = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;

    receive() external payable {}
}
