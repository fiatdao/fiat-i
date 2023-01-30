// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {NoLossCollateralAuctionActionsBase} from "./NoLossCollateralAuctionActionsBase.sol";
import {IBalancerVault} from "../helper/ConvergentCurvePoolHelper.sol";
import {IVault} from "../../interfaces/IVault.sol";
import {ITranche} from "../vault/VaultEPTActions.sol";
import {WAD, toInt256, sub, mul, div, wmul, wdiv} from "../../core/utils/Math.sol";

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// WARNING: These functions meant to be used as a a library for a PRBProxy. Some are unsafe if you call them directly.
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

/// @title NoLossCollateralAuctionActions
/// @notice A set of actions for buying and redeeming collateral from NoLossCollateralAuction
contract NoLossCollateralAuctionEPTActions is NoLossCollateralAuctionActionsBase {
    using SafeERC20 for IERC20;

    /// ======== Types ======== ///

    // Swap data
    struct SwapParams {
        // Address of the Balancer Vault
        address balancerVault;
        // Id of the Element Convergent Curve Pool containing the collateral token
        bytes32 poolId;
        // Underlier token address when adding collateral and `collateral` when removing
        address assetIn;
        // Collateral token address when adding collateral and `underlier` when removing
        address assetOut;
        // Min. amount of tokens we would accept to receive from the swap, whether it is collateral or underlier
        uint256 minOutput;
        // Timestamp at which swap must be confirmed by [seconds]
        uint256 deadline;
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

        // redeem pToken for underlier
        ITranche(IVault(vault).token()).withdrawPrincipal(pTokenAmount, recipient);
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
    /// @param swapParams Element swap params
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
        _sellPToken(pTokenAmount, recipient, swapParams);
    }

    function _sellPToken(
        uint256 pTokenAmount,
        address to,
        SwapParams calldata swapParams
    ) internal returns (uint256) {
        IBalancerVault.SingleSwap memory singleSwap = IBalancerVault.SingleSwap(
            swapParams.poolId,
            IBalancerVault.SwapKind.GIVEN_IN,
            swapParams.assetIn,
            swapParams.assetOut,
            pTokenAmount,
            new bytes(0)
        );
        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement(
            address(this),
            false,
            payable(to),
            false
        );

        IERC20(swapParams.assetIn).approve(swapParams.balancerVault, pTokenAmount);
        

        // kind == `GIVE_IN` use `minOutput` as `limit` to enforce min. amount of underliers to receive
        return IBalancerVault(swapParams.balancerVault).swap(
            singleSwap, funds, swapParams.minOutput, swapParams.deadline
        );
    }
}
