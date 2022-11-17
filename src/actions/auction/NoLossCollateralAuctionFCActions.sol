// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {NoLossCollateralAuctionActionsBase} from "./NoLossCollateralAuctionActionsBase.sol";
import {IVault} from "../../interfaces/IVault.sol";
import {WAD, toInt256, sub, mul, div, wmul, wdiv, add} from "../../utils/Math.sol";

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// WARNING: These functions meant to be used as a a library for a PRBProxy. Some are unsafe if you call them directly.
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
interface IVaultFC {
     function redeemAndExit(
        uint256 tokenId,
        address user,
        uint256 amount
    ) external returns (uint256 redeemed);
}

interface INotionalV2 {
    struct AssetRateParameters {
        address rateOracle;
        int256 rate;
        int256 underlyingDecimals;
    }

    enum DepositActionType {
        None,
        DepositAsset,
        DepositUnderlying,
        DepositAssetAndMintNToken,
        DepositUnderlyingAndMintNToken,
        RedeemNToken,
        ConvertCashToNToken
    }

    struct BalanceActionWithTrades {
        DepositActionType actionType;
        uint16 currencyId;
        uint256 depositActionAmount;
        uint256 withdrawAmountInternalPrecision;
        bool withdrawEntireCashBalance;
        bool redeemToUnderlying;
        bytes32[] trades;
    }

    function batchBalanceAndTradeAction(address account, BalanceActionWithTrades[] calldata actions) external payable;

    function getSettlementRate(uint16 currencyId, uint40 maturity) external view returns (AssetRateParameters memory);
}

/// @title Constants
/// @notice Copied from https://github.com/notional-finance/contracts-v2/blob/master/contracts/global/Constants.sol
/// Replaced OZ safe math with Math.sol
library Constants {
    int256 internal constant INTERNAL_TOKEN_PRECISION = 1e8;

    uint256 internal constant MAX_TRADED_MARKET_INDEX = 7;

    uint256 internal constant DAY = 86400;
    uint256 internal constant WEEK = DAY * 6;
    uint256 internal constant MONTH = WEEK * 5;
    uint256 internal constant QUARTER = MONTH * 3;
    uint256 internal constant YEAR = QUARTER * 4;

    uint256 internal constant DAYS_IN_WEEK = 6;
    uint256 internal constant DAYS_IN_MONTH = 30;
    uint256 internal constant DAYS_IN_QUARTER = 90;

    uint8 internal constant FCASH_ASSET_TYPE = 1;
    uint8 internal constant MAX_LIQUIDITY_TOKEN_INDEX = 8;

    bytes2 internal constant UNMASK_FLAGS = 0x3FFF;
    uint16 internal constant MAX_CURRENCIES = uint16(UNMASK_FLAGS);
}

/// @title DatetTime
/// @notice Copied from
/// https://github.com/notional-finance/contracts-v2/blob/master/contracts/internal/markets/DateTime.sol
/// Added Custom Errors
library DateTime {
    error DateTime__getReferenceTime_invalidBlockTime();
    error DateTime__getTradedMarket_invalidIndex();
    error DateTime__getMarketIndex_zeroMaxMarketIndex();
    error DateTime__getMarketIndex_invalidMaxMarketIndex();
    error DateTime__getMarketIndex_marketNotFound();

    function getReferenceTime(uint256 blockTime) internal pure returns (uint256) {
        if (blockTime < Constants.QUARTER) revert DateTime__getReferenceTime_invalidBlockTime();
        return blockTime - (blockTime % Constants.QUARTER);
    }

    function getTradedMarket(uint256 index) internal pure returns (uint256) {
        if (index == 1) return Constants.QUARTER;
        if (index == 2) return 2 * Constants.QUARTER;
        if (index == 3) return Constants.YEAR;
        if (index == 4) return 2 * Constants.YEAR;
        if (index == 5) return 5 * Constants.YEAR;
        if (index == 6) return 10 * Constants.YEAR;
        if (index == 7) return 20 * Constants.YEAR;

        revert DateTime__getTradedMarket_invalidIndex();
    }

    function getMarketIndex(
        uint256 maxMarketIndex,
        uint256 maturity,
        uint256 blockTime
    ) internal pure returns (uint256, bool) {
        if (maxMarketIndex == 0) revert DateTime__getMarketIndex_zeroMaxMarketIndex();
        if (maxMarketIndex > Constants.MAX_TRADED_MARKET_INDEX) revert DateTime__getMarketIndex_invalidMaxMarketIndex();

        uint256 tRef = DateTime.getReferenceTime(blockTime);

        for (uint256 i = 1; i <= maxMarketIndex; i++) {
            uint256 marketMaturity = add(tRef, DateTime.getTradedMarket(i));
            // If market matches then is not idiosyncratic
            if (marketMaturity == maturity) return (i, false);
            // Returns the market that is immediately greater than the maturity
            if (marketMaturity > maturity) return (i, true);
        }

        revert DateTime__getMarketIndex_marketNotFound();
    }
}

/// @title EncodeDecode
/// @notice Copied from
/// https://github.com/notional-finance/notional-solidity-sdk/blob/master/contracts/lib/EncodeDecode.sol
library EncodeDecode {
    enum TradeActionType {
        Lend,
        Borrow,
        AddLiquidity,
        RemoveLiquidity,
        PurchaseNTokenResidual,
        SettleCashDebt
    }

    function decodeERC1155Id(uint256 id)
        internal
        pure
        returns (
            uint16 currencyId,
            uint40 maturity,
            uint8 assetType
        )
    {
        assetType = uint8(id);
        maturity = uint40(id >> 8);
        currencyId = uint16(id >> 48);
    }

    function encodeBorrowTrade(
        uint8 marketIndex,
        uint88 fCashAmount,
        uint32 maxImpliedRate
    ) internal pure returns (bytes32) {
        return
            bytes32(
                uint256(
                    (uint256(uint8(TradeActionType.Borrow)) << 248) |
                        (uint256(marketIndex) << 240) |
                        (uint256(fCashAmount) << 152) |
                        (uint256(maxImpliedRate) << 120)
                )
            );
    }
}

/// @title NoLossCollateralAuctionActions
/// @notice A set of actions for buying and redeeming collateral from NoLossCollateralAuction
contract NoLossCollateralAuctionFCActions is NoLossCollateralAuctionActionsBase {
    using SafeERC20 for IERC20;

    error NoLossCollateralAuctionFYActions__toUint128_overflow();
    error NoLossCollateralAuctionFCActions__sellfCash_amountOverflow();
    error NoLossCollateralAuctionFCActions__getMarketIndex_invalidMarket();

    /// ======== Storage ======== ///

    /// @notice Address of the Notional V2 monolith
    INotionalV2 public immutable notionalV2;

    constructor(
        address codex_,
        address moneta_,
        address fiat_,
        address noLossCollateralAuction_,
        address notionalV2_
    ) NoLossCollateralAuctionActionsBase(codex_, moneta_, fiat_, noLossCollateralAuction_) {
        notionalV2 = INotionalV2(notionalV2_);
    }

    /// @notice Take collateral and redeems it for underlier
    /// FIAT from `from` and sending the underlier to `recipient`
    /// @dev The user needs to previously approve the UserProxy for spending collateral tokens or FIAT tokens
    /// @param vault Address of the collateral's vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param from Address which puts up the FIAT
    /// @param auctionId Id of the auction to buy collateral from
    /// @param maxCollateralToBuy Max. amount of collateral to buy [wad]
    /// @param maxPrice Max. acceptable price to pay for collateral (Credit / collateral) [wad]
    /// @param recipient Address which receives the underlier
    function takeCollateralAndRedeemForUnderlier(
        address vault,
        uint256 tokenId,
        address from,
        uint256 auctionId,
        uint256 maxCollateralToBuy,
        uint256 maxPrice,
        address recipient
    ) external {
        // Take collateral
        uint256 fCashAmount = takeCollateral(
            vault,
            tokenId,
            from,
            auctionId,
            maxCollateralToBuy,
            maxPrice,
            address(this)
        );

        IVaultFC(address(vault)).redeemAndExit(
        tokenId,
        recipient,
        fCashAmount);
    }

    /// @notice Take collateral and swaps it for underlier
    /// FIAT from `from` and sending the underlier to `recipient`
    /// @dev The user needs to previously approve the UserProxy for spending collateral tokens or FIAT tokens
    /// @param vault Address of the collateral's vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param from Address which puts up the FIAT
    /// @param auctionId Id of the auction to buy collateral from
    /// @param maxCollateralToBuy Max. amount of collateral to buy [wad]
    /// @param maxPrice Max. acceptable price to pay for collateral (Credit / collateral) [wad]
    /// @param recipient Address which receives the underlier
    function takeCollateralAndSwapForUnderlier(
        address vault,
        uint256 tokenId,
        address from,
        uint256 auctionId,
        uint256 maxCollateralToBuy,
        uint256 maxPrice,
        address recipient,
        uint32 maxImpliedRate
    ) external {
        // Take collateral (fCash)
        uint256 fCashAmount = takeCollateral(
            vault,
            tokenId,
            from,
            auctionId,
            maxCollateralToBuy,
            maxPrice,
            address(this)
        );

        IVault(address(vault)).exit(tokenId, address(this), fCashAmount);
       
        // sell fCash for underlier and send it to recipient
        _sellfCash(tokenId, recipient, fCashAmount, maxImpliedRate, IERC20(IVault(vault).underlierToken()));
    }

    function _getCurrencyId(uint256 tokenId) internal pure returns (uint16) {
        return uint16(tokenId >> 48);
    }

    /// @notice Returns the current market index for this fCash asset. If this returns
    /// zero that means it is idiosyncratic and cannot be traded.
    /// @param tokenId fCash Id (ERC1155 tokenId)
    /// @return Index of the Notional Finance market
    function getMarketIndex(uint256 tokenId) public view returns (uint8) {
        (uint256 marketIndex, bool isInvalidMarket) = DateTime.getMarketIndex(
            Constants.MAX_TRADED_MARKET_INDEX,
            getMaturity(tokenId),
            block.timestamp
        );
        if (isInvalidMarket) revert NoLossCollateralAuctionFCActions__getMarketIndex_invalidMarket();

        // Market index as defined does not overflow this conversion
        return uint8(marketIndex);
    }

    /// @notice Returns the underlying fCash maturity of the token
    function getMaturity(uint256 tokenId) public pure returns (uint40 maturity) {
        (, maturity, ) = EncodeDecode.decodeERC1155Id(tokenId);
    }

    /// @dev Sells an fCash tokens (shares) back on the Notional AMM
    /// @param tokenId fCash Id (ERC1155 tokenId)
    /// @param fCashAmount The amount of fCash to sell [tokenScale]
    /// @param to Receiver of the underlier tokens
    /// @param maxImpliedRate Max. accepted annualized implied borrow rate for swapping fCash for underliers [1e9]
    /// @param underlier underlier token for fCash
    function _sellfCash(
        uint256 tokenId,
        address to,
        uint256 fCashAmount,
        uint32 maxImpliedRate,
        IERC20 underlier
    ) internal {
        
        if (fCashAmount >= type(uint88).max) revert NoLossCollateralAuctionFCActions__sellfCash_amountOverflow();

        INotionalV2.BalanceActionWithTrades[] memory action = new INotionalV2.BalanceActionWithTrades[](1);
        action[0].actionType = INotionalV2.DepositActionType.None;
        action[0].currencyId = _getCurrencyId(tokenId);
        action[0].withdrawEntireCashBalance = true;
        action[0].redeemToUnderlying = true;
        action[0].trades = new bytes32[](1);
        action[0].trades[0] = EncodeDecode.encodeBorrowTrade(
            getMarketIndex(tokenId),
            uint88(fCashAmount),
            maxImpliedRate
        );

        uint256 balanceBefore = underlier.balanceOf(address(this));
        notionalV2.batchBalanceAndTradeAction(address(this), action);
        uint256 balanceAfter = underlier.balanceOf(address(this));

        // Send the resulting underlier to the user
        underlier.safeTransfer(to, balanceAfter - balanceBefore);
    }
}
