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
}

interface IComptroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
    function oracle() external view returns (address);
    function markets(address) external view returns (bool, uint256, bool);
    function supplyCaps(address) external view returns (uint256);
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
