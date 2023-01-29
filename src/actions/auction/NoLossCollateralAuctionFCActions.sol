// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {NoLossCollateralAuctionActionsBase} from "./NoLossCollateralAuctionActionsBase.sol";
import {IVault} from "../../interfaces/IVault.sol";
import {IVaultFC, INotional, Constants, DateTime, EncodeDecode} from "../vault/VaultFCActions.sol";
import {WAD, toInt256, sub, mul, div, wmul, wdiv, add} from "../../core/utils/Math.sol";

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// WARNING: These functions meant to be used as a a library for a PRBProxy. Some are unsafe if you call them directly.
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

/// @title NoLossCollateralAuctionActions
/// @notice A set of actions for buying and redeeming collateral from NoLossCollateralAuction
contract NoLossCollateralAuctionFCActions is NoLossCollateralAuctionActionsBase {
    using SafeERC20 for IERC20;

    error NoLossCollateralAuctionFYActions__toUint128_overflow();
    error NoLossCollateralAuctionFCActions__sellfCash_amountOverflow();
    error NoLossCollateralAuctionFCActions__getMarketIndex_invalidMarket();

    /// ======== Storage ======== ///

    /// @notice Address of the Notional V2 monolith
    INotional public immutable notionalV2;

    constructor(
        address codex_,
        address moneta_,
        address fiat_,
        address noLossCollateralAuction_,
        address notionalV2_
    ) NoLossCollateralAuctionActionsBase(codex_, moneta_, fiat_, noLossCollateralAuction_) {
        notionalV2 = INotional(notionalV2_);
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
        uint256 fCashAmount = takeCollateral(
            vault,
            tokenId,
            from,
            auctionId,
            maxCollateralToBuy,
            maxPrice,
            address(this)
        );

        IVaultFC(address(vault)).redeemAndExit(tokenId, recipient, fCashAmount);
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

        INotional.BalanceActionWithTrades[] memory action = new INotional.BalanceActionWithTrades[](1);
        action[0].actionType = INotional.DepositActionType.None;
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

        // send the resulting underlier to the user
        underlier.safeTransfer(to, balanceAfter - balanceBefore);
    }

    /// ======== View Methods ======== ///

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
}
