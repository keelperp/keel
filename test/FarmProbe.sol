// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ITok {
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function dividendContract() external view returns (address);
    function antiFarmerExpirationTime() external view returns (uint256);
}

interface IDiv {
    function totalShares() external view returns (uint256);
    function minimumShareBalance() external view returns (uint256);
    function accumulativeDividendOf(address) external view returns (uint256);
    function excludedFromDividends(address) external view returns (bool);
}

/// @notice Does a buy inside the anti-farmer window earn dividend shares or not?
///         The probe's code is overridden onto the token's own pair, so a transfer out of
///         it is exactly what a buy does.
contract FarmProbe {
    struct Out {
        uint256 windowEnds;
        uint256 nowTs;
        uint256 sharesBefore;
        uint256 sharesAfter;
        uint256 buyerBalance;
        uint256 minShare;
        uint8 buyerExcluded;
        uint8 transferOk;
    }

    function run(address token, address buyer, uint256 amount) external returns (Out memory o) {
        IDiv d = IDiv(ITok(token).dividendContract());
        o.windowEnds = ITok(token).antiFarmerExpirationTime();
        o.nowTs = block.timestamp;
        o.minShare = d.minimumShareBalance();
        o.sharesBefore = d.totalShares();
        o.transferOk = ITok(token).transfer(buyer, amount) ? 1 : 0;
        o.buyerBalance = ITok(token).balanceOf(buyer);
        o.sharesAfter = d.totalShares();
        o.buyerExcluded = d.excludedFromDividends(buyer) ? 1 : 0;
    }
}
