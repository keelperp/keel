// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {Bonding} from "../src/Bonding.sol";
import {LevVault} from "../src/LevVault.sol";

/// @notice One transaction sequence: factory, curve, and the opening vault set.
///         Every address it prints is re-read from the broadcast artefact and
///         checked with `eth_getCode` by tools/go.mjs before anything uses it.
contract Deploy is Script {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant vUSDT = 0xfD5840Cd36d94D7229439859C0112a4185BC0255;
    address constant vBTC = 0x882C173bC7Ff3b7786CA16dfeD3DFFfb9Ee7847B;
    address constant vBNB = 0xA07c5b74C9B40447a954e1466938b865b6BBea36;
    address constant COMPTROLLER = 0xfD36E2c2a6789Db23113685031d7F16329158384;
    address constant V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant V3_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    address constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant PANCAKE_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;

    function run() external {
        address custody = vm.envAddress("KEEL_CUSTODY");
        require(custody != address(0), "KEEL_CUSTODY unset");

        vm.startBroadcast();
        VaultFactory factory = new VaultFactory(msg.sender, keccak256(type(LevVault).creationCode));
        Bonding bonding = new Bonding(USDT, PANCAKE_FACTORY, V2_ROUTER, custody, address(factory));

        address[5] memory vaults;
        vaults[0] = factory.create(
            type(LevVault).creationCode, _cfg("Keel BTC 2L", "kBTC2L", BTCB, vBTC, 2e18, true, false, 3)
        );
        vaults[1] = factory.create(
            type(LevVault).creationCode, _cfg("Keel BTC 3L", "kBTC3L", BTCB, vBTC, 3e18, true, false, 5)
        );
        // No 5x. At Venus's 80% CF, 5x IS health 1.00 — the liquidation point itself.
        // 3x is the most a 1.20 health floor can hold; see the constructor check.
        vaults[2] = factory.create(
            type(LevVault).creationCode, _cfg("Keel BNB 2L", "kBNB2L", WBNB, vBNB, 2e18, true, true, 3)
        );
        vaults[3] = factory.create(
            type(LevVault).creationCode, _cfg("Keel BTC 2S", "kBTC2S", BTCB, vBTC, 2e18, false, false, 5)
        );
        vaults[4] = factory.create(
            type(LevVault).creationCode, _cfg("Keel BNB 3L", "kBNB3L", WBNB, vBNB, 3e18, true, true, 5)
        );
        vm.stopBroadcast();

        console2.log("VaultFactory", address(factory));
        console2.log("Bonding", address(bonding));
        console2.log("FeeVault", address(bonding.feeVault()));
        console2.log("LPLock", address(bonding.lpLock()));
        for (uint256 i = 0; i < vaults.length; i++) {
            console2.log("Vault", i, vaults[i]);
        }
    }

    function _cfg(
        string memory name,
        string memory symbol,
        address collateral,
        address vCollateral,
        uint256 leverage,
        bool isLong,
        bool isNative,
        uint8 loops
    ) internal pure returns (LevVault.Config memory) {
        return LevVault.Config({
            name: name,
            symbol: symbol,
            base_: USDT,
            collateral_: collateral,
            vBase: vUSDT,
            vCollateral: vCollateral,
            comptroller: COMPTROLLER,
            router: V2_ROUTER,
            targetLeverage_: leverage,
            isLong_: isLong,
            bandBps_: 500,
            maxLoops_: loops,
            collateralIsNative: isNative,
            // WBNB cannot be its own intermediate hop; the direct pair is the deep one anyway.
            swapHop: collateral == WBNB ? address(0) : WBNB,
            v3Router: V3_ROUTER,
            v3Fee: 500,
            minHealthBps: 12_000,
            v3Factory: V3_FACTORY,
            flashFee: 100
        });
    }
}
