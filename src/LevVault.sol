// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "./ERC20.sol";
import {
    IVToken,
    IComptroller,
    IVenusOracle,
    IPancakeRouter,
    IERC20Min,
    IVBNB,
    IWNative,
    IV3Router
} from "./interfaces/IVenus.sol";

/// @title LevVault — an on-chain leveraged position, held by the contract itself.
/// @notice One share is a pro-rata claim on a Venus position this contract owns outright.
///
///         There is no keeper, no operator account, no published equity and no pause.
///         `exchangeRate()` is a pure view over Venus state, so every holder can price
///         their own shares in the same block they trade them. Nothing here can be
///         switched off by whoever deployed it.
contract LevVault is ERC20 {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    /// @dev Venus computes vTokens as `amount * 1e18 / exchangeRate` and reverts with
    ///      "redeemTokens zero" when that rounds to nothing. Anything under this is dust
    ///      and is left in place rather than sent into a revert.
    uint256 internal constant DUST = 1e10;
    /// @dev Rebalancing is the one job a keeper used to do. With no keeper, it has to be
    ///      worth someone's gas — otherwise `rebalance()` is permissionless and never called,
    ///      and drift ends in a Venus liquidation. Paid in freshly minted shares, so it is
    ///      funded by dilution and can never fail for want of liquidity.
    uint256 internal constant BOUNTY_MIN_BPS = 5;
    uint256 internal constant BOUNTY_MAX_BPS = 30;
    uint256 internal constant REBALANCE_COOLDOWN = 1 hours;

    /// @dev Unit of account for deposits and redemptions (USDT).
    IERC20Min public immutable base;
    /// @dev The asset the position is exposed to (BTCB, WBNB, ...).
    IERC20Min public immutable collateral;

    IVToken public immutable vSupply;
    IVToken public immutable vBorrow;
    IVToken public immutable vBase;
    IComptroller public immutable comptroller;
    IPancakeRouter public immutable router;

    /// @dev 1e18-scaled, e.g. 3e18 for 3x.
    uint256 public immutable targetLeverage;
    bool public immutable isLong;
    uint256 public lastRebalanceAt;
    /// @dev Rebalance band in bps around targetLeverage; outside it `rebalance()` acts.
    uint256 public immutable bandBps;
    uint8 public immutable maxLoops;

    IERC20Min internal immutable supplyAsset;
    IERC20Min internal immutable borrowAsset;

    /// @dev Venus's BNB market is Compound's CEther: `mint()`/`repayBorrow()` are payable and
    ///      return nothing. Calling `mint(uint256)` on it hits a selector that does not exist
    ///      and reverts with empty returndata. These flags route around that.
    bool internal immutable supplyIsNative;
    bool internal immutable borrowIsNative;
    IWNative internal immutable wnative;
    address internal immutable swapHop;
    IV3Router internal immutable v3Router;
    uint24 internal immutable v3Fee;

    event Minted(address indexed to, uint256 baseIn, uint256 shares);
    event Redeemed(address indexed to, uint256 shares, uint256 baseOut);
    event Rebalanced(uint256 leverageBefore, uint256 leverageAfter, address indexed caller, uint256 bounty);

    /// @param base_ unit of account for deposits and redemptions (USDT)
    /// @param collateral_ the asset the position is exposed to (BTCB, WBNB, ...)
    /// @param targetLeverage_ 1e18-scaled, e.g. 3e18 for 3x
    /// @param isLong_ true = supply collateral & borrow base; false = the mirror
    struct Config {
        string name;
        string symbol;
        address base_;
        address collateral_;
        address vBase;
        address vCollateral;
        address comptroller;
        address router;
        uint256 targetLeverage_;
        bool isLong_;
        uint256 bandBps_;
        uint8 maxLoops_;
        bool collateralIsNative;
        /// @dev Intermediate hop for base<->collateral swaps, or address(0) for a direct pair.
        ///      PancakeSwap V2's USDT/BTCB pool is only ~$700k deep: an 18,000 USDT leg costs
        ///      5.90% direct but 2.19% routed through WBNB. Measured, not assumed.
        address swapHop;
        /// @dev PancakeSwap V3 router, or address(0) to stay on V2.
        address v3Router;
        /// @dev V3 pool fee tier for base<->collateral. 0 means use V2.
        ///      Measured: V2's USDT/BTCB pool is ~$700k and costs 12.25% on a 40,000 leg;
        ///      V3's 0.05% pool holds $16.2M and costs 0.43% on the same leg.
        uint24 v3Fee;
    }

    constructor(Config memory c) ERC20(c.name, c.symbol) {
        require(c.targetLeverage_ > WAD && c.targetLeverage_ <= 5 * WAD, "lev range");
        require(c.bandBps_ > 0 && c.bandBps_ <= 5000, "band range");
        require(c.maxLoops_ > 0 && c.maxLoops_ <= 20, "loops range");
        require(c.base_ != c.collateral_, "same asset");

        base = IERC20Min(c.base_);
        collateral = IERC20Min(c.collateral_);
        comptroller = IComptroller(c.comptroller);
        router = IPancakeRouter(c.router);
        targetLeverage = c.targetLeverage_;
        isLong = c.isLong_;
        bandBps = c.bandBps_;
        maxLoops = c.maxLoops_;
        vBase = IVToken(c.vBase);

        // Long  = supply collateral, borrow base.
        // Short = supply base,       borrow collateral.
        if (c.isLong_) {
            vSupply = IVToken(c.vCollateral);
            vBorrow = IVToken(c.vBase);
            supplyAsset = IERC20Min(c.collateral_);
            borrowAsset = IERC20Min(c.base_);
            supplyIsNative = c.collateralIsNative;
            borrowIsNative = false;
        } else {
            vSupply = IVToken(c.vBase);
            vBorrow = IVToken(c.vCollateral);
            supplyAsset = IERC20Min(c.base_);
            borrowAsset = IERC20Min(c.collateral_);
            supplyIsNative = false;
            borrowIsNative = c.collateralIsNative;
        }
        wnative = c.collateralIsNative ? IWNative(c.collateral_) : IWNative(address(0));
        require(c.swapHop != c.base_ && c.swapHop != c.collateral_, "hop collides");
        swapHop = c.swapHop;
        v3Router = IV3Router(c.v3Router);
        v3Fee = c.v3Fee;
        require(c.v3Fee == 0 || c.v3Router != address(0), "v3 router missing");
        if (c.v3Router != address(0)) {
            IERC20Min(c.base_).approve(c.v3Router, type(uint256).max);
            IERC20Min(c.collateral_).approve(c.v3Router, type(uint256).max);
        }

        address[] memory mk = new address[](1);
        mk[0] = address(vSupply);
        comptroller.enterMarkets(mk);

        IERC20Min(c.base_).approve(c.router, type(uint256).max);
        IERC20Min(c.collateral_).approve(c.router, type(uint256).max);
        if (!supplyIsNative) supplyAsset.approve(address(vSupply), type(uint256).max);
        if (!borrowIsNative) borrowAsset.approve(address(vBorrow), type(uint256).max);
    }

    // ---------------------------------------------------------------- views

    function _oracle() internal view returns (IVenusOracle) {
        return IVenusOracle(comptroller.oracle());
    }

    /// @notice Supply and borrow legs valued in USD (1e18).
    function positionUsd() public view returns (uint256 supplyUsd, uint256 borrowUsd) {
        IVenusOracle o = _oracle();
        uint256 sUnits = vSupply.balanceOf(address(this)) * vSupply.exchangeRateStored() / WAD;
        supplyUsd = sUnits * o.getUnderlyingPrice(address(vSupply)) / WAD;
        borrowUsd = vBorrow.borrowBalanceStored(address(this)) * o.getUnderlyingPrice(address(vBorrow)) / WAD;
    }

    /// @notice Net asset value denominated in `base`. Pure view over Venus — nothing published.
    function totalAssets() public view returns (uint256) {
        (uint256 s, uint256 b) = positionUsd();
        uint256 idle = base.balanceOf(address(this));
        if (s <= b) return idle;
        uint256 navUsd = s - b;
        return navUsd * WAD / _oracle().getUnderlyingPrice(address(vBase)) + idle;
    }

    /// @notice Base units per share, 1e18-scaled.
    function exchangeRate() public view returns (uint256) {
        uint256 ts = totalSupply;
        if (ts == 0) return WAD;
        return totalAssets() * WAD / ts;
    }

    /// @notice Live leverage: exposure to `collateral` over NAV, 1e18-scaled.
    function currentLeverage() public view returns (uint256) {
        (uint256 s, uint256 b) = positionUsd();
        if (s <= b) return 0;
        uint256 navUsd = s - b;
        uint256 exposureUsd = isLong ? s : b;
        return exposureUsd * WAD / navUsd;
    }

    function collateralFactor() public view returns (uint256 cf) {
        (, cf,) = comptroller.markets(address(vSupply));
    }

    /// @notice True when leverage has drifted outside the band and `rebalance()` will act.
    function needsRebalance() public view returns (bool) {
        uint256 lev = currentLeverage();
        if (lev == 0) return false;
        uint256 lo = targetLeverage * (BPS - bandBps) / BPS;
        uint256 hi = targetLeverage * (BPS + bandBps) / BPS;
        return lev < lo || lev > hi;
    }

    function _supplyUnderlying() internal view returns (uint256) {
        return vSupply.balanceOf(address(this)) * vSupply.exchangeRateStored() / WAD;
    }

    /// @dev Supply units that can be pulled out right now without breaching the collateral factor.
    ///      Leaves a 1% cushion so a price tick between view and call cannot make it revert.
    function _maxRedeemable() internal view returns (uint256) {
        (uint256 s, uint256 b) = positionUsd();
        uint256 cf = collateralFactor();
        uint256 borrowLimit = s * cf / WAD;
        if (borrowLimit <= b) return 0;
        uint256 freeUsd = (borrowLimit - b) * WAD / cf;
        uint256 px = _oracle().getUnderlyingPrice(address(vSupply));
        return freeUsd * WAD * 99 / (px * 100);
    }

    // ------------------------------------------------------------ user entry

    /// @notice Deposit `baseIn` of base asset, receive shares in the leveraged position.
    function mint(uint256 baseIn, uint256 minShares, address to) external returns (uint256 shares) {
        require(baseIn > 0, "zero in");
        require(to != address(0) && to != address(this), "bad recipient");
        _accrue();

        uint256 assetsBefore = totalAssets();
        uint256 ts = totalSupply;
        require(base.transferFrom(msg.sender, address(this), baseIn), "base in");

        shares = ts == 0 ? baseIn : baseIn * ts / assetsBefore;
        require(shares >= minShares && shares > 0, "slippage");
        _mint(to, shares);

        _lever();
        emit Minted(to, baseIn, shares);
    }

    /// @notice Burn shares, unwind that fraction of the position, receive base.
    function redeem(uint256 shares, uint256 minBaseOut, address to) external returns (uint256 baseOut) {
        require(shares > 0, "zero shares");
        require(to != address(0) && to != address(this), "bad recipient");
        _accrue();

        uint256 ts = totalSupply;
        uint256 fraction = shares * WAD / ts;
        _burn(msg.sender, shares);

        baseOut = _unwind(fraction);
        require(baseOut >= minBaseOut, "slippage");
        require(base.transfer(to, baseOut), "base out");
        emit Redeemed(to, shares, baseOut);
    }

    /// @notice Permissionless, and paid. Anyone may push leverage back inside the band
    ///         and is minted a bounty scaled to how far out it had drifted.
    function rebalance() external returns (uint256 bounty) {
        _accrue();
        uint256 before = currentLeverage();
        require(needsRebalance(), "in band");
        require(block.timestamp >= lastRebalanceAt + REBALANCE_COOLDOWN, "cooldown");
        lastRebalanceAt = block.timestamp;

        bounty = totalSupply * _bountyBps(before) / BPS;
        if (before > targetLeverage) {
            _unwindToTarget();
        } else {
            _lever();
        }
        if (bounty > 0) _mint(msg.sender, bounty);
        emit Rebalanced(before, currentLeverage(), msg.sender, bounty);
    }

    /// @notice Bounty in bps of supply for rebalancing at leverage `lev`. View so a caller
    ///         can price the job before spending gas on it.
    function bountyBps(uint256 lev) external view returns (uint256) {
        return _bountyBps(lev);
    }

    function _bountyBps(uint256 lev) internal view returns (uint256) {
        if (lev == 0) return 0;
        uint256 drift = lev > targetLeverage ? lev - targetLeverage : targetLeverage - lev;
        uint256 driftBps = drift * BPS / targetLeverage;
        uint256 bps = driftBps / 50;
        if (bps < BOUNTY_MIN_BPS) bps = BOUNTY_MIN_BPS;
        if (bps > BOUNTY_MAX_BPS) bps = BOUNTY_MAX_BPS;
        return bps;
    }

    /// @dev Venus stores interest lazily; poke both markets so every `*Stored` read is fresh.
    function _accrue() internal {
        vSupply.accrueInterest();
        if (address(vBorrow) != address(vSupply)) vBorrow.accrueInterest();
    }

    // -------------------------------------------------------------- internals

    /// @dev Supply `amt` of the supply asset. Unwraps first on the native market.
    function _venusSupply(uint256 amt) internal {
        if (amt < DUST) return;
        if (supplyIsNative) {
            wnative.withdraw(amt);
            IVBNB(address(vSupply)).mint{value: amt}();
        } else {
            require(vSupply.mint(amt) == 0, "venus mint");
        }
    }

    /// @dev Withdraw `amt` of the supply asset, re-wrapping on the native market.
    function _venusRedeem(uint256 amt) internal {
        if (amt < DUST) return;
        require(vSupply.redeemUnderlying(amt) == 0, "venus redeem");
        if (supplyIsNative) wnative.deposit{value: amt}();
    }

    function _venusRepay(uint256 amt) internal {
        if (amt < DUST) return;
        if (borrowIsNative) {
            wnative.withdraw(amt);
            IVBNB(address(vBorrow)).repayBorrow{value: amt}();
        } else {
            require(vBorrow.repayBorrow(amt) == 0, "venus repay");
        }
    }

    function _venusBorrow(uint256 amt) internal {
        require(vBorrow.borrow(amt) == 0, "venus borrow");
        if (borrowIsNative) wnative.deposit{value: amt}();
    }

    /// @dev Native BNB arrives here from `redeemUnderlying` / `borrow` on the BNB market.
    receive() external payable {}

    /// @dev getAmountsOut that yields 0 instead of reverting when a pair does not exist.
    function _quiet(address[] memory path, uint256 amountIn) internal view returns (uint256) {
        try router.getAmountsOut(amountIn, path) returns (uint256[] memory a) {
            return a[a.length - 1];
        } catch {
            return 0;
        }
    }

    function _swap(address from, address to, uint256 amountIn) internal returns (uint256 out) {
        if (amountIn == 0) return 0;
        if (v3Fee != 0) {
            return v3Router.exactInputSingle(
                IV3Router.ExactInputSingleParams({
                    tokenIn: from,
                    tokenOut: to,
                    fee: v3Fee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: amountIn,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        // V2 fallback. Pick the better of direct and hopped, on chain, every time. Slippage is
        // size-dependent: PancakeSwap V2's USDT/BTCB pool is ~$700k deep, so a small
        // leg is cheaper direct while a large one is cheaper through WBNB. Quoting
        // both costs gas and removes the guess.
        address[] memory path = new address[](2);
        path[0] = from;
        path[1] = to;
        if (swapHop != address(0) && from != swapHop && to != swapHop) {
            address[] memory viaHop = new address[](3);
            viaHop[0] = from;
            viaHop[1] = swapHop;
            viaHop[2] = to;
            uint256 direct = _quiet(path, amountIn);
            uint256 hopped = _quiet(viaHop, amountIn);
            if (hopped > direct) path = viaHop;
        }
        uint256[] memory amounts =
            router.swapExactTokensForTokens(amountIn, 0, path, address(this), block.timestamp);
        out = amounts[amounts.length - 1];
    }

    /// @dev Borrow-and-supply until leverage reaches target or Venus capacity runs out.
    function _lever() internal {
        // move any idle base into the supply leg first
        uint256 idle = base.balanceOf(address(this));
        if (idle > 0) {
            uint256 toSupply = address(supplyAsset) == address(base)
                ? idle
                : _swap(address(base), address(collateral), idle);
            _venusSupply(toSupply);
        }

        IVenusOracle o = _oracle();
        uint256 cf = collateralFactor();
        uint256 pxBorrow = o.getUnderlyingPrice(address(vBorrow));

        for (uint8 i = 0; i < maxLoops; i++) {
            (uint256 s, uint256 b) = positionUsd();
            if (s <= b) break;
            uint256 navUsd = s - b;
            uint256 targetSupplyUsd =
                isLong ? navUsd * targetLeverage / WAD : navUsd * (WAD + targetLeverage) / WAD;
            if (s >= targetSupplyUsd) break;

            uint256 need = targetSupplyUsd - s;
            uint256 limit = s * cf / WAD;
            if (limit <= b) break;
            uint256 capacity = (limit - b) * 99 / 100;
            uint256 takeUsd = need < capacity ? need : capacity;
            uint256 amt = takeUsd * WAD / pxBorrow;
            if (amt == 0) break;

            _venusBorrow(amt);
            uint256 got = _swap(address(borrowAsset), address(supplyAsset), amt);
            _venusSupply(got);
        }
    }

    /// @dev Shrink both legs by `fraction` (1e18) and return the base freed.
    function _unwind(uint256 fraction) internal returns (uint256 baseOut) {
        uint256 baseBefore = base.balanceOf(address(this));
        uint256 debt0 = vBorrow.borrowBalanceStored(address(this));
        uint256 supply0 = _supplyUnderlying();
        uint256 debtTarget = debt0 - debt0 * fraction / WAD;
        uint256 supplyTarget = supply0 - supply0 * fraction / WAD;

        for (uint8 i = 0; i < maxLoops; i++) {
            uint256 debt = vBorrow.borrowBalanceStored(address(this));
            if (debt <= debtTarget) break;
            uint256 repayNeed = debt - debtTarget;

            uint256 pullable = _maxRedeemable();
            if (pullable == 0) break;
            uint256 supplyNow = _supplyUnderlying();
            uint256 headroom = supplyNow > supplyTarget ? supplyNow - supplyTarget : 0;
            if (headroom == 0) break;
            uint256 pull = pullable < headroom ? pullable : headroom;
            if (pull == 0) break;

            _venusRedeem(pull);
            uint256 got = address(supplyAsset) == address(borrowAsset)
                ? pull
                : _swap(address(supplyAsset), address(borrowAsset), pull);
            uint256 pay = got < repayNeed ? got : repayNeed;
            _venusRepay(pay);
            uint256 dust = got - pay;
            if (dust > 0 && address(borrowAsset) != address(base)) {
                _swap(address(borrowAsset), address(base), dust);
            }
        }

        // pull the remaining supply down to target; that residue is the withdrawal
        uint256 s2 = _supplyUnderlying();
        if (s2 > supplyTarget) {
            uint256 rest = s2 - supplyTarget;
            uint256 cap = _maxRedeemable();
            if (rest > cap) rest = cap;
            if (rest >= DUST) {
                _venusRedeem(rest);
                if (address(supplyAsset) != address(base)) {
                    _swap(address(supplyAsset), address(base), rest);
                }
            }
        }

        uint256 nowBal = base.balanceOf(address(this));
        baseOut = nowBal > baseBefore ? nowBal - baseBefore : 0;
    }

    function _unwindToTarget() internal {
        uint256 lev = currentLeverage();
        if (lev <= targetLeverage) return;
        // shrink the position by the excess share of exposure
        uint256 fraction = (lev - targetLeverage) * WAD / lev;
        uint256 freed = _unwind(fraction);
        if (freed > 0) _lever();
    }
}
