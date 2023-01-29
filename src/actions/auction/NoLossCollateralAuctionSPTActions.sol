// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {NoLossCollateralAuctionActionsBase} from "./NoLossCollateralAuctionActionsBase.sol";
import {IVault} from "../../interfaces/IVault.sol";
import {IPeriphery, IDivider, IAdapter} from "../vault/VaultSPTActions.sol";
import {WAD, toInt256, sub, mul, div, wmul, wdiv} from "../../core/utils/Math.sol";

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// WARNING: These functions meant to be used as a a library for a PRBProxy. Some are unsafe if you call them directly.
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

/// @title NoLossCollateralAuctionActions
/// @notice A set of actions for buying and redeeming collateral from NoLossCollateralAuction
contract NoLossCollateralAuctionSPTActions is NoLossCollateralAuctionActionsBase {
    using SafeERC20 for IERC20;

    /// ======== Storage ======== ///

    /// @notice Address of the Sense Finance Periphery
    IPeriphery public immutable periphery;
    /// @notice Address of the Sense Finance Divider
    IDivider public immutable divider;

    // Redeem data
    struct RedeemParams {
        // Sense Finance Adapter corresponding to the pToken
        address adapter;
        // Maturity of the pToken
        uint256 maturity;
        // Address of the pToken's yield source
        address target;
        // Address of the pToken's underlier
        address underlierToken;
        // Amount of `target` token to approve for the Sense Finance Adapter for unwrapping them for `underlierToken`
        uint256 approveTarget;
    }

    // Swap data
    struct SwapParams {
        // Sense Finance Adapter corresponding to the pToken
        address adapter;
        // Min amount of  [tokenScale for buying and selling]
        uint256 minAccepted;
        // Maturity of the pToken
        uint256 maturity;
        // Address of the asset to be swapped for `assetOut`, `underlierToken` for buying, `collateral` for selling
        address assetIn;
        // Address of the asset to receive in ex. for `assetOut`, `collateral` for buying, `underlierToken` for selling
        address assetOut;
        // Amount of `assetIn` to approve for the Sense Finance Periphery for swapping `assetIn` for `assetOut`
        uint256 approve;
    }

    constructor(
        address codex_,
        address moneta_,
        address fiat_,
        address noLossCollateralAuction_,
        address periphery_
    ) NoLossCollateralAuctionActionsBase(codex_, moneta_, fiat_, noLossCollateralAuction_) {
        divider = IDivider(IPeriphery(periphery_).divider());
        periphery = IPeriphery(periphery_);
    }

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
    /// @param redeemParams Sense redeem params
    function takeCollateralAndRedeemForUnderlier(
        address vault,
        uint256 tokenId,
        address from,
        uint256 auctionId,
        uint256 maxCollateralToBuy,
        uint256 maxPrice,
        address recipient,
        RedeemParams calldata redeemParams
    ) external {
        uint256 pTokenAmount = takeCollateral(
            vault,
            tokenId,
            from,
            auctionId,
            maxCollateralToBuy,
            maxPrice,
            address(this)
        );

        IVault(address(vault)).exit(0, address(this), pTokenAmount);

        // redeem pTokens for `target` token
        uint256 targetAmount = divider.redeem(redeemParams.adapter, redeemParams.maturity, pTokenAmount);

        // approve the Sense Finance Adapter to transfer `target` tokens on behalf of the proxy
        if (redeemParams.approveTarget != 0) {
            // reset the allowance if it's currently non-zero
            if (IERC20(redeemParams.target).allowance(address(this), redeemParams.adapter) != 0){
                IERC20(redeemParams.target).safeApprove(redeemParams.adapter, 0);    
            }
            
            IERC20(redeemParams.target).safeApprove(redeemParams.adapter, redeemParams.approveTarget);
        }
        // unwrap `target` token for underlier
        uint256 underlierAmount = IAdapter(redeemParams.adapter).unwrapTarget(targetAmount);

        // send underlier to recipient
        IERC20(redeemParams.underlierToken).safeTransfer(recipient, underlierAmount);
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
    /// @param swapParams Sense swap params
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
        uint256 pTokenAmount = takeCollateral(
            vault,
            tokenId,
            from,
            auctionId,
            maxCollateralToBuy,
            maxPrice,
            address(this)
        );

        IVault(address(vault)).exit(0, address(this), pTokenAmount);
        
        // sell pToken according to `swapParams`
        // approve Sense Finance Periphery to transfer pTokens on behalf of the proxy
        if (swapParams.approve != 0) {
            if (IERC20(swapParams.assetIn).allowance(address(this), address(periphery)) != 0){
                IERC20(swapParams.assetIn).safeApprove(address(periphery), 0);
            }

            IERC20(swapParams.assetIn).safeApprove(address(periphery), swapParams.approve);
        }

        uint256 underlier = periphery.swapPTsForUnderlying(
            swapParams.adapter,
            swapParams.maturity,
            pTokenAmount,
            swapParams.minAccepted
        );

        // send underlier to recipient
        IERC20(swapParams.assetOut).safeTransfer(recipient, underlier);
    }
}
