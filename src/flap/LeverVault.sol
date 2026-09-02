// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VaultBaseV2} from "./VaultBaseV2.sol";
import {IFlapTriggerService, ITriggerReceiver} from "./IFlapTriggerService.sol";
import {VaultUISchema, VaultMethodSchema, FieldDescriptor, ApproveAction} from "./IVaultSchemasV1.sol";
import {
    IVToken,
    IComptroller,
    IVenusOracle,
    IERC20Min,
    IVBNB,
    IWNative,
    IV3Router,
    IV3Pool
} from "../interfaces/IVenus.sol";

/// @dev Only the one getter this vault needs. Importing Flap's full token interface would
///      drag in an OpenZeppelin dependency for a single function signature.
interface IFlapTaxToken {
    function dividendContract() external view returns (address);
}

interface IDividend {
    function deposit(uint256 amount) external;
    function dividendToken() external view returns (address);
    function totalShares() external view returns (uint256);
}

/// @title LeverVault — a Flap vault whose treasury is a leveraged BNB position
///
/// @notice Every buy and sell of the token sends native BNB here. Instead of sitting as
///         cash, that BNB is levered into a BNB long the vault holds on Venus itself.
///         When the position gains, `harvest()` sends the gain to every holder through
///         the token's own dividend contract.
///
///         So the treasury moves when nobody trades. It has no operator account behind
///         it, no published NAV, and no pause: `nav()` is a view over Venus state.
///
/// @dev  Flap compliance notes, rule by rule:
///       - **005 (receive gas):** `receive()` does one add, one add and one event. No loop,
///         no external call, no delegatecall. Everything expensive is behind
///         `deployPending()`, which anyone may call and which pays for the privilege.
///       - **003 (fairness):** no privileged role can change slippage, routing, timing or
///         triggers. The route, the fee tier, the health floor and every bounty are
///         constants. The three working functions are permissionless and paid, so an
///         insider has no advantage a bot does not also have.
///       - **009 (emergency):** this vault runs behind a BeaconProxy, so it is exempt and
///         deliberately ships no emergency withdraw. The Guardian's upgrade path is the
///         emergency mechanism.
///       - **001 (permissions):** there are no role-gated functions to grant the Guardian.
///         Nothing here is privileged, so nothing can lock the Guardian out.
contract LeverVault is VaultBaseV2, ITriggerReceiver {
    // ---------------------------------------------------------------- constants

    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant vBNB = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;
    address internal constant vUSDT = 0xfD5840Cd36d94D7229439859C0112a4185BC0255;
    address internal constant COMPTROLLER = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address internal constant V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    /// @dev Swap tier: WBNB/USDT 0.01%, ~$11.8M deep. Flash tier is separate on purpose —
    ///      a V3 pool is locked during its own flash callback, so borrowing and swapping
    ///      in one pool reverts LOK.
    uint24 internal constant SWAP_FEE = 100;

    /// @notice How far a swap may land below the oracle's price before it reverts, in bps.
    /// @dev    The exit path had no floor at all: `harvest` and `rebalance` repaid whatever the
    ///         pool returned, so a sandwiched unwind completed at the attacker's price. The
    ///         build path was already covered by the flash repayment check, which reverts if the
    ///         swap cannot cover what is owed.
    ///
    ///         The reference is Venus's own ResilientOracle -- the same price that decides
    ///         whether this position gets liquidated -- rather than a second feed with its own
    ///         failure modes. 300 bps is deliberately loose: the pool legitimately drifts from
    ///         the oracle between updates, and a floor tight enough to catch every sandwich
    ///         would also stop the vault from deleveraging in exactly the fast market where
    ///         deleveraging matters most. This bounds the loss; it does not eliminate it.
    uint256 public constant MAX_SWAP_SLIP_BPS = 300;
    address internal constant FLASH_POOL = 0x36696169C63e42cd08ce11f5deeBbCeBae652050; // WBNB/USDT 0.05%

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @notice 3x is the ceiling Venus's 80% collateral factor can hold at a 1.20 health
    ///         floor: health = CF*L/(L-1), and 5x is exactly 1.00 — the liquidation point.
    uint256 public constant TARGET_LEVERAGE = 3 * WAD;
    uint256 public constant MIN_HEALTH_BPS = 12_000;
    /// @notice Below this the vault deleverages immediately, waiving the rebalance cooldown.
    /// @dev    Raised from 11_000 after Flap's pre-audit observed how narrow the window was.
    ///         A build lands at health 1.205; at 11_000 the collateral had to fall 8.3% before
    ///         anything happened, and the next scheduled wake can be an hour away when the
    ///         previous one found nothing to do. 11_300 moves the trigger to a 6.5% fall.
    ///
    ///         It is not set higher because a rescue deleverages back to TARGET_LEVERAGE, which
    ///         is health 1.20: the closer this sits to that, the less room each rescue buys and
    ///         the more often ordinary volatility pays for a swap. At 11_500 a 4.6% move would
    ///         trigger one, which BNB does on a normal day.
    uint256 public constant URGENT_HEALTH_BPS = 11_300;

    /// @notice The floor a redeem-then-repay pass may dip to, as opposed to a plain redeem.
    /// @dev Repaying raises health: for s > b, d/dx[(s-x)/(b-x)] > 0, so redeeming collateral
    ///      and immediately spending it on debt ends higher than it started, and the pass is
    ///      atomic so the dip between the two legs is never observable to a liquidator.
    ///
    ///      Sizing this pass against MIN_HEALTH_BPS instead made every deleverage a no-op, by
    ///      arithmetic rather than by accident: `rebalance` triggers above 3x * 1.05, which is
    ///      health 1.1721, and `_maxRedeemableBnb` only returns a non-zero cap above health
    ///      1.20. So the repay loop broke on its first pass, the tail redeemed nothing, and the
    ///      closing health check reverted the whole call -- leverage and health identical
    ///      before and after. The urgent rescue at 1.13 was blocked the same way. A position
    ///      that drifted past the band could not come back, on any path.
    uint256 public constant REPAY_FLOOR_BPS = 10_200;
    uint256 public constant REBALANCE_BAND_BPS = 500;

    /// @notice Paid to whoever does the work, in the asset that work produced. Constant,
    ///         so no role can tune insider profit (rule 003).
    uint256 public constant DEPLOY_BOUNTY_BPS = 25;
    uint256 public constant HARVEST_BOUNTY_BPS = 50;
    uint256 public constant REBALANCE_BOUNTY_BPS = 30;
    uint256 public constant MIN_DEPLOY = 0.01 ether;
    /// @notice Of every harvest, after the caller's bounty: 30% to the project, 70% to
    ///         holders. Constant — nobody can move it, including the project.
    uint256 public constant PROJECT_SHARE_BPS = 3000;

    /// @notice Flap's trigger service on BNB Chain. It calls `trigger()` on a schedule,
    ///         which is why holders never have to press anything.
    address internal constant TRIGGER_SERVICE = 0xcf4EE25035CF883895110f367F5BA8172416a7F9;
    /// @notice Settlement cadence when there is work to do.
    uint64 public constant TRIGGER_INTERVAL = 5 minutes;
    /// @notice Cadence when the last wake found nothing. Checking every 5 minutes forever
    ///         would spend the treasury on trigger fees during a quiet market.
    uint64 public constant IDLE_INTERVAL = 1 hours;
    /// @dev Rule 008 caps a callback at 2,000,000 gas. A build measures 1.20-1.24M, so the
    ///      schedule is bought FIRST and the work is attempted second, inside a try —
    ///      a failed job must never break the chain that would have retried it.
    uint256 internal constant WORK_GAS_FLOOR = 1_800_000;
    uint256 public constant MIN_HARVEST = 0.02 ether;

    // ------------------------------------------------------- storage (append-only)

    // This vault runs behind a BeaconProxy, so what would be immutables live in storage
    // and are written once by initialize(). Declared in this order; an upgrade may append
    // below but must never reorder or remove what is above.

    /// @notice The Flap tax token this vault was created for.
    address public token;
    /// @notice Receives PROJECT_SHARE_BPS of every harvest. Set once at initialize and
    ///         never movable — there is no setter, by design.
    address public project;
    /// @notice Lifetime BNB received from the tax processor.
    uint256 public totalReceived;
    /// @notice BNB that has arrived but is not yet in the position.
    uint256 public pendingRevenue;
    /// @notice Lifetime BNB put into the position.
    uint256 public totalDeployed;
    /// @notice Lifetime WBNB pushed to holders as dividends.
    uint256 public totalHarvested;
    /// @notice Cost basis of the live position, in BNB, for measuring gain.
    uint256 public costBasis;
    uint256 public lastRebalanceAt;
    /// @notice Lifetime BNB paid to the project out of harvests.
    uint256 public totalToProject;
    /// @notice The one trigger request this vault is waiting on. Zero means the chain is
    ///         idle and anyone may restart it with `kickstart()`.
    uint256 public pendingRequestId;

    bool private _entered;

    // ------------------------------------------------------------------- events

    event Received(address indexed from, uint256 amount);
    event Deployed(address indexed caller, uint256 amount, uint256 bounty, uint256 leverage);
    event Harvested(address indexed caller, uint256 toHolders, uint256 toProject, uint256 bounty);
    event Rebalanced(address indexed caller, uint256 leverageBefore, uint256 leverageAfter, uint256 bounty);
    event Scheduled(uint256 indexed requestId, uint64 executeAfter);
    event Settled(uint256 indexed requestId, uint8 action);
    event WorkFailed(uint256 indexed requestId, bytes reason);

    // Rule 004: the UI renders revert strings verbatim and cannot decode custom error
    // selectors, so every revert here is a require() with an inline bilingual literal.

    modifier nonReentrant() {
        require(!_entered, unicode"LeverVault: reentrant call / 重入调用");
        _entered = true;
        _;
        _entered = false;
    }

    // --------------------------------------------------------------- initialize

    function initialize(address token_, address project_) external {
        require(token == address(0), unicode"LeverVault: already initialized / 已初始化");
        require(
            token_ != address(0) && project_ != address(0), unicode"LeverVault: zero address / 地址为零"
        );
        token = token_;
        project = project_;

        address[] memory mk = new address[](1);
        mk[0] = vBNB;
        IComptroller(COMPTROLLER).enterMarkets(mk);

        IERC20Min(USDT).approve(V3_ROUTER, type(uint256).max);
        IERC20Min(WBNB).approve(V3_ROUTER, type(uint256).max);
        IERC20Min(USDT).approve(vUSDT, type(uint256).max);
    }

    // ------------------------------------------------------- rule 005: cheap receive

    /// @notice Tax revenue arrives here.
    /// @dev Two SSTOREs and one event. No loop, no external call, no delegatecall.
    ///      The work of turning this into a position is `deployPending()`, which anyone
    ///      may call — putting it here would risk the 1,000,000 gas cap and, if it ever
    ///      reverted, would break tax collection for the token permanently.
    receive() external payable {
        // WBNB.withdraw() and vBNB.redeemUnderlying() both hand BNB back with a 2,300-gas
        // stipend (PUSH2 0x08fc — read off both contracts' bytecode, not assumed). Two
        // SSTOREs cost 9,133 gas warm, so accounting for those returns here does not merely
        // mis-record them as fresh tax: it exhausts the stipend and reverts the whole
        // position operation with empty returndata. Return before touching storage.
        if (msg.sender == WBNB || msg.sender == vBNB) return;
        totalReceived += msg.value;
        pendingRevenue += msg.value;
        emit Received(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------- views

    function _oracle() internal view returns (IVenusOracle) {
        return IVenusOracle(IComptroller(COMPTROLLER).oracle());
    }

    function _cf() internal view returns (uint256 cf) {
        (, cf,) = IComptroller(COMPTROLLER).markets(vBNB);
    }

    /// @dev One oracle round trip costs ~26,300 gas on Venus's ResilientOracle, and the
    ///      collateral-factor lookup another ~17,900. Reading them once and threading the
    ///      values through the build took the callback from 1,420,949 to well under it.
    struct Px {
        uint256 bnb;
        uint256 usdt;
        uint256 cf;
    }

    function _px() internal view returns (Px memory p) {
        IComptroller c = comptroller_();
        IVenusOracle o = IVenusOracle(c.oracle());
        p.bnb = o.getUnderlyingPrice(vBNB);
        p.usdt = o.getUnderlyingPrice(vUSDT);
        (, p.cf,) = c.markets(vBNB);
    }

    function comptroller_() internal pure returns (IComptroller) {
        return IComptroller(COMPTROLLER);
    }

    /// @notice The two legs of the position, valued in USD (1e18).
    function positionUsd() public view returns (uint256 supplyUsd, uint256 borrowUsd) {
        return _positionUsd(_px());
    }

    function _positionUsd(Px memory p) internal view returns (uint256 supplyUsd, uint256 borrowUsd) {
        uint256 bnb = IVToken(vBNB).balanceOf(address(this)) * IVToken(vBNB).exchangeRateStored() / WAD;
        supplyUsd = bnb * p.bnb / WAD;
        borrowUsd = IVToken(vUSDT).borrowBalanceStored(address(this)) * p.usdt / WAD;
    }

    /// @notice Treasury value in BNB. A view over Venus — nothing is published, so nothing
    ///         can go stale and nobody can stop publishing it.
    function nav() public view returns (uint256) {
        return _nav(_px());
    }

    function _nav(Px memory p) internal view returns (uint256) {
        (uint256 s, uint256 b) = _positionUsd(p);
        uint256 idle = address(this).balance;
        if (s <= b) return idle;
        return (s - b) * WAD / p.bnb + idle;
    }

    /// @notice BNB exposure over net value, 1e18-scaled.
    function currentLeverage() public view returns (uint256) {
        (uint256 s, uint256 b) = positionUsd();
        if (s <= b) return 0;
        return s * WAD / (s - b);
    }

    function _leverage(Px memory p) internal view returns (uint256) {
        (uint256 s, uint256 b) = _positionUsd(p);
        if (s <= b) return 0;
        return s * WAD / (s - b);
    }

    /// @notice supply x CF / debt, in bps. Venus liquidates at 10000.
    function healthBps() public view returns (uint256) {
        return _health(_px());
    }

    /// @notice Venus's own verdict: true when it already considers this account liquidatable.
    /// @dev    `_health` derives a ratio from `collateralFactorMantissa`, which is what the
    ///         vault targets. But `markets()` returns seven words and we read three, and Venus
    ///         can set the parameter its liquidation engine uses independently of the one we
    ///         read. Rather than guess which of the other words that is, ask Venus directly:
    ///         a non-zero shortfall is computed with whatever it actually uses.
    ///
    ///         This is a floor under the ratio, not a replacement for it. The ratio still
    ///         drives targeting; this catches the case where the two have diverged and our
    ///         copy of the parameter says the position is safe when Venus does not.
    function _venusShortfall() internal view returns (bool) {
        (uint256 err,, uint256 shortfall) = IComptroller(COMPTROLLER).getAccountLiquidity(address(this));
        return err == 0 && shortfall > 0;
    }

    function _health(Px memory p) internal view returns (uint256) {
        (uint256 s, uint256 b) = _positionUsd(p);
        if (b == 0) return type(uint256).max;
        return s * p.cf / WAD * BPS / b;
    }

    /// @notice Gain over the cost of everything deployed so far, in BNB.
    function unrealisedGain() public view returns (uint256) {
        return _gain(_px());
    }

    function _gain(Px memory p) internal view returns (uint256) {
        uint256 n = _nav(p);
        uint256 basis = costBasis + pendingRevenue;
        return n > basis ? n - basis : 0;
    }

    function needsRebalance() public view returns (bool) {
        uint256 lev = currentLeverage();
        if (lev == 0) return false;
        uint256 lo = TARGET_LEVERAGE * (BPS - REBALANCE_BAND_BPS) / BPS;
        uint256 hi = TARGET_LEVERAGE * (BPS + REBALANCE_BAND_BPS) / BPS;
        return lev < lo || lev > hi;
    }

    /// @notice Seconds that must pass between rebalances. Zero when the position is close
    ///         enough to liquidation that waiting is the larger risk.
    function rebalanceCooldown() public pure returns (uint256) {
        return 1 hours;
    }

    function _cooldown(Px memory p) internal view returns (uint256) {
        return _health(p) < URGENT_HEALTH_BPS ? 0 : 1 hours;
    }

    // ------------------------------------------------------------ the three jobs

    /// @notice Turn accumulated tax into position. Permissionless and paid, because with
    ///         no keeper there has to be a reason for anyone to show up.
    function deployPending() external nonReentrant returns (uint256 bounty) {
        return _deploy(msg.sender);
    }

    /// @dev `bountyTo == address(0)` is the automatic path: the trigger fee has already
    ///      been paid out of the treasury, so no second fee is charged on top of it.
    function _deploy(address bountyTo) internal returns (uint256 bounty) {
        uint256 amount = pendingRevenue;
        require(amount >= MIN_DEPLOY, unicode"LeverVault: nothing to deploy yet / 暂无可部署的税收");

        bounty = bountyTo == address(0) ? 0 : amount * DEPLOY_BOUNTY_BPS / BPS;
        uint256 work = amount - bounty;
        pendingRevenue = 0;
        totalDeployed += work;
        costBasis += work;

        _accrue();
        Px memory p = _px();
        _build(work, p);
        require(
            _health(p) >= MIN_HEALTH_BPS,
            unicode"LeverVault: build breached the health floor / 建仓跌破健康度下限"
        );

        if (bounty > 0) {
            (bool ok,) = bountyTo.call{value: bounty}("");
            require(ok, unicode"LeverVault: bounty transfer failed / 赏金转账失败");
        }
        emit Deployed(bountyTo, work, bounty, _leverage(p));
    }

    /// @notice Send the position's gain to every holder through the token's own dividend
    ///         contract. Permissionless and paid.
    function harvest() external nonReentrant returns (uint256 bounty) {
        return _harvest(msg.sender);
    }

    function _harvest(address bountyTo) internal returns (uint256 bounty) {
        _accrue();
        Px memory p = _px();
        uint256 gain = _gain(p);
        require(gain >= MIN_HARVEST, unicode"LeverVault: no gain to harvest yet / 暂无可分配的收益");

        address div = IFlapTaxToken(token).dividendContract();
        require(
            IDividend(div).dividendToken() == WBNB,
            unicode"LeverVault: dividend token is not WBNB / 分红代币不是 WBNB"
        );

        uint256 before = address(this).balance;
        _shrinkBy(gain, p);
        uint256 freed = address(this).balance - before;
        require(freed > 0, unicode"LeverVault: unwind freed nothing / 减仓没有释放出资金");

        bounty = bountyTo == address(0) ? 0 : freed * HARVEST_BOUNTY_BPS / BPS;
        uint256 net = freed - bounty;
        uint256 toProject = net * PROJECT_SHARE_BPS / BPS;
        uint256 toHolders = net - toProject;

        // costBasis is deliberately untouched: _shrinkBy took only the gain, so what is
        // left in the position is still exactly what was paid for it.
        totalHarvested += toHolders;
        totalToProject += toProject;

        // Flap's dividend contract takes no tokens when it has no eligible holders, and its
        // `deposit` is declared without a return value here, so there is nothing to check.
        // Check the balance instead: WBNB is an ERC20 and `_nav` counts only native balance
        // plus the Venus position, so any WBNB left sitting here is outside NAV, invisible to
        // `_gain`, and unreachable -- while `totalHarvested` above has already counted it as
        // paid. Reverting keeps the gain in the position for the next attempt, which is
        // strictly better than stranding it.
        uint256 wbnbHeld = IERC20Min(WBNB).balanceOf(address(this));
        IWNative(WBNB).deposit{value: toHolders}();
        IERC20Min(WBNB).approve(div, toHolders);
        IDividend(div).deposit(toHolders);
        require(
            IERC20Min(WBNB).balanceOf(address(this)) <= wbnbHeld,
            unicode"LeverVault: dividend did not take the WBNB / 分红合约未收取 WBNB"
        );

        if (toProject > 0) {
            (bool sent,) = project.call{value: toProject}("");
            require(sent, unicode"LeverVault: project transfer failed / 项目方转账失败");
        }

        require(
            _health(p) >= MIN_HEALTH_BPS,
            unicode"LeverVault: harvest breached the health floor / 分配收益跌破健康度下限"
        );

        if (bounty > 0) {
            (bool ok,) = bountyTo.call{value: bounty}("");
            require(ok, unicode"LeverVault: bounty transfer failed / 赏金转账失败");
        }
        emit Harvested(bountyTo, toHolders, toProject, bounty);
    }

    /// @notice Push leverage back inside the band. Permissionless and paid.
    function rebalance() external nonReentrant returns (uint256 bounty) {
        return _rebalance(msg.sender);
    }

    function _rebalance(address bountyTo) internal returns (uint256 bounty) {
        _accrue();
        require(needsRebalance(), unicode"LeverVault: leverage is inside the band / 杠杆仍在区间内");
        Px memory p = _px();
        uint256 cd = _cooldown(p);
        require(
            block.timestamp >= lastRebalanceAt + cd,
            unicode"LeverVault: rebalance cooldown / 再平衡冷却中"
        );
        lastRebalanceAt = block.timestamp;

        uint256 before = _leverage(p);
        uint256 healthBefore = _health(p);
        uint256 bnbBefore = address(this).balance;
        bool deleveraging = before > TARGET_LEVERAGE;
        if (deleveraging) {
            (uint256 s, uint256 b) = _positionUsd(p);
            uint256 excess = s - (s - b) * TARGET_LEVERAGE / WAD;
            _deleverBy(excess * WAD / p.usdt, p);
            // The deleverage frees nothing by design, so the caller has to be paid out of a
            // proportional shrink -- which is what `_shrinkBy` is for, and which leaves the
            // leverage the step above just set exactly where it is.
            if (bountyTo != address(0)) {
                Px memory q = _px();
                _shrinkBy(excess * REBALANCE_BOUNTY_BPS / BPS * WAD / q.bnb, q);
            }
        } else {
            _build(0, p);
        }
        uint256 freed = address(this).balance - bnbBefore;
        bounty = bountyTo == address(0) ? 0 : freed * REBALANCE_BOUNTY_BPS / BPS;
        if (bounty > 0) {
            (bool ok,) = bountyTo.call{value: bounty}("");
            require(ok, unicode"LeverVault: bounty transfer failed / 赏金转账失败");
        }
        uint256 rest = address(this).balance - bnbBefore;
        if (rest > 0) {
            // Deleveraging hands back capital that is already inside costBasis, unlike
            // `harvest`, whose freed BNB leaves the vault entirely and so leaves the basis
            // alone. Booking it as pending revenue without taking it out of the basis counts
            // the same BNB twice the moment `_deploy` puts it back and runs `costBasis +=
            // work` on capital that never left. Since `_nav` already counts idle balance,
            // `_gain = nav - (costBasis + pendingRevenue)` would then sit permanently lower
            // by the freed amount, and `harvest` would stop paying holders until NAV had
            // grown past a basis that no longer describes what was paid. Move it between the
            // two rather than adding to one. What genuinely left -- the bounty -- is not
            // moved here, so it shows up as the loss it is.
            if (deleveraging) {
                costBasis = costBasis > rest ? costBasis - rest : 0;
            }
            pendingRevenue += rest;
        }
        // Improvement, not an absolute floor. TARGET_LEVERAGE, MIN_HEALTH_BPS and Venus's 80%
        // collateral factor are exactly coincident: health at 3x is 0.8 * 3/2 = 1.2000, the
        // floor itself. So a deleverage that lands on its own target sits precisely on the line
        // and any swap friction puts it a hair under -- the check would revert the very move it
        // exists to encourage. Worse, a deep rescue from 1.05 that reaches 1.15 is a large
        // improvement and would also have been reverted. Demand that health rose, and keep the
        // absolute floor as the other way to pass.
        uint256 healthAfter = _health(_px());
        require(
            healthAfter >= MIN_HEALTH_BPS || healthAfter > healthBefore,
            unicode"LeverVault: rebalance did not improve health / 再平衡没有改善健康度"
        );
        emit Rebalanced(bountyTo, before, _leverage(p), bounty);
    }

    // ------------------------------------------------------- automatic settlement

    /// @notice Called by Flap's trigger service on a schedule. Holders press nothing.
    /// @dev Rule 008 in three parts:
    ///      - sender is checked against the one official service address;
    ///      - the request id must be the exact one this vault is waiting on, and it is
    ///        consumed before any work runs, so a replay finds nothing to replay;
    ///      - nothing here assumes the callback arrived on time. Every job re-reads the
    ///        chain and decides again.
    function trigger(uint256 requestId) external override {
        require(
            msg.sender == TRIGGER_SERVICE,
            unicode"LeverVault: caller is not the trigger service / 调用方不是定时服务"
        );
        require(
            requestId != 0 && requestId == pendingRequestId,
            unicode"LeverVault: unknown or spent trigger / 未知或已消费的定时请求"
        );
        pendingRequestId = 0;

        uint8 action = _pickAction();

        // Buy the next slot before doing the work. A build measures 1.20-1.24M gas against
        // the 2M cap; if it reverted after scheduling, the chain would still be alive to retry.
        _schedule(action == 0 ? IDLE_INTERVAL : TRIGGER_INTERVAL);

        if (action != 0 && gasleft() >= WORK_GAS_FLOOR) {
            try this.settleSelf(action) {
                emit Settled(requestId, action);
            } catch (bytes memory reason) {
                emit WorkFailed(requestId, reason);
            }
        }
    }

    /// @notice Anyone may restart settlement if the chain ever goes idle — after a failed
    ///         schedule, or after the treasury was briefly too empty to buy a slot.
    function kickstart() external nonReentrant {
        require(pendingRequestId == 0, unicode"LeverVault: already scheduled / 已排定下一次结算");
        _schedule(TRIGGER_INTERVAL);
        require(pendingRequestId != 0, unicode"LeverVault: could not schedule / 无法排定结算");
    }

    /// @notice Seconds until the next settlement, or zero when the chain is idle.
    function nextSettlementIn() external view returns (uint256) {
        if (pendingRequestId == 0) return 0;
        IFlapTriggerService.TriggerRequest memory r =
            IFlapTriggerService(TRIGGER_SERVICE).getRequest(pendingRequestId);
        return r.executeAfter > block.timestamp ? r.executeAfter - block.timestamp : 0;
    }

    /// @notice What the next settlement will do. 0 nothing, 1 rescue, 2 build, 3 harvest,
    ///         4 rebalance.
    function pendingAction() external view returns (uint8) {
        return _pickAction();
    }

    function _pickAction() internal view returns (uint8) {
        // Cheapest checks first: pendingRevenue is a single SLOAD, and it is what a wake
        // finds most of the time. Only reach for the oracle when it has to.
        Px memory p = _px();

        // Venus is asked whether it can serve the action before it is chosen. Without this the
        // selector re-picks the same blocked action on every wake -- a rescue that cannot
        // redeem stays selected, reverts, and never lets a lower-priority action that would
        // succeed run at all. getCash is one storage read on the market.
        uint256 bnbCash = IVToken(vBNB).getCash();
        uint256 usdtCash = IVToken(vUSDT).getCash();

        // A rescue and a harvest both redeem BNB; a deploy borrows USDT.
        // Venus's own verdict outranks our ratio: if it says this account is already
        // liquidatable, nothing else is worth doing with the wake.
        //
        // needsRebalance() is the third condition, and it is the one that matters when the
        // position is underwater. A rescue runs _rebalance, which requires it. If supply has
        // fallen to or below debt, _leverage returns 0, needsRebalance returns false, and the
        // rescue reverts every single time -- while health is necessarily below the urgent line,
        // so the selector picks it again on the next wake and never reaches the deploy that
        // could actually recover the position. Requiring it here lets an action that cannot
        // succeed step aside for one that can.
        //
        // It costs nothing in the ordinary case: health below 11,300 means leverage above
        // 3.42x, which is already outside the 3x +/- 5% band, so needsRebalance is true there
        // anyway. The only state this changes is the insolvent one.
        if ((_health(p) < URGENT_HEALTH_BPS || _venusShortfall())
            && needsRebalance() && bnbCash >= MIN_DEPLOY) return 1;
        if (pendingRevenue >= MIN_DEPLOY && usdtCash > 0) return 2;
        if (_gain(p) >= MIN_HARVEST && bnbCash >= MIN_DEPLOY) return 3;
        uint256 lev = _leverage(p);
        if (lev != 0) {
            uint256 lo = TARGET_LEVERAGE * (BPS - REBALANCE_BAND_BPS) / BPS;
            uint256 hi = TARGET_LEVERAGE * (BPS + REBALANCE_BAND_BPS) / BPS;
            // Levering down redeems BNB; levering up borrows USDT.
            bool servable = lev > hi ? bnbCash >= MIN_DEPLOY : usdtCash > 0;
            if ((lev < lo || lev > hi) && servable) return 4;
        }
        return 0;
    }

    /// @dev External only so `trigger()` can wrap it in a try. Self-calls only.
    function settleSelf(uint8 action) external {
        require(msg.sender == address(this), unicode"LeverVault: self only / 仅限自调用");
        if (action == 2) {
            _deploy(address(0));
        } else if (action == 3) {
            _harvest(address(0));
        } else {
            _rebalance(address(0));
        }
    }

    function _schedule(uint64 delay) internal {
        uint256 fee = IFlapTriggerService(TRIGGER_SERVICE).getFee();
        if (address(this).balance < fee) return;
        uint256 id =
            IFlapTriggerService(TRIGGER_SERVICE).requestTrigger{value: fee}(uint64(block.timestamp) + delay);
        // The slot is bought out of undeployed revenue. Without this the balance drops and
        // pendingRevenue does not, so the next build tries to deploy more BNB than the
        // vault holds and reverts with empty returndata. The manual path hid it: its 0.25%
        // bounty happened to leave exactly enough room.
        pendingRevenue = pendingRevenue > fee ? pendingRevenue - fee : 0;
        pendingRequestId = id;
        emit Scheduled(id, uint64(block.timestamp) + delay);
    }

    // -------------------------------------------------------------- position work

    function _accrue() internal {
        IVToken(vBNB).accrueInterest();
        IVToken(vUSDT).accrueInterest();
    }

    /// @dev Supply `extra` BNB and lever to target in one flash-funded pass. Venus checks
    ///      collateral at the instant of the borrow, before the proceeds become collateral,
    ///      so a loop can only take the sliver current collateral supports and converges at
    ///      cf/health. Flash supplies first and borrows second.
    function _build(uint256 extra, Px memory p) internal {
        if (extra > 0) IVBNB(vBNB).mint{value: extra}();

        uint256 navBnb = _nav(p) - address(this).balance;
        if (navBnb == 0) return;
        uint256 navUsd = navBnb * p.bnb / WAD;

        uint256 targetDebt = navUsd * (TARGET_LEVERAGE - WAD) / WAD;
        uint256 cfBps = p.cf / 1e14;
        // The health floor binds before the leverage target does, and at cf 0.80 / health
        // 1.20 a 3x long sits exactly on it. Take 1% off so the build clears it.
        // At cf 0.80 / health 1.20 a 3x long sits exactly ON the floor, and the build adds
        // two costs the model does not: the flash fee and the quote buffer, together ~0.55%.
        // 99% leaves health at 1.198 and trips the check; 97% lands at 1.205.
        uint256 debtCap = navUsd * cfBps / (MIN_HEALTH_BPS - cfBps) * 97 / 100;
        if (targetDebt > debtCap) targetDebt = debtCap;

        (, uint256 curDebt) = _positionUsd(p);
        if (targetDebt <= curDebt) return;
        uint256 wbnbToFlash = (targetDebt - curDebt) * WAD / p.bnb;
        if (wbnbToFlash < MIN_DEPLOY) return;

        // WBNB is token1 in the WBNB/USDT pool (0x55d3.. < 0xbb4C..).
        // Prices ride along in the callback data: reading them again inside the callback
        // is two more ResilientOracle round trips at ~26,300 gas each.
        IV3Pool(FLASH_POOL).flash(address(this), 0, wbnbToFlash, abi.encode(wbnbToFlash, p.bnb, p.usdt));
    }

    /// @notice PancakeSwap V3 flash callback. Only the one pool may call it.
    function pancakeV3FlashCallback(uint256, uint256 fee1, bytes calldata data) external {
        require(
            msg.sender == FLASH_POOL,
            unicode"LeverVault: caller is not the flash pool / 调用方不是闪电贷池"
        );
        (uint256 borrowed, uint256 pxBnb, uint256 pxUsdt) = abi.decode(data, (uint256, uint256, uint256));
        uint256 owed = borrowed + fee1;

        IWNative(WBNB).withdraw(borrowed);
        IVBNB(vBNB).mint{value: borrowed}();

        uint256 usdtNeeded = owed * pxBnb / pxUsdt * 1003 / 1000;
        require(
            IVToken(vUSDT).borrow(usdtNeeded) == 0,
            unicode"LeverVault: Venus borrow failed / Venus 借款失败"
        );
        // No floor here, and none is needed: the require below is strictly tighter. The swap
        // must return enough to repay the flash loan or the entire build reverts, which is a
        // bound on the same quantity an oracle floor would bound, enforced by the pool itself.
        uint256 got = _swap(USDT, WBNB, usdtNeeded, 0);
        require(got >= owed, unicode"LeverVault: flash repayment short / 闪电贷还款不足");
        IERC20Min(WBNB).transfer(FLASH_POOL, owed);
        if (got > owed) {
            IWNative(WBNB).withdraw(got - owed);
        }
    }

    /// @dev Free `wantBnb` of BNB by shrinking both legs proportionally.
    /// @notice Redeem collateral and spend all of it on debt until leverage reaches the target.
    ///
    /// @dev Deliberately NOT `_shrinkBy`. That shrinks both legs by the same *fraction*, and a
    ///      proportional shrink leaves leverage exactly where it was:
    ///      `s(1-f) / (s(1-f) - b(1-f)) == s / (s - b)`. Deleveraging needs the legs to move by
    ///      the same *absolute* amount, because `(s-x) / ((s-x) - (b-x)) = (s-x) / (s-b)` is the
    ///      expression that actually falls. Solving it for the target gives
    ///      `x = s - (s-b) * TARGET`, which is the `excess` the caller passes in.
    ///
    ///      Handing that `excess` to `_shrinkBy` instead -- as this did -- overstated the
    ///      fraction by the leverage factor, because `excess` was divided by equity rather than
    ///      by supply. Where leverage ended up was then decided by how much of the tail redeem
    ///      the health cap happened to block: everything blocked landed 2.83x, nothing blocked
    ///      landed back at 3.15x, and the 3.00x target was not reachable either way.
    ///
    /// @param repayUsdt Debt to retire, in vUSDT underlying units.
    function _deleverBy(uint256 repayUsdt, Px memory p) internal {
        uint256 debt0 = IVToken(vUSDT).borrowBalanceStored(address(this));
        if (repayUsdt == 0 || debt0 == 0) return;
        uint256 debtTarget = debt0 > repayUsdt ? debt0 - repayUsdt : 0;
        // Every redeemed BNB is spent on debt, so nothing is freed here and leverage is the only
        // thing that moves. A partial pass is progress; the next wake continues from it.
        for (uint8 i = 0; i < 8; i++) {
            uint256 debt = IVToken(vUSDT).borrowBalanceStored(address(this));
            if (debt <= debtTarget) break;
            if (!_repayOnce(debt - debtTarget, p)) break;
        }
    }

    function _shrinkBy(uint256 wantBnb, Px memory p) internal {
        uint256 navBnb = _nav(p) - address(this).balance;
        if (navBnb == 0 || wantBnb == 0) return;
        uint256 fraction = wantBnb >= navBnb ? WAD : wantBnb * WAD / navBnb;

        uint256 debt0 = IVToken(vUSDT).borrowBalanceStored(address(this));
        uint256 debtTarget = debt0 - debt0 * fraction / WAD;
        // Both targets are taken from the ORIGINAL legs. Recomputing the supply target
        // after the repayment loop double-counts what the loop already redeemed, and a
        // 0.99 BNB harvest frees 1.89.
        uint256 supply0 = IVToken(vBNB).balanceOf(address(this)) * IVToken(vBNB).exchangeRateStored() / WAD;
        uint256 supplyTarget = supply0 - supply0 * fraction / WAD;

        for (uint8 i = 0; i < 8; i++) {
            uint256 debt = IVToken(vUSDT).borrowBalanceStored(address(this));
            if (debt <= debtTarget) break;
            if (!_repayOnce(debt - debtTarget, p)) break;
        }

        uint256 supplyNow = IVToken(vBNB).balanceOf(address(this)) * IVToken(vBNB).exchangeRateStored() / WAD;
        if (supplyNow > supplyTarget) {
            uint256 rest = supplyNow - supplyTarget;
            // A plain redeem lowers health with nothing to offset it, so this one keeps the
            // strict floor -- an early harvest freed 3.88 BNB against a 0.99 gain here.
            uint256 cap = _maxRedeemableBnb(p, MIN_HEALTH_BPS);
            if (rest > cap) rest = cap;
            if (rest >= MIN_DEPLOY) {
                require(
                    IVToken(vBNB).redeemUnderlying(rest) == 0,
                    unicode"LeverVault: Venus redeem failed / Venus 赎回失败"
                );
            }
        }
        uint256 leftover = IERC20Min(WBNB).balanceOf(address(this));
        if (leftover > 0) IWNative(WBNB).withdraw(leftover);
    }

    /// @dev Collateral that can be pulled without dropping under the health floor.
    ///      Sizing this against Venus's own limit instead is what let an early harvest
    ///      free 3.88 BNB against a 0.99 BNB gain and leave health at 1.003 — the loop
    ///      had not repaid enough debt, and the tail redeemed its share regardless.
    ///      Solving (s - x) * cf >= h * b for x gives the only safe pull.
    function _maxRedeemableBnb(Px memory p, uint256 floorBps) internal view returns (uint256) {
        (uint256 s, uint256 b) = _positionUsd(p);
        if (b == 0) return s * WAD / p.bnb;
        uint256 cfBps = p.cf / 1e14;
        uint256 floorSupply = floorBps * b / cfBps;
        if (s <= floorSupply) return 0;
        return (s - floorSupply) * WAD * 99 / (p.bnb * 100);
    }

    /// @param minOut The oracle-derived floor. Zero is only correct where the caller enforces
    ///               its own bound afterwards, as the flash callback does.
    function _swap(address from, address to, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256)
    {
        if (amountIn == 0) return 0;
        return IV3Router(V3_ROUTER)
            .exactInputSingle(
                IV3Router.ExactInputSingleParams({
                    tokenIn: from,
                    tokenOut: to,
                    fee: SWAP_FEE,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: minOut,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    /// @dev One deleveraging pass: redeem what the repayment needs, sell it, repay, and put any
    ///      remainder back. Split out of `_shrinkBy` because that loop already held seven locals
    ///      and adding the oracle floor to the swaps pushed it past the stack limit.
    /// @return true if it moved, false if there was nothing worth redeeming.
    function _repayOnce(uint256 needUsdt, Px memory p) internal returns (bool) {
        // Redeem what the repayment needs, not everything the floor allows. Pulling the maximum
        // each pass left the surplus sitting as WBNB, which the tail then unwrapped and counted
        // as freed — a 0.99 BNB harvest paid out 1.89.
        uint256 cap = _maxRedeemableBnb(p, REPAY_FLOOR_BPS);
        uint256 pull = needUsdt * p.usdt / p.bnb * 101 / 100;
        if (pull > cap) pull = cap;
        // Take what Venus can actually hand over. Redeeming more than the market holds reverts
        // the whole call, which in a rescue is the worst possible outcome: the position stays
        // exactly as leveraged as it was. A partial pass makes partial progress, and the next
        // wake continues from there.
        uint256 cash = IVToken(vBNB).getCash();
        if (pull > cash) pull = cash;
        if (pull < MIN_DEPLOY) return false;
        require(
            IVToken(vBNB).redeemUnderlying(pull) == 0,
            unicode"LeverVault: Venus redeem failed / Venus 赎回失败"
        );
        IWNative(WBNB).deposit{value: pull}();
        uint256 usdt = _sellBnb(pull, p);
        uint256 pay = usdt < needUsdt ? usdt : needUsdt;
        require(
            IVToken(vUSDT).repayBorrow(pay) == 0,
            unicode"LeverVault: Venus repay failed / Venus 还款失败"
        );
        if (usdt > pay) _buyBnb(usdt - pay, p);
        return true;
    }

    /// @dev BNB out of the position: sell WBNB for USDT, floored at the oracle.
    function _sellBnb(uint256 amountIn, Px memory p) internal returns (uint256) {
        return _swap(WBNB, USDT, amountIn, _floor(amountIn, p.bnb, p.usdt));
    }

    /// @dev The remainder after a repayment goes back to WBNB, floored the same way.
    function _buyBnb(uint256 amountIn, Px memory p) internal returns (uint256) {
        return _swap(USDT, WBNB, amountIn, _floor(amountIn, p.usdt, p.bnb));
    }

    /// @dev Value `amountIn` of `from` in units of `to` at the oracle, less the tolerance.
    ///      Both prices are USD-per-token scaled to 1e18, so the units cancel.
    function _floor(uint256 amountIn, uint256 pxIn, uint256 pxOut) internal pure returns (uint256) {
        if (amountIn == 0 || pxOut == 0) return 0;
        return amountIn * pxIn / pxOut * (BPS - MAX_SWAP_SLIP_BPS) / BPS;
    }

    // --------------------------------------------------------------- flap surface

    function description() public pure override returns (string memory) {
        return unicode"Trading tax becomes a leveraged BNB position the vault holds on Venus itself. "
            unicode"The treasury moves with the market when nobody is trading, and its gain is paid to "
            unicode"holders through the token's dividend contract. No keeper, no published NAV, no pause."
            unicode" / 交易税会变成金库自己持有在 Venus 上的杠杆 BNB 仓位。无人交易时国库仍随市场波动,"
            unicode"其收益通过代币的分红合约发给持有者。没有 keeper,不发布 NAV,没有暂停开关。";
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "LeverVault";
        schema.description = description();

        VaultMethodSchema[] memory m = new VaultMethodSchema[](6);

        m[0].name = "nav";
        m[0].description = unicode"Treasury value in BNB, read straight from Venus. / 国库价值(以 BNB 计),直接读自 Venus。";
        m[0].outputs = _one("bnb", "uint256", unicode"Treasury value in wei / 国库价值,单位 wei");
        m[0].isWriteMethod = false;

        m[1].name = "currentLeverage";
        m[1].description = unicode"Live BNB exposure over net value, 1e18-scaled. / 实时 BNB 敞口除以净值,按 1e18 缩放。";
        m[1].outputs = _one("leverage", "uint256", unicode"3e18 means 3x / 3e18 表示 3 倍");
        m[1].isWriteMethod = false;

        m[2].name = "healthBps";
        m[2].description = unicode"Collateral x factor over debt, in bps. Venus liquidates at 10000. / 抵押乘以抵押率再除以负债,单位 bps。Venus 在 10000 清算。";
        m[2].outputs = _one("health", "uint256", unicode"12000 means liquidated only by a 16.7% move / 12000 表示需下跌 16.7% 才会被清算");
        m[2].isWriteMethod = false;

        m[3].name = "deployPending";
        m[3].description = unicode"Turn accumulated tax into position. Anyone may call; pays 0.25%. / 把累积的税收建成仓位。任何人都可调用,支付 0.25% 赏金。";
        m[3].outputs = _one("bounty", "uint256", unicode"BNB paid to the caller / 支付给调用者的 BNB");
        m[3].isWriteMethod = true;

        m[4].name = "harvest";
        m[4].description = unicode"Distribute the position's gain: 70% to holders as WBNB dividends, "
            unicode"30% to the project. Anyone may call; pays 0.5% to the caller."
            unicode" / 分配仓位收益:70% 以 WBNB 分红发给持有者,30% 给项目方。任何人都可调用,支付 0.5% 赏金。";
        m[4].outputs = _one("bounty", "uint256", unicode"BNB paid to the caller / 支付给调用者的 BNB");
        m[4].isWriteMethod = true;

        m[5].name = "rebalance";
        m[5].description = unicode"Push leverage back inside the band. Anyone may call; pays 0.3% of what it frees. / 把杠杆推回区间内。任何人都可调用,支付所释放资金的 0.3% 作为赏金。";
        m[5].outputs = _one("bounty", "uint256", unicode"BNB paid to the caller / 支付给调用者的 BNB");
        m[5].isWriteMethod = true;

        schema.methods = m;
    }

    function _one(string memory name_, string memory type_, string memory desc)
        internal
        pure
        returns (FieldDescriptor[] memory f)
    {
        f = new FieldDescriptor[](1);
        f[0].name = name_;
        f[0].fieldType = type_;
        f[0].description = desc;
        f[0].decimals = 18;
    }
}
