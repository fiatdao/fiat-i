// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC1155} from "openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {ICodex} from "../interfaces/ICodex.sol";
import {ICollybus} from "../interfaces/ICollybus.sol";
import {Guarded} from "../core/utils/Guarded.sol";
import {toInt256, add, sub, mul, div, wdiv} from "../core/utils/Math.sol";

import {IVaultFC} from "../interfaces/IVaultFC.sol";
import {Vault1155} from "./Vault.sol";

interface INotionalV2 {
    enum TokenType {
        UnderlyingToken,
        cToken,
        cETH,
        Ether,
        NonMintable
    }

    struct Token {
        address tokenAddress;
        bool hasTransferFee;
        int256 decimals;
        TokenType tokenType;
        uint256 maxCollateralBalance;
    }

    struct ETHRate {
        int256 rateDecimals;
        int256 rate;
        int256 buffer;
        int256 haircut;
        int256 liquidationDiscount;
    }

    struct AssetRateParameters {
        address rateOracle;
        int256 rate;
        int256 underlyingDecimals;
    }

    function getSettlementRate(uint16 currencyId, uint40 maturity) external view returns (AssetRateParameters memory);

    function getCurrencyAndRates(uint16 currencyId)
        external
        view
        returns (
            Token memory assetToken,
            Token memory underlyingToken,
            ETHRate memory ethRate,
            AssetRateParameters memory assetRate
        );

    function settleAccount(address account) external;

    function withdraw(
        uint16 currencyId,
        uint88 amountInternalPrecision,
        bool redeemToUnderlying
    ) external returns (uint256);
}

/// @title VaultFC (Notional fCash Vault)
/// @notice Collateral adapter for Notional fCash
/// @dev
contract VaultFC is Guarded, IVaultFC, ERC1155Holder {
    using SafeERC20 for IERC20;

    /// ======== Custom Errors ======== ///

    error VaultFC__enter_overflow();
    error VaultFC__exit_overflow();
    error VaultFC__enter_notLive();
    error VaultFC__enter_wrongCurrency();
    error VaultFC__enter_wrongTenor();
    error VaultFC__exit_wrongCurrency();
    error VaultFC__exit_wrongTenor();
    error VaultFC__setParam_notLive();
    error VaultFC__setParam_unrecognizedParam();
    error VaultFC__fairPrice_wrongCurrency();

    /// ======== Storage ======== ///

    /// @notice Codex
    ICodex public immutable override codex;
    /// @notice Price Feed
    ICollybus public override collybus;

    /// @notice Collateral token
    address public immutable override token;
    /// @notice Decimals of collateral token (fixed to 8 for fCash)
    uint256 public constant override tokenScale = 10**8;
    /// @notice Underlier of collateral token
    address public immutable override underlierToken;
    /// @notice Decimals of underlier token
    uint256 public immutable override underlierScale;

    /// @notice Notional Finance CurrencyId (1 - cETH, 2 - cDAI, 3 - cUSDC, 4 - cWBTC )
    uint256 public immutable currencyId;

    /// @notice Notional Finance Tenor [seconds]
    uint256 public immutable tenor;

    /// @notice The vault type
    bytes32 public immutable override vaultType;

    /// @notice Boolean indicating if this contract is live (0 - not live, 1 - live)
    uint256 public override live;

    /// ======== Events ======== ///

    event SetParam(bytes32 indexed param, address data);

    event Enter(uint256 indexed tokenId, address indexed user, uint256 amount);
    event Exit(uint256 indexed tokenId, address indexed user, uint256 amount);

    event Lock();

    constructor(
        address codex_,
        address collybus_,
        address notional,
        address underlierToken_,
        uint256 tenor_,
        uint256 currencyId_
    ) Guarded() {
        live = 1;
        codex = ICodex(codex_);
        collybus = ICollybus(collybus_);
        // set token to the Notional Finance monolith
        token = notional;
        // set underlier to the cToken underlier
        underlierToken = underlierToken_;
        underlierScale = 10**IERC20Metadata(underlierToken_).decimals();
        tenor = tenor_;
        currencyId = currencyId_;
        vaultType = bytes32("ERC1155:FC");
    }

    /// ======== Configuration ======== ///

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [address]
    function setParam(bytes32 param, address data) external virtual override checkCaller {
        if (live == 0) revert VaultFC__setParam_notLive();
        if (param == "collybus") collybus = ICollybus(data);
        else revert VaultFC__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// ======== Entering and Exiting Collateral ======== ///

    /// @notice Enters `amount` collateral into the system and credits it to `user`
    /// @dev Caller has to set allowance for this contract
    /// @param tokenId fCash Id (ERC1155 token id)
    /// @param user Address to whom the collateral should be credited to in Codex
    /// @param amount Amount of collateral to enter [tokenScale]
    function enter(
        uint256 tokenId,
        address user,
        uint256 amount
    ) external virtual override {
        if (live == 0) revert VaultFC__enter_notLive();
        if (currencyId != _getCurrencyId(tokenId)) revert VaultFC__enter_wrongCurrency();
        if (!_isValidTenor(tokenId)) revert VaultFC__enter_wrongTenor();
        int256 wad = toInt256(wdiv(amount, tokenScale));
        codex.modifyBalance(address(this), tokenId, user, wad);
        IERC1155(token).safeTransferFrom(msg.sender, address(this), tokenId, amount, new bytes(0));
        emit Enter(tokenId, user, amount);
    }

    /// @notice Exits `amount` collateral into the system and credits it to `user`
    /// @param tokenId fCash Id (ERC1155 token id)
    /// @param user Address to whom the collateral should be credited to
    /// @param amount Amount of collateral to exit [tokenScale]
    function exit(
        uint256 tokenId,
        address user,
        uint256 amount
    ) external virtual override {
        int256 wad = toInt256(wdiv(amount, tokenScale));
        if (currencyId != _getCurrencyId(tokenId)) revert VaultFC__exit_wrongCurrency();
        if (!_isValidTenor(tokenId)) revert VaultFC__enter_wrongTenor();
        codex.modifyBalance(address(this), tokenId, msg.sender, -wad);
        IERC1155(token).safeTransferFrom(address(this), user, tokenId, amount, new bytes(0));
        emit Exit(tokenId, user, amount);
    }

    /// @notice Exits `amount` fCash (collateral) from the system, redeems it for underliers and credits them to `user`
    /// @param tokenId fCash Id (ERC1155 token id)
    /// @param user Address to whom the collateral should be credited to
    /// @param amount Amount of collateral to exit [tokenScale]
    /// @return redeemed Redeemed amount of underliers [underlierScale]
    function redeemAndExit(
        uint256 tokenId,
        address user,
        uint256 amount
    ) external override returns (uint256 redeemed) {
        int256 wad = toInt256(wdiv(amount, tokenScale));
        if (currencyId != _getCurrencyId(tokenId)) revert VaultFC__exit_wrongCurrency();
        codex.modifyBalance(address(this), tokenId, msg.sender, -wad);

        // notionalV2.withdraw expects amount to be denominated in cTokens
        INotionalV2.AssetRateParameters memory ar = INotionalV2(token).getSettlementRate(
            uint16(currencyId),
            uint40(maturity(tokenId))
        );
        // (fCashScale * 1e10 * underlierScale) / (1e18 * underlierScale / cTokenScale)
        uint256 cTokensOwed = div(mul(mul(amount, uint256(1e10)), underlierScale), uint256(ar.rate));
        // withdraw underlier for fCash
        redeemed = INotionalV2(token).withdraw(uint16(currencyId), uint88(cTokensOwed), true);

        // transfer underlier token to user
        IERC20(underlierToken).safeTransfer(user, redeemed);

        emit Exit(tokenId, user, amount);
    }

    /// @notice Returns the redeemable amount of underlier tokens for a given amount of fCash
    /// @dev If cTokenExRate is 0, it fetches the last cached rate from Notional / Compound which may be outdated
    /// This method is not intended to be executed on-chain
    /// @param tokenId fCash Id (ERC1155 token id)
    /// @param amount Amount of fCash to redeem [tokenScale]
    /// @param cTokenExRate Current exchange rate from cToken to underlier (opt.) [1e18 * underlierScale / cTokenScale]
    /// @return Redeemable underlier amount [underlierScale]
    function redeems(
        uint256 tokenId,
        uint256 amount,
        uint256 cTokenExRate
    ) external view override returns (uint256) {
        INotionalV2.AssetRateParameters memory ar = INotionalV2(token).getSettlementRate(
            uint16(currencyId),
            uint40(maturity(tokenId))
        );

        // (fCashScale * 1e10 * underlierScale) / (1e18 * underlierScale / cTokenScale)
        uint256 cTokensOwed = div(mul(mul(amount, uint256(1e10)), underlierScale), uint256(ar.rate));
        // convert cTokensOwed into the current underlier amount
        if (cTokenExRate == 0) {
            (, , , INotionalV2.AssetRateParameters memory arCurrent) = INotionalV2(token).getCurrencyAndRates(
                uint16(currencyId)
            );
            cTokenExRate = uint256(arCurrent.rate);
        }
        // (cTokenScale * (1e18 * underlierScale / cTokenScale)) / (1e10 * cTokenScale)
        return div(mul(cTokensOwed, uint256(cTokenExRate)), uint256(1e18));
    }

    /// ======== Collateral Asset ======== ///

    /// @notice Returns the maturity or a given tokenId
    /// @param tokenId fCash Id (ERC1155 token id)
    /// @return maturity [seconds]
    function maturity(uint256 tokenId) public pure override returns (uint256) {
        return uint40(tokenId >> 8);
    }

    function _isValidTenor(uint256 tokenId) internal view returns (bool) {
        uint256 referenceTime = sub(block.timestamp, (block.timestamp % tenor));
        return (maturity(tokenId) == add(referenceTime, tenor));
    }

    function _getCurrencyId(uint256 tokenId) internal pure returns (uint256) {
        return uint16(tokenId >> 48);
    }

    /// ======== Valuing Collateral ======== ///

    /// @notice Returns the fair price of a single collateral unit
    /// @param tokenId fCash Id (ERC1155 token id)
    /// @param net Boolean indicating whether the liquidation safety margin should be applied to the fair value
    /// @param face Boolean indicating whether the current fair value or the fair value at maturity should be returned
    /// @return fair price [wad]
    function fairPrice(
        uint256 tokenId,
        bool net,
        bool face
    ) external view override returns (uint256) {
        if (currencyId != _getCurrencyId(tokenId)) revert VaultFC__fairPrice_wrongCurrency();
        return
            ICollybus(collybus).read(
                address(this),
                underlierToken,
                tokenId,
                (face) ? block.timestamp : maturity(tokenId),
                net
            );
    }

    /// ======== Shutdown ======== ///

    /// @notice Locks the contract
    /// @dev Sender has to be allowed to call this method
    function lock() external virtual override checkCaller {
        live = 0;
        emit Lock();
    }
}
