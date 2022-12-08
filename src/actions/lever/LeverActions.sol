// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICodex} from "../../interfaces/ICodex.sol";
import {IVault} from "../../interfaces/IVault.sol";
import {IMoneta} from "../../interfaces/IMoneta.sol";
import {IFIAT} from "../../interfaces/IFIAT.sol";
import {IFlash, ICreditFlashBorrower, IERC3156FlashBorrower} from "../../interfaces/IFlash.sol";
import {IPublican} from "../../interfaces/IPublican.sol";
import {WAD, toInt256, add, wmul, wdiv, sub} from "../../core/utils/Math.sol";

import {IBalancerVault, IAsset} from "../helper/ConvergentCurvePoolHelper.sol";

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// WARNING: These functions meant to be used as a a library for a PRBProxy. Some are unsafe if you call them directly.
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

/// @title LeverActions
/// @notice
abstract contract LeverActions {
    /// ======== Custom Errors ======== ///

    error LeverActions__exitMoneta_zeroUserAddress();

    /// ======== Storage ======== ///

    struct FlashLoanData {
        // Action to perform in the flash loan callback [1 - buy, 2 - sell, 3 - redeem]
        uint256 action;
        // Data corresponding to the action
        bytes data;
    }

    struct SellFIATSwapParams {
        // Batch Swap
        IBalancerVault.BatchSwapStep[] swaps;
        // IAssets for Batch Swap, assets array has to be in swap order FIAT => B => underlier (FIAT index field can be left empty)
        IAsset[] assets;
        // An array of maximum amounts of each asset to be transferred. For token going into the Vault (+), for tokens going out of the Vault (-)
        int256[] limits;
        // Timestamp at which swap must be confirmed by [seconds]
        uint256 deadline;
    }

    struct BuyFIATSwapParams {
        // Batch Swap
        IBalancerVault.BatchSwapStep[] swaps;
        // IAssets for Batch Swap, assets array has to be in swap order underlier => B => FIAT  (FIAT index field can be left empty)
        IAsset[] assets;
        // An array of maximum amounts of each asset to be transferred. For token going into the Vault (+), for tokens going out of the Vault (-)
        int256[] limits;
        // Timestamp at which swap must be confirmed by [seconds]
        uint256 deadline;
    }

    /// @notice Codex
    ICodex public immutable codex;
    /// @notice FIAT token
    IFIAT public immutable fiat;
    /// @notice Flash
    IFlash public immutable flash;
    /// @notice Moneta
    IMoneta public immutable moneta;
    /// @notice Publican
    IPublican public immutable publican;

    address internal immutable self = address(this);

    // FIAT - DAI - USDC Balancer Pool
    bytes32 public immutable fiatPoolId;
    address public immutable fiatBalancerVault;

    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    bytes32 public constant CALLBACK_SUCCESS_CREDIT = keccak256("CreditFlashBorrower.onCreditFlashLoan");

    constructor(
        address codex_,
        address fiat_,
        address flash_,
        address moneta_,
        address publican_,
        bytes32 fiatPoolId_,
        address fiatBalancerVault_
    ) {
        codex = ICodex(codex_);
        fiat = IFIAT(fiat_);
        flash = IFlash(flash_);
        moneta = IMoneta(moneta_);
        publican = IPublican(publican_);
        fiatPoolId = fiatPoolId_;
        fiatBalancerVault = fiatBalancerVault_;

        (address[] memory tokens, , ) = IBalancerVault(fiatBalancerVault_).getPoolTokens(fiatPoolId);
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).approve(fiatBalancerVault_, type(uint256).max);
        }

        fiat.approve(moneta_, type(uint256).max);
    }

    /// @notice Sets `amount` as the allowance of `spender` over the UserProxy's FIAT
    /// @param spender Address of the spender
    /// @param amount Amount of tokens to approve [wad]
    function approveFIAT(address spender, uint256 amount) external {
        fiat.approve(spender, amount);
    }

    /// @dev Redeems FIAT for internal credit
    /// @param to Address of the recipient
    /// @param amount Amount of FIAT to exit [wad]
    function exitMoneta(address to, uint256 amount) public {
        if (to == address(0)) revert LeverActions__exitMoneta_zeroUserAddress();

        // proxy needs to delegate ability to transfer internal credit on its behalf to Moneta first
        if (codex.delegates(address(this), address(moneta)) != 1) codex.grantDelegate(address(moneta));

        moneta.exit(to, amount);
    }

    /// @dev The user needs to previously call approveFIAT with the address of Moneta as the spender
    /// @param from Address of the account which provides FIAT
    /// @param amount Amount of FIAT to enter [wad]
    function enterMoneta(address from, uint256 amount) public {
        // if `from` is set to an external address then transfer amount to the proxy first
        // requires `from` to have set an allowance for the proxy
        if (from != address(0) && from != address(this)) fiat.transferFrom(from, address(this), amount);

        moneta.enter(address(this), amount);
    }

    /// @notice Deposits `amount` of `token` with `tokenId` from `from` into the `vault`
    /// @dev Virtual method to be implement in token specific UserAction contracts
    function enterVault(
        address vault,
        address token,
        uint256 tokenId,
        address from,
        uint256 amount
    ) public virtual;

    /// @notice Withdraws `amount` of `token` with `tokenId` to `to` from the `vault`
    /// @dev Virtual method to be implement in token specific UserAction contracts
    function exitVault(
        address vault,
        address token,
        uint256 tokenId,
        address to,
        uint256 amount
    ) public virtual;

    function addCollateralAndDebt(
        address vault,
        address token,
        uint256 tokenId,
        address position,
        address collateralizer,
        address creditor,
        uint256 addCollateral,
        uint256 addDebt
    ) public {
        // update the interest rate accumulator in Codex for the vault
        if (addDebt != 0) publican.collect(vault);

        // transfer tokens to be used as collateral into Vault
        enterVault(vault, token, tokenId, collateralizer, wmul(uint256(addCollateral), IVault(vault).tokenScale()));

        // compute normal debt and compensate for precision error caused by wdiv
        (, uint256 rate, , ) = codex.vaults(vault);
        uint256 deltaNormalDebt = wdiv(addDebt, rate);
        if (wmul(deltaNormalDebt, rate) < addDebt) deltaNormalDebt = add(deltaNormalDebt, uint256(1));

        // update collateral and debt balances
        codex.modifyCollateralAndDebt(
            vault,
            tokenId,
            position,
            address(this),
            address(this),
            toInt256(addCollateral),
            toInt256(deltaNormalDebt)
        );

        // redeem newly generated internal credit for FIAT
        exitMoneta(creditor, addDebt);
    }

    function subCollateralAndDebt(
        address vault,
        address token,
        uint256 tokenId,
        address position,
        address collateralizer,
        uint256 subCollateral,
        uint256 subNormalDebt
    ) public {
        // update collateral and debt balanaces
        codex.modifyCollateralAndDebt(
            vault,
            tokenId,
            position,
            address(this),
            address(this),
            -toInt256(subCollateral),
            -toInt256(subNormalDebt)
        );

        // withdraw tokens not be used as collateral anymore from Vault
        exitVault(vault, token, tokenId, collateralizer, wmul(subCollateral, IVault(vault).tokenScale()));
    }

    function _sellFIATExactIn(SellFIATSwapParams memory params, uint256 exactAmountIn) internal returns (uint256) {
        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement(
            address(this),
            false,
            payable(address(this)),
            false
        );
        // Set FIAT exact amount In
        params.swaps[0].amount = exactAmountIn;
        params.assets[0] = IAsset(address(fiat));

        // BatchSwap
        int256[] memory deltas = IBalancerVault(fiatBalancerVault).batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN,
            params.swaps,
            params.assets,
            funds,
            params.limits,
            params.deadline
        );

        // Vault deltas are in the same order as Assets, underlier is the last one, return the absolut value
        return abs(deltas[params.assets.length - 1]);
    }

    function _buyFIATExactOut(BuyFIATSwapParams memory params, uint256 exactAmountOut)
        internal
        returns (uint256, address)
    {
        IBalancerVault.FundManagement memory funds = IBalancerVault.FundManagement(
            address(this),
            false,
            payable(address(this)),
            false
        );
        // Set FIAT exact amount Out
        params.swaps[0].amount = exactAmountOut;
        params.assets[params.assets.length-1] = IAsset(address(fiat));
        
        // BatchSwap
        int256[] memory deltas = IBalancerVault(fiatBalancerVault).batchSwap(
            IBalancerVault.SwapKind.GIVEN_OUT,
            params.swaps,
            params.assets,
            funds,
            params.limits,
            params.deadline
        );

        // Vault deltas are in the same order as Assets, underlier is the first
        return (abs(deltas[0]), address(params.assets[0]));
    }

    struct BatchSwap {
        bytes32 poolId;
        address asset; // assetOut when fiatInToUnderlier, assetIn when underlierToFiat
    }

    /// @notice Returns an amount of underlier for a given amount of FIAT
    /// @param amountIn FIAT amount In
    /// @param path Swap path from FIAT to the underlier (excluding FIAT) (e.g. FIAT => B => C => Underlier)
    /// @return underlierAmount Amount of underlier 
    function fiatInToUnderlier(
        uint256 amountIn, 
        BatchSwap[] memory path
    ) external returns (uint256) {
        IBalancerVault.FundManagement memory funds;
        IBalancerVault.BatchSwapStep[] memory balSwaps = new IBalancerVault.BatchSwapStep[](path.length);
        IAsset[] memory assets = new IAsset[](path.length+1);

        assets[0] =  IAsset(address(fiat));

        for (uint i=0; i< path.length;++i){
            IBalancerVault.BatchSwapStep memory swap = IBalancerVault.BatchSwapStep(path[i].poolId,i,i+1,0,new bytes(0));
            balSwaps[i] =swap;
            assets[i+1] = IAsset(address(path[i].asset));
        }
        
        balSwaps[0].amount = amountIn;
        
        int256[] memory assetDeltas = IBalancerVault(fiatBalancerVault).queryBatchSwap(
            IBalancerVault.SwapKind.GIVEN_IN,
            balSwaps,
            assets,
            funds
        );

        // Underlier is the last one
        return abs(assetDeltas[assetDeltas.length-1]);
    }
    
    /// @notice Returns an amount of underlier for a given amount of FIAT
    /// @param amountOut FIAT amount we want to receive
    /// @param path Swap path from underlier to FIAT (excluding FIAT) (e.g. Underlier => C => B => FIAT)
    /// @return underlierAmount Amount of underlier 
    function underlierToFiatOut(
        uint256 amountOut, 
        BatchSwap[] memory path
    ) external returns (uint256) {
        uint pathLength = path.length;

        IBalancerVault.FundManagement memory funds;
        IBalancerVault.BatchSwapStep[] memory balSwaps = new IBalancerVault.BatchSwapStep[](pathLength);
        IAsset[] memory assets = new IAsset[](pathLength+1);

        assets[pathLength] =  IAsset(address(fiat));

        for (uint i= 0; i<path.length;++i){
            IBalancerVault.BatchSwapStep memory swap = IBalancerVault.BatchSwapStep(path[i].poolId,pathLength-1,pathLength,0,new bytes(0));
            balSwaps[i] =swap;
            assets[i] = IAsset(address(path[i].asset));
            pathLength--;
        }
        
        balSwaps[0].amount = amountOut;
        
        int256[] memory assetDeltas = IBalancerVault(fiatBalancerVault).queryBatchSwap(
            IBalancerVault.SwapKind.GIVEN_OUT,
            balSwaps,
            assets,
            funds
        );
        // underlier is the first one
        return abs(assetDeltas[0]);
    }

    /**
     * @dev Returns the absolute value of a signed integer.
     */
    function abs(int256 a) internal pure returns (uint256 result) {
        result = a > 0 ? uint256(a) : uint256(-a);
    }
}
