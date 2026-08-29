// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchToken} from "./LaunchToken.sol";
import {FeeVault} from "./FeeVault.sol";
import {LPLock} from "./LPLock.sol";
import {LevVault} from "./LevVault.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {IERC20Min, IPancakeRouter} from "./interfaces/IVenus.sol";

interface IPancakeFactory {
    function createPair(address, address) external returns (address);
    function getPair(address, address) external view returns (address);
}

interface IPancakeRouterLiq {
    function addLiquidity(address, address, uint256, uint256, uint256, uint256, address, uint256)
        external
        returns (uint256, uint256, uint256);
}

/// @title Bonding — a constant-product curve whose reserve asset is a LevVault share.
/// @notice Both sides of the curve move. The token's price in base is the curve price
///         multiplied by the vault's exchange rate, so a launch can cross the graduation
///         line because its backing appreciated, with no new buying at all.
///
///         Unlike a keeper-published reserve, that exchange rate is a pure view over
///         Venus state: every buyer prices the reserve themselves, in their own block.
contract Bonding {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    uint256 public constant CURVE_SUPPLY = 750_000_000e18;
    uint256 public constant LP_SUPPLY = 250_000_000e18;
    /// @dev Virtual reserve is denominated in vault shares, so it appreciates with the backing.
    uint256 public constant VIRTUAL_SHARES = 4_000e18;
    uint256 public constant GRADUATION_BASE = 12_000e18;
    uint256 public constant FEE_BPS = 100;
    uint256 public constant MIN_SEED = 5e18;
    uint64 public constant LAUNCH_DELAY_BLOCKS = 5;

    IERC20Min public immutable base;
    IPancakeFactory public immutable pancakeFactory;
    IPancakeRouterLiq public immutable pancakeRouter;
    FeeVault public immutable feeVault;
    LPLock public immutable lpLock;
    VaultFactory public immutable vaultFactory;

    struct Curve {
        address vault;
        address creator;
        uint256 reserveShares;
        uint256 tokensLeft;
        uint64 launchBlock;
        bool graduated;
        address pair;
    }

    mapping(address => Curve) public curves;
    address[] public tokens;

    event Launched(address indexed token, address indexed creator, address indexed vault, uint256 seed);
    event Bought(address indexed token, address indexed buyer, uint256 baseIn, uint256 tokensOut);
    event Sold(address indexed token, address indexed seller, uint256 tokensIn, uint256 baseOut);
    event Graduated(address indexed token, address indexed pair, uint256 burned, uint256 lp);

    struct Meta {
        string name;
        string symbol;
        string description;
        string image;
        string[3] links;
    }

    constructor(address _base, address _factory, address _router, address _custody, address _vaultFactory) {
        require(_vaultFactory != address(0), "vault factory zero");
        vaultFactory = VaultFactory(_vaultFactory);
        base = IERC20Min(_base);
        pancakeFactory = IPancakeFactory(_factory);
        pancakeRouter = IPancakeRouterLiq(_router);
        feeVault = new FeeVault(_base, address(this), _custody);
        lpLock = new LPLock();
    }

    function tokenCount() external view returns (uint256) {
        return tokens.length;
    }

    // ------------------------------------------------------------------ curve

    /// @dev Constant product over (virtual + reserve) shares and remaining tokens.
    function _tokensOut(Curve storage c, uint256 sharesIn) internal view returns (uint256) {
        uint256 x = VIRTUAL_SHARES + c.reserveShares;
        uint256 y = c.tokensLeft;
        uint256 k = x * y;
        uint256 newY = k / (x + sharesIn);
        return y - newY;
    }

    function _sharesOut(Curve storage c, uint256 tokensIn) internal view returns (uint256) {
        uint256 x = VIRTUAL_SHARES + c.reserveShares;
        uint256 y = c.tokensLeft;
        uint256 k = x * y;
        uint256 newX = k / (y + tokensIn);
        return x - newX;
    }

    /// @notice Backing value of a launch, in base units. Moves with the vault, untraded.
    function backingBase(address token) public view returns (uint256) {
        Curve storage c = curves[token];
        if (c.vault == address(0)) return 0;
        return c.reserveShares * LevVault(payable(c.vault)).exchangeRate() / WAD;
    }

    function canGraduate(address token) public view returns (bool) {
        Curve storage c = curves[token];
        if (c.graduated || c.vault == address(0)) return false;
        return backingBase(token) >= GRADUATION_BASE || c.tokensLeft == 0;
    }

    // ----------------------------------------------------------------- launch

    function launch(Meta calldata m, address vault, uint256 seed) external returns (address token) {
        require(seed >= MIN_SEED, "seed too small");
        // Provenance, not shape. An interface check would let a caller pass a look-alike
        // whose mint() keeps the deposit — see VaultFactory.
        require(vaultFactory.isVault(vault), "unknown vault");

        LaunchToken t = new LaunchToken(m.name, m.symbol, m.description, m.image, m.links);
        token = address(t);

        Curve storage c = curves[token];
        c.vault = vault;
        c.creator = msg.sender;
        c.tokensLeft = CURVE_SUPPLY;
        c.launchBlock = uint64(block.number);
        tokens.push(token);

        emit Launched(token, msg.sender, vault, seed);
        _buy(token, seed, 0, msg.sender);
    }

    function buy(address token, uint256 baseIn, uint256 minTokensOut, address to)
        external
        returns (uint256 tokensOut)
    {
        Curve storage c = curves[token];
        require(block.number >= c.launchBlock + LAUNCH_DELAY_BLOCKS, "not open");
        return _buy(token, baseIn, minTokensOut, to);
    }

    function _buy(address token, uint256 baseIn, uint256 minTokensOut, address to)
        internal
        returns (uint256 tokensOut)
    {
        Curve storage c = curves[token];
        require(!c.graduated, "graduated");
        require(to != address(0), "to zero");
        require(base.transferFrom(msg.sender, address(this), baseIn), "base in");

        uint256 fee = baseIn * FEE_BPS / BPS;
        require(base.transfer(address(feeVault), fee), "fee");
        feeVault.accrue(token, c.creator, fee);

        uint256 net = baseIn - fee;
        base.approve(c.vault, net);
        uint256 shares = LevVault(payable(c.vault)).mint(net, 0, address(this));

        tokensOut = _tokensOut(c, shares);
        require(tokensOut >= minTokensOut && tokensOut > 0, "slippage");

        c.reserveShares += shares;
        c.tokensLeft -= tokensOut;
        require(LaunchToken(token).transfer(to, tokensOut), "token out");
        emit Bought(token, to, baseIn, tokensOut);
    }

    function sell(address token, uint256 tokensIn, uint256 minBaseOut, address to)
        external
        returns (uint256 baseOut)
    {
        Curve storage c = curves[token];
        require(!c.graduated, "graduated");
        require(to != address(0), "to zero");
        require(LaunchToken(token).transferFrom(msg.sender, address(this), tokensIn), "token in");

        uint256 shares = _sharesOut(c, tokensIn);
        require(shares <= c.reserveShares, "reserve");
        c.reserveShares -= shares;
        c.tokensLeft += tokensIn;

        uint256 gross = LevVault(payable(c.vault)).redeem(shares, 0, address(this));
        uint256 fee = gross * FEE_BPS / BPS;
        require(base.transfer(address(feeVault), fee), "fee");
        feeVault.accrue(token, c.creator, fee);

        baseOut = gross - fee;
        require(baseOut >= minBaseOut, "slippage");
        require(base.transfer(to, baseOut), "base out");
        emit Sold(token, to, tokensIn, baseOut);
    }

    // -------------------------------------------------------------- graduation

    /// @notice Permissionless. Anyone may push a launch over the line once its backing qualifies.
    ///         The pool is TOKEN/vault-share, so the graduated market keeps moving too.
    function graduate(address token) external {
        Curve storage c = curves[token];
        require(canGraduate(token), "not eligible");
        c.graduated = true;

        uint256 burned = c.tokensLeft;
        if (burned > 0) {
            require(LaunchToken(token).transfer(address(0xdEaD), burned), "burn");
            c.tokensLeft = 0;
        }

        address share = c.vault;
        address pair = pancakeFactory.getPair(token, share);
        if (pair == address(0)) pair = pancakeFactory.createPair(token, share);
        c.pair = pair;

        uint256 shares = c.reserveShares;
        c.reserveShares = 0;

        LaunchToken(token).lift();
        LaunchToken(token).approve(address(pancakeRouter), LP_SUPPLY);
        IERC20Min(share).approve(address(pancakeRouter), shares);
        (,, uint256 lp) = pancakeRouter.addLiquidity(
            token, share, LP_SUPPLY, shares, 0, 0, address(lpLock), block.timestamp
        );
        lpLock.note(pair, lp);
        emit Graduated(token, pair, burned, lp);
    }
}
