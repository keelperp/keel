// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LevVault} from "../src/LevVault.sol";
import {IERC20Min} from "../src/interfaces/IVenus.sol";

/// @notice Full-lifecycle probe, run as a single `eth_call` against live BNB Chain state.
///         BSC public nodes prune state after ~96s and no free archive node exists, so a
///         forge fork cannot survive a multi-step test. One atomic call can.
contract KeelProbe {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant vUSDT = 0xfD5840Cd36d94D7229439859C0112a4185BC0255;
    address constant vBTC = 0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B;
    address constant vBNB = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;
    address constant COMPTROLLER = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    struct Result {
        uint256 shares;
        uint256 rateAfterMint;
        uint256 leverage;
        uint256 totalAssets;
        uint256 baseOut;
        uint256 roundTripBps; // baseOut / baseIn in bps
        uint256 supplyUsd;
        uint256 borrowUsd;
    }

    /// @param collateralIsBtc true -> BTCB market, false -> BNB market (via vBNB is native; we use BTCB or WBNB)
    function run(uint256 baseIn, uint256 leverageX18, bool isLong, bool collateralIsBtc, uint8 loops)
        external
        returns (Result memory r)
    {
        return _run(baseIn, leverageX18, isLong, collateralIsBtc, loops, collateralIsBtc ? WBNB : address(0));
    }

    /// @notice Same block, same state, two routing configs — the only honest A/B.
    function ab(uint256 baseIn, uint256 leverageX18, bool isLong, bool collateralIsBtc, uint8 loops)
        external
        returns (Result memory direct, Result memory hopped)
    {
        direct = _run(baseIn, leverageX18, isLong, collateralIsBtc, loops, address(0));
        hopped = _run(baseIn, leverageX18, isLong, collateralIsBtc, loops, WBNB);
    }

    function _run(
        uint256 baseIn,
        uint256 leverageX18,
        bool isLong,
        bool collateralIsBtc,
        uint8 loops,
        address hop
    ) internal returns (Result memory r) {
        address coll = collateralIsBtc ? BTCB : WBNB;
        address vColl = collateralIsBtc ? vBTC : vBNB;

        LevVault v = new LevVault(
            LevVault.Config({
                name: "Keel BTC 3L",
                symbol: "kBTC3L",
                base_: USDT,
                collateral_: coll,
                vBase: vUSDT,
                vCollateral: vColl,
                comptroller: COMPTROLLER,
                router: ROUTER,
                targetLeverage_: leverageX18,
                isLong_: isLong,
                bandBps_: 500,
                maxLoops_: loops,
                collateralIsNative: !collateralIsBtc,
                swapHop: hop
            })
        );

        IERC20Min(USDT).approve(address(v), type(uint256).max);
        r.shares = v.mint(baseIn, 0, address(this));
        r.rateAfterMint = v.exchangeRate();
        r.leverage = v.currentLeverage();
        r.totalAssets = v.totalAssets();
        (r.supplyUsd, r.borrowUsd) = v.positionUsd();

        r.baseOut = v.redeem(r.shares, 0, address(this));
        r.roundTripBps = r.baseOut * 10_000 / baseIn;
    }
}
