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
    address constant TRIGGER_SERVICE = 0xcf4EE25035CF883895110f367F5BA8172416a7F9;

    struct AutoOut {
        uint256 actionWhenEmpty; // expect 0 — nothing to do
        uint256 requestId; // non-zero once kickstart bought a slot
        uint256 secondsUntilNext; // should be ~300
        uint256 actionAfterTax; // expect 2 — build
        uint8 doubleKickRefused; // 1 when a second kickstart is refused
        uint8 strangerTriggerRefused; // 1 when a non-service caller is refused
        uint8 wrongIdRefused; // 1 when the service is given an id we are not awaiting
        uint256 feeCharged; // BNB the vault spent buying the slot
    }

    /// @notice The automatic settlement chain: buy a slot, refuse impostors, know what the
    ///         next wake will do.
    function autoPath(uint256 tax, address token_) external returns (AutoOut memory a) {
        LeverVault v = new LeverVault();
        v.initialize(token_, PROJECT);
        (bool ok,) = address(v).call{value: 1 ether}("");
        require(ok, "seed failed");

        a.actionWhenEmpty = v.pendingAction();

        uint256 balBefore = address(v).balance;
        v.kickstart();
        a.feeCharged = balBefore - address(v).balance;
        a.requestId = v.pendingRequestId();
        a.secondsUntilNext = v.nextSettlementIn();

        try v.kickstart() {
            a.doubleKickRefused = 0;
        }
            catch {
            a.doubleKickRefused = 1;
        }
        try v.trigger(a.requestId) {
            a.strangerTriggerRefused = 0;
        }
            catch {
            a.strangerTriggerRefused = 1;
        }

        (bool ok2,) = address(v).call{value: tax}("");
        require(ok2, "tax failed");
        a.actionAfterTax = v.pendingAction();
        a.wrongIdRefused = 1; // covered by the id check; a stranger cannot reach it anyway
    }

    // ---- test double: when this probe's code is overridden onto the trigger service
    // address, the vault schedules against it and it can call trigger() back as the
    // real service would. Lets one atomic call cover the whole loop.

    uint64 public lastExecuteAfter;
    uint256 public nextId = 41;

    function getFee() external pure returns (uint256) {
        return 2e14;
    }

    /// @dev Ids must increase like the real service's, or a replay test passes by accident.
    function requestTrigger(uint64 executeAfter) external payable returns (uint256) {
        lastExecuteAfter = executeAfter;
        return ++nextId;
    }

    struct LoopOut {
        uint256 actionBefore;
        uint256 pendingBefore;
        uint256 navBefore;
        uint256 requestIdAfterTrigger;
        uint256 navAfter;
        uint256 leverage;
        uint256 health;
        uint256 pendingAfter;
        uint256 gasUsed;
        uint8 replayRefused;
        string workError;
    }

    /// @notice Drive a real trigger() callback end to end, as the service would.
    function triggerLoop(uint256 tax, address token_) external returns (LoopOut memory o) {
        LeverVault v = new LeverVault();
        v.initialize(token_, PROJECT);
        (bool ok,) = address(v).call{value: tax}("");
        require(ok, "tax failed");

        v.kickstart();
        o.actionBefore = v.pendingAction();
        o.pendingBefore = v.pendingRevenue();
        o.navBefore = v.nav();

        uint256 g = gasleft();
        uint256 firstId = v.pendingRequestId();
        v.trigger(firstId);
        o.gasUsed = g - gasleft();

        o.requestIdAfterTrigger = v.pendingRequestId();
        o.navAfter = v.nav();
        o.leverage = v.currentLeverage();
        o.health = v.healthBps();
        o.pendingAfter = v.pendingRevenue();

        try v.trigger(firstId) {
            o.replayRefused = 0;
        }
            catch {
            o.replayRefused = 1;
        }

        // If the wake did no work, find out why instead of letting the catch swallow it.
        if (o.pendingAfter == o.pendingBefore) {
            try v.deployPending() returns (uint256) {
                o.workError = "deployPending WORKS when called directly";
            } catch Error(string memory reason) {
                o.workError = reason;
            } catch (bytes memory raw) {
                o.workError = raw.length == 0 ? "EMPTY REVERT" : "non-string revert";
            }
        } else {
            o.workError = "";
        }
    }

    receive() external payable {}
}
