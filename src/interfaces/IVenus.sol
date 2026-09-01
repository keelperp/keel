// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Venus Core Pool (Compound V2 fork) surface used by Keel.
interface IVToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow(uint256 repayAmount) external returns (uint256);
    function accrueInterest() external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function borrowBalanceStored(address) external view returns (uint256);
    function underlying() external view returns (address);
    /// @notice Underlying held by this market and available to redeem or borrow right now.
    function getCash() external view returns (uint256);
}

interface IComptroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
    function oracle() external view returns (address);
    function markets(address) external view returns (bool, uint256, bool);
    function supplyCaps(address) external view returns (uint256);
    /// @notice Venus's own solvency answer: (error, liquidity, shortfall), all in USD 1e18.
    ///         A non-zero shortfall means the account is already liquidatable, computed with
    ///         whatever parameters Venus itself uses rather than with our copy of them.
    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);
}

interface IVenusOracle {
    /// @return price scaled to 1e(36 - underlyingDecimals); 1e18 for 18-decimal assets
    function getUnderlyingPrice(address vToken) external view returns (uint256);
}

interface IPancakeRouter {
    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256)
        external
        returns (uint256[] memory);
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @notice Venus native-BNB market. Compound's CEther shape: payable, no return value.
interface IVBNB {
    function mint() external payable;
    function repayBorrow() external payable;
    function redeemUnderlying(uint256) external returns (uint256);
    function borrow(uint256) external returns (uint256);
    function accrueInterest() external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function borrowBalanceStored(address) external view returns (uint256);
}

interface IWNative {
    function deposit() external payable;
    function withdraw(uint256) external;
}

/// @notice PancakeSwap V3 SwapRouter. Selector 0x414bf389 — the deadline-bearing variant,
///         confirmed against the deployed router's dispatch table, not assumed.
interface IV3Router {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata) external payable returns (uint256);
}

/// @notice PancakeSwap V3 pool, for the flash-build path.
interface IV3Pool {
    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data) external;
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}
