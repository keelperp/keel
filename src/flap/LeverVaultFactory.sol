// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BeaconProxy} from "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import {VaultFactoryBaseV2} from "./VaultFactoryBaseV2.sol";
import {VaultDataSchema, FieldDescriptor} from "./IVaultSchemasV1.sol";
import {IVaultFactoryValidationV2} from "./IVaultFactory.sol";
import {LeverVault} from "./LeverVault.sol";
import {LeverBeacon} from "./LeverBeacon.sol";

/// @title LeverVaultFactory — the only way a LeverVault comes into existence
///
/// @notice Flap's VaultPortal calls `newVault` while creating a tax token, and hands it
///         the token's predicted address. This factory answers with a BeaconProxy whose
///         implementation the Flap Guardian controls.
///
/// @dev Rule 002 / 001 notes:
///      - inherits `VaultFactoryBaseV2` and overrides `vaultDataSchema()`;
///      - `newVault` reverts for any caller that is not the VaultPortal;
///      - there are no role-gated functions here and none on the vault, so there is no
///        role for the Guardian to be granted and nothing that could lock it out. The
///        Guardian's authority is the beacon it owns, set in `LeverBeacon`'s constructor;
///      - reverts are `require()` with inline bilingual literals, per rule 004.
contract LeverVaultFactory is VaultFactoryBaseV2 {
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    /// @notice The beacon every vault this factory deploys points at. Guardian-owned.
    address public immutable beacon;

    /// @notice Vaults created by this factory, oldest first.
    address[] public vaults;
    mapping(address => address) public vaultOf;

    event VaultCreated(
        address indexed taxToken, address indexed vault, address indexed creator, address project
    );

    constructor() {
        beacon = address(new LeverBeacon(address(new LeverVault())));
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    /// @notice Only native BNB. The vault borrows against BNB collateral on Venus and pays
    ///         holders in WBNB, so an ERC-20 quote would be a different vault, not a
    ///         parameter of this one.
    function isQuoteTokenSupported(address quoteToken) external pure override returns (bool supported) {
        return quoteToken == address(0);
    }

    /// @notice Refuse a launch this vault could never serve, before the token exists.
    ///
    /// @dev Spec v2.2 retires `onBeforeNewTokenV6WithVault` — the base reverts
    ///      `LegacyV6ValidationHookNotImplemented` — and routes validation through
    ///      `onBeforeLaunch`, which lands here. Getting this wrong is silent: a guard
    ///      written against the old hook simply never runs.
    ///
    ///      Each rejection below is a mistake that cannot be repaired after launch:
    ///      - a non-WBNB dividend token makes `harvest()` revert forever, so the treasury
    ///        grows and no holder can ever be paid out of it;
    ///      - zero tax, or a zero vault share, means the vault is created and never funded;
    ///      - zero `dividendBps` strands every gain the same way a wrong dividend token does.
    function _validateBeforeLaunch(IVaultFactoryValidationV2.LaunchValidationDataV1 memory data)
        internal
        pure
        override
        returns (bool success, string memory reason)
    {
        if (data.quoteToken != address(0)) {
            return
                (
                    false,
                    unicode"LeverVaultFactory: quote must be native BNB / 计价资产必须是原生 BNB"
                );
        }
        // address(0) means "pay dividends in the quote token", which here is BNB and
        // reaches the dividend contract as WBNB. An explicit WBNB is the same thing.
        if (data.dividendToken != address(0) && data.dividendToken != WBNB) {
            return (
                false,
                unicode"LeverVaultFactory: dividends must be BNB or WBNB / 分红资产必须是 BNB 或 WBNB"
            );
        }
        if (data.buyTaxRate == 0 && data.sellTaxRate == 0) {
            return (
                false,
                unicode"LeverVaultFactory: a zero-tax token never funds the vault / 零税代币无法为金库注资"
            );
        }
        if (data.vaultBps == 0) {
            return (
                false,
                unicode"LeverVaultFactory: vaultBps zero means the vault never receives tax / 金库分成为零则永远收不到税"
            );
        }
        if (data.dividendBps == 0) {
            return
                (false, unicode"LeverVaultFactory: dividendBps must be non-zero / 分红份额不能为零");
        }
        return (true, "");
    }

    function vaultDataSchema() public pure override returns (VaultDataSchema memory schema) {
        schema.description = "Trading tax is levered into a 3x BNB long the vault holds on Venus. Gains are settled "
            "automatically every 5 minutes: 60% to holders as WBNB dividends, 40% to the project.";
        FieldDescriptor[] memory f = new FieldDescriptor[](1);
        f[0].name = "project";
        f[0].fieldType = "address";
        f[0].description = "Receives 40% of every harvest. Fixed at creation; the vault has no setter.";
        f[0].decimals = 0;
        schema.fields = f;
        schema.isArray = false;
    }

    function newVault(address taxToken, address quoteToken, address creator, bytes calldata vaultData)
        external
        override
        returns (address vault)
    {
        require(
            msg.sender == _getVaultPortal(),
            unicode"LeverVaultFactory: caller is not the VaultPortal / 调用方不是 VaultPortal"
        );
        require(
            taxToken != address(0), unicode"LeverVaultFactory: tax token is zero / 税收代币为零地址"
        );
        require(
            quoteToken == address(0),
            unicode"LeverVaultFactory: quote must be native BNB / 计价资产必须是原生 BNB"
        );
        require(creator != address(0), unicode"LeverVaultFactory: creator is zero / 创建者为零地址");
        require(
            vaultOf[taxToken] == address(0),
            unicode"LeverVaultFactory: vault already exists / 金库已存在"
        );
        require(vaultData.length == 32, unicode"LeverVaultFactory: invalid vault data / 金库数据无效");

        address project = abi.decode(vaultData, (address));
        require(project != address(0), unicode"LeverVaultFactory: project is zero / 项目地址为零");

        vault = address(new BeaconProxy(beacon, ""));
        LeverVault(payable(vault)).initialize(taxToken, project);

        vaults.push(vault);
        vaultOf[taxToken] = vault;
        emit VaultCreated(taxToken, vault, creator, project);
    }
}
