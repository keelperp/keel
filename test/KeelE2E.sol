// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LevVault} from "../src/LevVault.sol";
import {Bonding} from "../src/Bonding.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IERC20Min} from "../src/interfaces/IVenus.sol";

/// @notice launch -> sell -> graduate, as one atomic eth_call on live BNB Chain state.
contract KeelE2E {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant vUSDT = 0xfD5840Cd36d94D7229439859C0112a4185BC0255;
    address constant vBTC = 0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B;
    address constant COMPTROLLER = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    struct Out {
        uint256 seedTokens;
        uint256 backingAfterSeed;
        uint256 vaultLeverage;
        uint256 soldBaseOut;
        uint256 backingAfterSell;
        uint8 eligible;
        uint256 burnedAtGraduation;
        uint256 lpToLock;
        uint256 lpHeldByLock;
        uint8 unrestricted;
        uint256 creatorFee;
        uint256 protocolFee;
    }

    /// @notice The gate proven red: a vault the factory never created must be refused.
    /// @return refused 1 when launch reverted with "unknown vault", 0 when it went through
    function rogueVault() external returns (uint8 refused, string memory got) {
        VaultFactory f = new VaultFactory(address(this));
        Bonding b = new Bonding(USDT, FACTORY, ROUTER, address(this), address(f));

        // built directly, never listed by the factory
        LevVault rogue = new LevVault(
            LevVault.Config({
                name: "Rogue",
                symbol: "R",
                base_: USDT,
                collateral_: BTCB,
                vBase: vUSDT,
                vCollateral: vBTC,
                comptroller: COMPTROLLER,
                router: ROUTER,
                targetLeverage_: 3e18,
                isLong_: true,
                bandBps_: 500,
                maxLoops_: 5,
                collateralIsNative: false,
                swapHop: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
                v3Router: V3_ROUTER,
                v3Fee: 500
            })
        );
        require(rogue.targetLeverage() > 0, "rogue looks real");

        IERC20Min(USDT).approve(address(b), type(uint256).max);
        Bonding.Meta memory m =
            Bonding.Meta({name: "Rogue", symbol: "R", description: "", image: "", links: ["", "", ""]});
        try b.launch(m, address(rogue), 1000e18) returns (address) {
            return (0, "ACCEPTED - GATE IS OPEN");
        } catch Error(string memory reason) {
            return (1, reason);
        }
    }

    function run(uint256 seed, uint256 sellBps) external returns (Out memory o) {
        VaultFactory f = new VaultFactory(address(this));
        LevVault v = LevVault(
            payable(f.create(
                    LevVault.Config({
                        name: "Keel BTC 3L",
                        symbol: "kBTC3L",
                        base_: USDT,
                        collateral_: BTCB,
                        vBase: vUSDT,
                        vCollateral: vBTC,
                        comptroller: COMPTROLLER,
                        router: ROUTER,
                        targetLeverage_: 3e18,
                        isLong_: true,
                        bandBps_: 500,
                        maxLoops_: 5,
                        collateralIsNative: false,
                        swapHop: 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c,
                        v3Router: V3_ROUTER,
                        v3Fee: 500
                    })
                ))
        );
        Bonding b = new Bonding(USDT, FACTORY, ROUTER, address(this), address(f));
        IERC20Min(USDT).approve(address(b), type(uint256).max);

        Bonding.Meta memory m = Bonding.Meta({
            name: "Test Launch", symbol: "TL", description: "e2e", image: "", links: ["", "", ""]
        });
        address token = b.launch(m, address(v), seed);

        o.seedTokens = LaunchToken(token).balanceOf(address(this));
        o.backingAfterSeed = b.backingBase(token);
        o.vaultLeverage = v.currentLeverage();

        // sell a slice back into the curve
        uint256 sellAmt = o.seedTokens * sellBps / 10_000;
        if (sellAmt > 0) {
            LaunchToken(token).approve(address(b), sellAmt);
            o.soldBaseOut = b.sell(token, sellAmt, 0, address(this));
        }
        o.backingAfterSell = b.backingBase(token);

        o.eligible = b.canGraduate(token) ? 1 : 0;
        if (o.eligible == 1) {
            (,,, uint256 leftBefore,,,) = b.curves(token);
            b.graduate(token);
            o.burnedAtGraduation = leftBefore;
            (,,,,,, address pair) = b.curves(token);
            o.lpHeldByLock = IERC20Min(pair).balanceOf(address(b.lpLock()));
            o.lpToLock = o.lpHeldByLock;
            o.unrestricted = LaunchToken(token).unrestricted() ? 1 : 0;
        }
        o.creatorFee = b.feeVault().claimable(address(this));
        o.protocolFee = b.feeVault().protocolAccrued();
    }
}
