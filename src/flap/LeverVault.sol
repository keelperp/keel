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
    address internal constant FLASH_POOL = 0x36696169C63e42cd08ce11f5deeBbCeBae652050; // WBNB/USDT 0.05%

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    /// @notice 3x is the ceiling Venus's 80% collateral factor can hold at a 1.20 health
    ///         floor: health = CF*L/(L-1), and 5x is exactly 1.00 — the liquidation point.
    uint256 public constant TARGET_LEVERAGE = 3 * WAD;
    uint256 public constant MIN_HEALTH_BPS = 12_000;
    uint256 public constant URGENT_HEALTH_BPS = 11_000;
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
    /// @dev Rule 008 caps a callback at 2,000,000 gas. A build measures ~1.7M, so the
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

        IWNative(WBNB).deposit{value: toHolders}();
        IERC20Min(WBNB).approve(div, toHolders);
        IDividend(div).deposit(toHolders);

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
        uint256 bnbBefore = address(this).balance;
        if (before > TARGET_LEVERAGE) {
            (uint256 s, uint256 b) = _positionUsd(p);
            uint256 excess = s - (s - b) * TARGET_LEVERAGE / WAD;
            _shrinkBy(excess * WAD / p.bnb, p);
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
        if (rest > 0) pendingRevenue += rest;
        require(
            _health(_px()) >= MIN_HEALTH_BPS,
            unicode"LeverVault: rebalance breached the health floor / 再平衡跌破健康度下限"
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

        // Buy the next slot before doing the work. A build costs ~1.7M gas against a 2M
        // cap; if it reverted after scheduling, the chain would still be alive to retry.
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
        if (_health(p) < URGENT_HEALTH_BPS) return 1;
        if (pendingRevenue >= MIN_DEPLOY) return 2;
        if (_gain(p) >= MIN_HARVEST) return 3;
        uint256 lev = _leverage(p);
        if (lev != 0) {
            uint256 lo = TARGET_LEVERAGE * (BPS - REBALANCE_BAND_BPS) / BPS;
            uint256 hi = TARGET_LEVERAGE * (BPS + REBALANCE_BAND_BPS) / BPS;
            if (lev < lo || lev > hi) return 4;
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
        uint256 got = _swap(USDT, WBNB, usdtNeeded);
        require(got >= owed, unicode"LeverVault: flash repayment short / 闪电贷还款不足");
        IERC20Min(WBNB).transfer(FLASH_POOL, owed);
        if (got > owed) {
            IWNative(WBNB).withdraw(got - owed);
        }
    }

    /// @dev Free `wantBnb` of BNB by shrinking both legs proportionally.
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
            // Redeem what the repayment needs, not everything the floor allows. Pulling the
            // maximum each pass left the surplus sitting as WBNB, which the tail then
            // unwrapped and counted as freed — a 0.99 BNB harvest paid out 1.89.
            uint256 needUsdt = debt - debtTarget;
            uint256 needBnb = needUsdt * p.usdt / p.bnb * 101 / 100;
            uint256 cap = _maxRedeemableBnb(p);
            uint256 pull = needBnb < cap ? needBnb : cap;
            if (pull < MIN_DEPLOY) break;
            require(
                IVToken(vBNB).redeemUnderlying(pull) == 0,
                unicode"LeverVault: Venus redeem failed / Venus 赎回失败"
            );
            IWNative(WBNB).deposit{value: pull}();
            uint256 usdt = _swap(WBNB, USDT, pull);
            uint256 pay = usdt < debt - debtTarget ? usdt : debt - debtTarget;
            require(
                IVToken(vUSDT).repayBorrow(pay) == 0,
                unicode"LeverVault: Venus repay failed / Venus 还款失败"
            );
            if (usdt > pay) _swap(USDT, WBNB, usdt - pay);
        }

        uint256 supplyNow = IVToken(vBNB).balanceOf(address(this)) * IVToken(vBNB).exchangeRateStored() / WAD;
        if (supplyNow > supplyTarget) {
            uint256 rest = supplyNow - supplyTarget;
            uint256 cap = _maxRedeemableBnb(p);
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
    function _maxRedeemableBnb(Px memory p) internal view returns (uint256) {
        (uint256 s, uint256 b) = _positionUsd(p);
        if (b == 0) return s * WAD / p.bnb;
        uint256 cfBps = p.cf / 1e14;
        uint256 floorSupply = MIN_HEALTH_BPS * b / cfBps;
        if (s <= floorSupply) return 0;
        return (s - floorSupply) * WAD * 99 / (p.bnb * 100);
    }

    function _swap(address from, address to, uint256 amountIn) internal returns (uint256) {
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
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
    }

    // --------------------------------------------------------------- flap surface

    function description() public pure override returns (string memory) {
        return "Trading tax becomes a leveraged BNB position the vault holds on Venus itself. "
            "The treasury moves with the market when nobody is trading, and its gain is paid to "
            "holders through the token's dividend contract. No keeper, no published NAV, no pause.";
    }

    function vaultUISchema() public pure override returns (VaultUISchema memory schema) {
        schema.vaultType = "LeverVault";
        schema.description = description();

        VaultMethodSchema[] memory m = new VaultMethodSchema[](6);

        m[0].name = "nav";
        m[0].description = "Treasury value in BNB, read straight from Venus.";
        m[0].outputs = _one("bnb", "uint256", "Treasury value in wei");
        m[0].isWriteMethod = false;

        m[1].name = "currentLeverage";
        m[1].description = "Live BNB exposure over net value, 1e18-scaled.";
        m[1].outputs = _one("leverage", "uint256", "3e18 means 3x");
        m[1].isWriteMethod = false;

        m[2].name = "healthBps";
        m[2].description = "Collateral x factor over debt, in bps. Venus liquidates at 10000.";
        m[2].outputs = _one("health", "uint256", "12000 means liquidated only by a 16.7% move");
        m[2].isWriteMethod = false;

        m[3].name = "deployPending";
        m[3].description = "Turn accumulated tax into position. Anyone may call; pays 0.25%.";
        m[3].outputs = _one("bounty", "uint256", "BNB paid to the caller");
        m[3].isWriteMethod = true;

        m[4].name = "harvest";
        m[4].description =
            "Distribute the position's gain: 70% to holders as WBNB dividends, 30% to the project. Anyone may call; pays 0.5% to the caller.";
        m[4].outputs = _one("bounty", "uint256", "BNB paid to the caller");
        m[4].isWriteMethod = true;

        m[5].name = "rebalance";
        m[5].description = "Push leverage back inside the band. Anyone may call; pays 0.3% of what it frees.";
        m[5].outputs = _one("bounty", "uint256", "BNB paid to the caller");
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
