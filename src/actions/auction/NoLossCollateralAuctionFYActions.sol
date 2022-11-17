// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {NoLossCollateralAuctionActionsBase} from "./NoLossCollateralAuctionActionsBase.sol";
import {IVault} from "../../interfaces/IVault.sol";
import {WAD, toInt256, sub, mul, div, wmul, wdiv} from "../../utils/Math.sol";

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// WARNING: These functions meant to be used as a a library for a PRBProxy. Some are unsafe if you call them directly.
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

interface IFYPool {
    function sellBasePreview(uint128 baseIn) external view returns (uint128);

    function sellBase(address to, uint128 min) external returns (uint128);

    function sellFYTokenPreview(uint128 fyTokenIn) external view returns (uint128);

    function sellFYToken(address to, uint128 min) external returns (uint128);
}

interface IFYToken {
    function redeem(address to, uint256 amount) external returns (uint256 redeemed);
}

/// @title NoLossCollateralAuctionActions
/// @notice A set of actions for buying and redeeming collateral from NoLossCollateralAuction
contract NoLossCollateralAuctionFYActions is NoLossCollateralAuctionActionsBase {
    using SafeERC20 for IERC20;

    error NoLossCollateralAuctionFYActions__toUint128_overflow();

    /// ======== Storage ======== ///

    // Swap data
    struct SwapParams {
        // Min amount of asset out [tokenScale for buying, underlierScale for selling]
        uint256 minAssetOut;
        // Address of the Yield Space v2 pool
        address yieldSpacePool;
        // Address of the underlier (underlierToken) when buying, Address of the fyToken (token) when selling
        address assetIn;
        // Address of the fyToken (token) when buying, Address of underlier (underlierToken) when selling
        address assetOut;
    }

    constructor(
        address codex_,
        address moneta_,
        address fiat_,
        address noLossCollateralAuction_
    ) NoLossCollateralAuctionActionsBase(codex_, moneta_, fiat_, noLossCollateralAuction_) {}

    /// @notice Take collateral and redeems it for underlier (AT OR AFTER maturity)
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
        // Take collateral (fyTokens)
        uint256 fyTokenAmount = takeCollateral(
            vault,
            tokenId,
            from,
            auctionId,
            maxCollateralToBuy,
            maxPrice,
            address(this)
        );

        IVault(address(vault)).exit(0, address(this), fyTokenAmount);

        // redeem fyToken for underlier
        IFYToken(IVault(vault).token()).redeem(recipient, fyTokenAmount);
    }

    /// @notice Take collateral and swaps it for underlier (BEFORE maturity)
    /// FIAT from `from` and sending the underlier to `recipient`
    /// @dev The user needs to previously approve the UserProxy for spending collateral tokens or FIAT tokens
    /// @param vault Address of the collateral's vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param from Address which puts up the FIAT
    /// @param auctionId Id of the auction to buy collateral from
    /// @param maxCollateralToBuy Max. amount of collateral to buy [wad]
    /// @param maxPrice Max. acceptable price to pay for collateral (Credit / collateral) [wad]
    /// @param recipient Address which receives the underlier
    /// @param swapParams Yield swap params
    function takeCollateralAndSwapForUnderlier(
        address vault,
        uint256 tokenId,
        address from,
        uint256 auctionId,
        uint256 maxCollateralToBuy,
        uint256 maxPrice,
        address recipient,
        SwapParams calldata swapParams
    ) external {
        // Take collateral (fyTokens)
        uint256 fyTokenAmount = takeCollateral(
            vault,
            tokenId,
            from,
            auctionId,
            maxCollateralToBuy,
            maxPrice,
            address(this)
        );
        
        IVault(address(vault)).exit(0, address(this), fyTokenAmount);

        // sell fyToken according to `swapParams`
        _sellFYToken(fyTokenAmount, recipient, swapParams);
    }

    function _sellFYToken(
        uint256 fyTokenAmount,
        address to,
        SwapParams calldata swapParams
    ) internal returns (uint256) {
        // Transfer from this contract to fypool
        IERC20(swapParams.assetIn).safeTransfer(swapParams.yieldSpacePool, fyTokenAmount);
        return uint256(IFYPool(swapParams.yieldSpacePool).sellFYToken(to, _toUint128(swapParams.minAssetOut)));
    }

    /// ======== Utils ======== ///

    /// @dev Casts from uint256 to uint128 (required by Yield Protocol)
    function _toUint128(uint256 x) private pure returns (uint128) {
        if (x >= type(uint128).max) revert NoLossCollateralAuctionFYActions__toUint128_overflow();
        return uint128(x);
    }
}
