// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "./Constants.sol";
import "./Types.sol";
import "./SafeInt256.sol";
import "./DateTime.sol";

library EncodeDecode {
    using SafeInt256 for int256;

    function convertToExternal(int256 amount, int256 decimals) internal pure returns (int256) {
        if (decimals == Constants.INTERNAL_TOKEN_PRECISION) return amount;
        return amount.mul(decimals).div(Constants.INTERNAL_TOKEN_PRECISION);
    }

    function convertToInternal(int256 amount, int256 decimals) internal pure returns (int256) {
        if (decimals == Constants.INTERNAL_TOKEN_PRECISION) return amount;
        return amount.mul(Constants.INTERNAL_TOKEN_PRECISION).div(decimals);
    }

    /// @notice Decodes asset ids
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

    /// @notice Encodes asset ids
    function encodeERC1155Id(
        uint256 currencyId,
        uint256 maturity,
        uint256 assetType
    ) internal pure returns (uint256) {
        require(currencyId <= Constants.MAX_CURRENCIES);
        require(maturity <= type(uint40).max);
        require(assetType <= Constants.MAX_LIQUIDITY_TOKEN_INDEX);

        return
            uint256(
                (bytes32(uint256(uint16(currencyId))) << 48) |
                    (bytes32(uint256(uint40(maturity))) << 8) |
                    bytes32(uint256(uint8(assetType)))
            );
    }

    function encodeLendTrade(
        uint8 marketIndex,
        uint88 fCashAmount,
        uint32 minImpliedRate
    ) internal pure returns (bytes32) {
        return
            bytes32(
                (uint256(uint8(TradeActionType.Lend)) << 248) |
                    (uint256(marketIndex) << 240) |
                    (uint256(fCashAmount) << 152) |
                    (uint256(minImpliedRate) << 120)
            );
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

    function encodeAddLiquidity(
        uint8 marketIndex,
        uint88 assetCashAmount,
        uint32 minImpliedRate,
        uint32 maxImpliedRate
    ) internal pure returns (bytes32) {
        return
            bytes32(
                uint256(
                    (uint8(TradeActionType.AddLiquidity) << 248) |
                        (marketIndex << 240) |
                        (assetCashAmount << 152) |
                        (minImpliedRate << 120) |
                        (maxImpliedRate << 88)
                )
            );
    }

    function encodeRemoveLiquidity(
        uint8 marketIndex,
        uint88 tokenAmount,
        uint32 minImpliedRate,
        uint32 maxImpliedRate
    ) internal pure returns (bytes32) {
        return
            bytes32(
                uint256(
                    (uint8(TradeActionType.RemoveLiquidity) << 248) |
                        (marketIndex << 240) |
                        (tokenAmount << 152) |
                        (minImpliedRate << 120) |
                        (maxImpliedRate << 88)
                )
            );
    }

    function encodePurchaseNTokenResidual(uint32 maturity, int88 fCashResidualAmount) internal pure returns (bytes32) {
        return
            bytes32(
                uint256(
                    (uint8(TradeActionType.PurchaseNTokenResidual) << 248) |
                        (maturity << 216) |
                        (uint256(int256(fCashResidualAmount)) << 128)
                )
            );
    }

    function encodeSettleCashDebt(address counterparty, int88 fCashAmountToSettle) internal pure returns (bytes32) {
        return
            bytes32(
                uint256(
                    (uint8(TradeActionType.SettleCashDebt) << 248) |
                        (uint256(bytes32(bytes20(counterparty))) << 88) |
                        (uint256(int256(fCashAmountToSettle)))
                )
            );
    }

    function encodeOffsettingTrade(
        int256 notional,
        uint256 maturity,
        uint256 blockTime
    ) internal pure returns (bytes32, bool) {
        if (notional == 0) return (bytes32(0), false);
        (uint256 marketIndex, bool isIdiosyncratic) = DateTime.getMarketIndex(
            Constants.MAX_TRADED_MARKET_INDEX,
            maturity,
            blockTime
        );
        // Cannot trade out of an idiosyncratic asset
        if (isIdiosyncratic) return (bytes32(0), false);

        require(type(int88).min < notional && notional < type(int88).max);
        if (notional > 0) {
            return (encodeBorrowTrade(uint8(marketIndex), uint88(int88(notional.abs())), 0), true);
        } else {
            return (encodeLendTrade(uint8(marketIndex), uint88(int88(notional.abs())), 0), true);
        }
    }

    function encodeOffsettingTradesFromPortfolio(
        PortfolioAsset[] memory portfolio,
        uint256 fCashCurrency,
        uint256 blockTime
    ) private pure returns (bytes32[] memory) {
        uint256 numTrades;

        bytes32[] memory trades = new bytes32[](portfolio.length);
        for (uint256 i; i < portfolio.length; i++) {
            PortfolioAsset memory asset = portfolio[i];
            if (asset.currencyId != fCashCurrency) {
                continue;
            } else if (asset.assetType == Constants.FCASH_ASSET_TYPE) {
                (bytes32 trade, bool success) = encodeOffsettingTrade(asset.notional, asset.maturity, blockTime);

                if (success) {
                    trades[numTrades] = trade;
                    numTrades++;
                }
            } else {
                // If the token's settlement date is in the past, it will be settled and cannot be
                // removed from the portfolio
                uint256 settlementDate = DateTime.getSettlementDate(asset);
                if (settlementDate <= blockTime) continue;

                (
                    uint256 marketIndex, /* bool isIdiosyncratic */

                ) = DateTime.getMarketIndex(Constants.MAX_TRADED_MARKET_INDEX, asset.maturity, blockTime);
                require(0 < asset.notional && asset.notional < int256(uint256(type(uint88).max)));

                trades[numTrades] = encodeRemoveLiquidity(uint8(marketIndex), uint88(uint256(asset.notional)), 0, 0);
                numTrades++;
            }
        }

        // Resize the trades array down to numTrades length
        assembly {
            mstore(trades, sub(mload(trades), numTrades))
        }
        return trades;
    }

    function encodeOffsettingTradesFromArrays(
        uint256[] memory fCashMaturities,
        int256[] memory fCashNotional,
        uint256 blockTime
    ) internal pure returns (bytes32[] memory) {
        require(fCashMaturities.length == fCashNotional.length, "Trade Length Mismatch");

        uint256 numTrades;
        bytes32[] memory trades = new bytes32[](fCashMaturities.length);
        for (uint256 i; i < fCashNotional.length; i++) {
            (bytes32 trade, bool success) = encodeOffsettingTrade(fCashNotional[i], fCashMaturities[i], blockTime);

            if (success) {
                trades[numTrades] = trade;
                numTrades++;
            }
        }

        // Resize the trades array down to numTrades length
        assembly {
            mstore(trades, sub(mload(trades), numTrades))
        }
        return trades;
    }
}
