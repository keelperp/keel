// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Clones} from "openzeppelin-contracts/contracts/proxy/Clones.sol";
import {IVaultPortal} from "../src/flap/IVaultPortal.sol";
import {IPortalTypes, IPortalCommonTypes} from "../src/flap/IPortal.sol";

/// @notice Launches KEEL through Flap's own VaultPortal against an already-deployed factory.
///
/// @dev The factory is the artifact an auditor verifies, so a launch parameter must never be a
///      reason to redeploy it. Every value here comes from LAUNCH.md; nothing is invented at the
///      call site.
///
///      The portal deploys the token as a clone with CREATE2 and requires a 0x7777 suffix, so the
///      salt is mined. Mining runs against a fork if it is done inside the broadcast, and four
///      million predictions hold that fork open long enough for a public BSC node to prune state
///      out from under it -- which surfaces as `missing trie node` and reads like a bug. Mine
///      offline with MineKeelSalt and pass SALT in.
abstract contract KeelLaunchBase is Script {
    error UnsupportedChain(uint256 chainId);
    error NoVanitySalt();

    struct Venue {
        address vaultPortal;
        address portal;
        address taxedV3Impl;
    }

    function venueFor(uint256 chainId) public pure returns (Venue memory) {
        if (chainId == 56) {
            return Venue({
                vaultPortal: 0x90497450f2a706f1951b5bdda52B4E5d16f34C06,
                portal: 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0,
                taxedV3Impl: 0x024f18294970B5c76c0691b87f138A0317156422
            });
        }
        if (chainId == 97) {
            return Venue({
                vaultPortal: 0x027e3704fC5C16522e9393d04C60A3ac5c0d775f,
                portal: 0x5bEacaF7ABCbB3aB280e80D007FD31fcE26510e9,
                taxedV3Impl: 0xE6Ff967a887084c16D0fD71548CF709542cc1557
            });
        }
        revert UnsupportedChain(chainId);
    }

    function mineVanitySalt(Venue memory v, uint256 from) public pure returns (bytes32 salt) {
        salt = bytes32(from);
        for (uint256 i; i < 4_000_000; ++i) {
            address predicted = Clones.predictDeterministicAddress(v.taxedV3Impl, salt, v.portal);
            bytes20 a = bytes20(predicted);
            if (a[18] == 0x77 && a[19] == 0x77) return salt;
            salt = bytes32(uint256(salt) + 1);
        }
        revert NoVanitySalt();
    }

    /// @dev Every field is the value decided in LAUNCH.md. The four tax routes must sum to 10000
    ///      or the V3 launcher reverts.
    function keelParams(address factory, bytes32 salt, address project)
        public
        view
        returns (IVaultPortal.NewTokenV6WithVaultParams memory p)
    {
        p.name = "Keel";
        p.symbol = "KEEL";
        p.meta = "";
        p.dexThresh = IPortalCommonTypes.DexThreshType.FOUR_FIFTHS;
        p.salt = salt;
        p.migratorType = IPortalTypes.MigratorType.V2_MIGRATOR;
        p.quoteToken = address(0);
        p.quoteAmt = vm.envOr("DEV_BUY_WEI", uint256(0));
        p.dexId = IPortalTypes.DEXId.DEX0;
        p.buyTaxRate = 200;
        p.sellTaxRate = 200;
        p.taxDuration = 3_153_600_000;
        p.antiFarmerDuration = 259_200;
        p.mktBps = 8000;      // to the vault: builds the 3x BNB long
        p.dividendBps = 2000; // straight to the dividend contract
        p.deflationBps = 0;
        p.lpBps = 0;
        p.minimumShareBalance = 10_000e18;
        p.dividendToken = address(0); // == quote; reaches the dividend contract as WBNB
        p.commissionReceiver = address(0);
        p.tokenVersion = IPortalTypes.TokenVersion.TOKEN_TAXED_V3;
        p.vaultFactory = factory;
        p.vaultData = abi.encode(project); // receives PROJECT_SHARE_BPS; immutable after launch
    }
}

contract MineKeelSalt is KeelLaunchBase {
    function run() external view {
        Venue memory v = venueFor(vm.envOr("CHAIN", block.chainid));
        bytes32 salt = bytes32(vm.envOr("SALT", uint256(0)));
        if (salt == bytes32(0)) salt = mineVanitySalt(v, vm.envOr("SALT_OFFSET", uint256(1)));
        console2.log("SALT ", vm.toString(salt));
        console2.log("token", Clones.predictDeterministicAddress(v.taxedV3Impl, salt, v.portal));
    }
}

contract LaunchKeel is KeelLaunchBase {
    error NoFactory();
    error NoVaultCreated();

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address factory = vm.envAddress("KEEL_FACTORY");
        if (factory == address(0) || factory.code.length == 0) revert NoFactory();
        address project = vm.envOr("KEEL_PROJECT", vm.addr(pk));

        Venue memory v = venueFor(block.chainid);
        bytes32 salt = bytes32(vm.envUint("SALT"));

        vm.startBroadcast(pk);
        address token = IVaultPortal(payable(v.vaultPortal))
            .newTokenV6WithVault{value: vm.envOr("DEV_BUY_WEI", uint256(0))}(
                keelParams(factory, salt, project)
            );
        vm.stopBroadcast();

        address vault = IVaultPortal(payable(v.vaultPortal)).getVault(token).vault;
        if (vault == address(0)) revert NoVaultCreated();
        // A returned address is a simulation result until the chain has code at it.
        require(token.code.length > 0, "token has no code");
        require(vault.code.length > 0, "vault has no code");

        console2.log("KEEL token", token);
        console2.log("vault     ", vault);
        console2.log("factory   ", factory);
        console2.log("project   ", project);
    }
}
