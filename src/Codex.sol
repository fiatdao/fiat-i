// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2018 Rain <rainbreak@riseup.net>
pragma solidity ^0.8.4;

import {ICodex} from "./interfaces/ICodex.sol";
import {IVault} from "./interfaces/IVault.sol";

import {Guarded} from "./utils/Guarded.sol";
import {WAD, add, sub, wmul} from "./utils/Math.sol";

/// @title Codex
/// @notice `Codex` is responsible for the accounting of collateral and debt balances
/// Uses Vat.sol from DSS (MakerDAO) / SafeEngine.sol from GEB (Reflexer Labs) as a blueprint
/// Changes from Vat.sol / SafeEngine.sol:
/// - only WAD precision is used (no RAD and RAY)
/// - uses a method signature based authentication scheme
/// - supports ERC1155, ERC721 style assets by TokenId
contract Codex is Guarded, ICodex {
    /// ======== Custom Errors ======== ///

    error Codex__init_vaultAlreadyInit();
    error Codex__setParam_notLive();
    error Codex__setParam_unrecognizedParam();
    error Codex__transferBalance_notAllowed();
    error Codex__transferCredit_notAllowed();
    error Codex__modifyCollateralAndDebt_notLive();
    error Codex__modifyCollateralAndDebt_vaultNotInit();
    error Codex__modifyCollateralAndDebt_ceilingExceeded();
    error Codex__modifyCollateralAndDebt_notSafe();
    error Codex__modifyCollateralAndDebt_notAllowedSender();
    error Codex__modifyCollateralAndDebt_notAllowedCollateralizer();
    error Codex__modifyCollateralAndDebt_notAllowedDebtor();
    error Codex__modifyCollateralAndDebt_debtFloor();
    error Codex__transferCollateralAndDebt_notAllowed();
    error Codex__transferCollateralAndDebt_notSafeSrc();
    error Codex__transferCollateralAndDebt_notSafeDst();
    error Codex__transferCollateralAndDebt_debtFloorSrc();
    error Codex__transferCollateralAndDebt_debtFloorDst();
    error Codex__modifyRate_notLive();

    /// ======== Storage ======== ///

    // Vault Data
    struct Vault {
        // Total Normalised Debt in Vault [wad]
        uint256 totalNormalDebt;
        // Vault's Accumulation Rate [wad]
        uint256 rate;
        // Vault's Debt Ceiling [wad]
        uint256 debtCeiling;
        // Debt Floor for Positions corresponding to this Vault [wad]
        uint256 debtFloor;
    }
    // Position Data
    struct Position {
        // Locked Collateral in Position [wad]
        uint256 collateral;
        // Normalised Debt (gross debt before rate is applied) generated by Position [wad]
        uint256 normalDebt;
    }

    /// @notice Map of delegatees who can modify collateral, debt and credit on behalf of a delegator
    /// @dev Delegator => Delegatee => hasDelegate
    mapping(address => mapping(address => uint256)) public override delegates;
    /// @notice Vaults
    /// @dev Vault => Vault Data
    mapping(address => Vault) public override vaults;
    /// @notice Positions
    /// @dev Vault => TokenId => Owner => Position
    mapping(address => mapping(uint256 => mapping(address => Position))) public override positions;
    /// @notice Token balances not put up for collateral in a Position
    /// @dev Vault => TokenId => Owner => Balance [wad]
    mapping(address => mapping(uint256 => mapping(address => uint256))) public override balances;
    /// @notice Credit balances
    /// @dev Account => Credit [wad]
    mapping(address => uint256) public override credit;
    /// @notice Unbacked Debt balances
    /// @dev Account => Unbacked Debt [wad]
    mapping(address => uint256) public override unbackedDebt;

    /// @notice Global Debt (incl. rate) outstanding == Credit Issued [wad]
    uint256 public override globalDebt;
    /// @notice Global Unbacked Debt (incl. rate) oustanding == Total Credit [wad]
    uint256 public override globalUnbackedDebt;
    /// @notice Global Debt Ceiling [wad]
    uint256 public override globalDebtCeiling;

    /// @notice Boolean indicating if this contract is live (0 - not live, 1 - live)
    uint256 public live;

    /// ======== Events ======== ///
    event Init(address indexed vault);
    event SetParam(address indexed vault, bytes32 indexed param, uint256 data);
    event GrantDelegate(address indexed delegator, address indexed delegatee);
    event RevokeDelegate(address indexed delegator, address indexed delegatee);
    event ModifyBalance(
        address indexed vault,
        uint256 indexed tokenId,
        address indexed user,
        int256 amount,
        uint256 balance
    );
    event TransferBalance(
        address indexed vault,
        uint256 indexed tokenId,
        address indexed src,
        address dst,
        uint256 amount,
        uint256 srcBalance,
        uint256 dstBalance
    );
    event TransferCredit(
        address indexed src,
        address indexed dst,
        uint256 amount,
        uint256 srcCredit,
        uint256 dstCredit
    );
    event ModifyCollateralAndDebt(
        address indexed vault,
        uint256 indexed tokenId,
        address indexed user,
        address collateralizer,
        address creditor,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    );
    event TransferCollateralAndDebt(
        address indexed vault,
        uint256 indexed tokenId,
        address indexed src,
        address dst,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    );
    event ConfiscateCollateralAndDebt(
        address indexed vault,
        uint256 indexed tokenId,
        address indexed user,
        address collateralizer,
        address debtor,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    );
    event SettleUnbackedDebt(address indexed debtor, uint256 debt);
    event CreateUnbackedDebt(address indexed debtor, address indexed creditor, uint256 debt);
    event ModifyRate(address indexed vault, address indexed creditor, int256 deltaRate);
    event Lock();

    constructor() Guarded() {
        live = 1;
    }

    /// ======== Configuration ======== ///

    /// @notice Initializes a new Vault
    /// @dev Sender has to be allowed to call this method
    /// @param vault Address of the Vault
    function init(address vault) external override checkCaller {
        if (vaults[vault].rate != 0) revert Codex__init_vaultAlreadyInit();
        vaults[vault].rate = WAD;
        emit Init(vault);
    }

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(bytes32 param, uint256 data) external override checkCaller {
        if (live == 0) revert Codex__setParam_notLive();
        if (param == "globalDebtCeiling") globalDebtCeiling = data;
        else revert Codex__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// @notice Sets various variables for a Vault
    /// @dev Sender has to be allowed to call this method
    /// @param vault Address of the Vault
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(
        address vault,
        bytes32 param,
        uint256 data
    ) external override checkCaller {
        if (live == 0) revert Codex__setParam_notLive();
        if (param == "debtCeiling") vaults[vault].debtCeiling = data;
        else if (param == "debtFloor") vaults[vault].debtFloor = data;
        else revert Codex__setParam_unrecognizedParam();
        emit SetParam(vault, param, data);
    }

    /// ======== Caller Delegation ======== ///

    /// @notice Grants the delegatee the ability to modify collateral, debt and credit balances on behalf of the caller
    /// @param delegatee Address of the delegatee
    function grantDelegate(address delegatee) external override {
        delegates[msg.sender][delegatee] = 1;
        emit GrantDelegate(msg.sender, delegatee);
    }

    /// @notice Revokes the delegatee's ability to modify collateral, debt and credit balances on behalf of the caller
    /// @param delegatee Address of the delegatee
    function revokeDelegate(address delegatee) external override {
        delegates[msg.sender][delegatee] = 0;
        emit RevokeDelegate(msg.sender, delegatee);
    }

    /// @notice Checks the delegate
    /// @param delegator Address of the delegator
    /// @param delegatee Address of the delegatee
    /// @return True if delegate is granted
    function hasDelegate(address delegator, address delegatee) internal view returns (bool) {
        return delegator == delegatee || delegates[delegator][delegatee] == 1;
    }

    /// ======== Credit and Token Balance Administration ======== ///

    /// @notice Updates the token balance for a `user`
    /// @dev Sender has to be allowed to call this method
    /// @param vault Address of the Vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param user Address of the user
    /// @param amount Amount to add (positive) or subtract (negative) [wad]
    function modifyBalance(
        address vault,
        uint256 tokenId,
        address user,
        int256 amount
    ) external override checkCaller {
        balances[vault][tokenId][user] = add(balances[vault][tokenId][user], amount);
        emit ModifyBalance(vault, tokenId, user, amount, balances[vault][tokenId][user]);
    }

    /// @notice Transfer an `amount` of tokens from `src` to `dst`
    /// @dev Sender has to be delegated by `src`
    /// @param vault Address of the Vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param src From address
    /// @param dst To address
    /// @param amount Amount to be transferred [wad]
    function transferBalance(
        address vault,
        uint256 tokenId,
        address src,
        address dst,
        uint256 amount
    ) external override {
        if (!hasDelegate(src, msg.sender)) revert Codex__transferBalance_notAllowed();
        balances[vault][tokenId][src] = sub(balances[vault][tokenId][src], amount);
        balances[vault][tokenId][dst] = add(balances[vault][tokenId][dst], amount);
        emit TransferBalance(
            vault,
            tokenId,
            src,
            dst,
            amount,
            balances[vault][tokenId][src],
            balances[vault][tokenId][dst]
        );
    }

    /// @notice Transfer an `amount` of Credit from `src` to `dst`
    /// @dev Sender has to be delegated by `src`
    /// @param src From address
    /// @param dst To address
    /// @param amount Amount to be transferred [wad]
    function transferCredit(
        address src,
        address dst,
        uint256 amount
    ) external override {
        if (!hasDelegate(src, msg.sender)) revert Codex__transferCredit_notAllowed();
        credit[src] = sub(credit[src], amount);
        credit[dst] = add(credit[dst], amount);
        emit TransferCredit(src, dst, amount, credit[src], credit[dst]);
    }

    /// ======== Position Administration ======== ///

    /// @notice Modifies a Position's collateral and debt balances
    /// @dev Checks that the global debt ceiling and the vault's debt ceiling have not been exceeded,
    /// that the Position is still safe after the modification,
    /// that the sender is delegated by the owner if the collateral-to-debt ratio decreased,
    /// that the sender is delegated by the collateralizer if new collateral is put up,
    /// that the sender is delegated by the creditor if debt is settled,
    /// and that the vault debt floor is exceeded
    /// @param vault Address of the Vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param user Address of the user
    /// @param collateralizer Address of who puts up or receives the collateral delta
    /// @param creditor Address of who provides or receives the credit delta for the debt delta
    /// @param deltaCollateral Amount of collateral to put up (+) for or remove (-) from this Position [wad]
    /// @param deltaNormalDebt Amount of normalized debt (gross, before rate is applied) to generate (+) or
    /// settle (-) on this Position [wad]
    function modifyCollateralAndDebt(
        address vault,
        uint256 tokenId,
        address user,
        address collateralizer,
        address creditor,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    ) external override {
        // system is live
        if (live == 0) revert Codex__modifyCollateralAndDebt_notLive();

        Position memory p = positions[vault][tokenId][user];
        Vault memory v = vaults[vault];
        // vault has been initialised
        if (v.rate == 0) revert Codex__modifyCollateralAndDebt_vaultNotInit();

        p.collateral = add(p.collateral, deltaCollateral);
        p.normalDebt = add(p.normalDebt, deltaNormalDebt);
        v.totalNormalDebt = add(v.totalNormalDebt, deltaNormalDebt);

        int256 deltaDebt = wmul(v.rate, deltaNormalDebt);
        uint256 debt = wmul(v.rate, p.normalDebt);
        globalDebt = add(globalDebt, deltaDebt);

        // either debt has decreased, or debt ceilings are not exceeded
        if (deltaNormalDebt > 0 && (wmul(v.totalNormalDebt, v.rate) > v.debtCeiling || globalDebt > globalDebtCeiling))
            revert Codex__modifyCollateralAndDebt_ceilingExceeded();
        // position is either less risky than before, or it is safe
        if (
            (deltaNormalDebt > 0 || deltaCollateral < 0) &&
            debt > wmul(p.collateral, IVault(vault).fairPrice(tokenId, true, false))
        ) revert Codex__modifyCollateralAndDebt_notSafe();

        // position is either more safe, or the owner consents
        if ((deltaNormalDebt > 0 || deltaCollateral < 0) && !hasDelegate(user, msg.sender))
            revert Codex__modifyCollateralAndDebt_notAllowedSender();
        // collateralizer consents if new collateral is put up
        if (deltaCollateral > 0 && !hasDelegate(collateralizer, msg.sender))
            revert Codex__modifyCollateralAndDebt_notAllowedCollateralizer();

        // creditor consents if debt is settled with credit
        if (deltaNormalDebt < 0 && !hasDelegate(creditor, msg.sender))
            revert Codex__modifyCollateralAndDebt_notAllowedDebtor();

        // position has no debt, or a non-dusty amount
        if (p.normalDebt != 0 && debt < v.debtFloor) revert Codex__modifyCollateralAndDebt_debtFloor();

        balances[vault][tokenId][collateralizer] = sub(balances[vault][tokenId][collateralizer], deltaCollateral);
        credit[creditor] = add(credit[creditor], deltaDebt);

        positions[vault][tokenId][user] = p;
        vaults[vault] = v;

        emit ModifyCollateralAndDebt(vault, tokenId, user, collateralizer, creditor, deltaCollateral, deltaNormalDebt);
    }

    /// @notice Transfers a Position's collateral and debt balances to another Position
    /// @dev Checks that the sender is delegated by `src` and `dst` Position owners,
    /// that the `src` and `dst` Positions are still safe after the transfer,
    /// and that the `src` and `dst` Positions' debt exceed the vault's debt floor
    /// @param vault Address of the Vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param src Address of the `src` Positions owner
    /// @param dst Address of the `dst` Positions owner
    /// @param deltaCollateral Amount of collateral to send to (+) or from (-) the `src` Position [wad]
    /// @param deltaNormalDebt Amount of normalized debt (gross, before rate is applied) to send to (+) or
    /// from (-) the `dst` Position [wad]
    function transferCollateralAndDebt(
        address vault,
        uint256 tokenId,
        address src,
        address dst,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    ) external override {
        Position storage pSrc = positions[vault][tokenId][src];
        Position storage pDst = positions[vault][tokenId][dst];
        Vault storage v = vaults[vault];

        pSrc.collateral = sub(pSrc.collateral, deltaCollateral);
        pSrc.normalDebt = sub(pSrc.normalDebt, deltaNormalDebt);
        pDst.collateral = add(pDst.collateral, deltaCollateral);
        pDst.normalDebt = add(pDst.normalDebt, deltaNormalDebt);

        uint256 debtSrc = wmul(pSrc.normalDebt, v.rate);
        uint256 debtDst = wmul(pDst.normalDebt, v.rate);

        // both sides consent
        if (!hasDelegate(src, msg.sender) || !hasDelegate(dst, msg.sender))
            revert Codex__transferCollateralAndDebt_notAllowed();

        // both sides safe
        if (debtSrc > wmul(pSrc.collateral, IVault(vault).fairPrice(tokenId, true, false)))
            revert Codex__transferCollateralAndDebt_notSafeSrc();
        if (debtDst > wmul(pDst.collateral, IVault(vault).fairPrice(tokenId, true, false)))
            revert Codex__transferCollateralAndDebt_notSafeDst();

        // both sides non-dusty
        if (pSrc.normalDebt != 0 && debtSrc < v.debtFloor) revert Codex__transferCollateralAndDebt_debtFloorSrc();
        if (pDst.normalDebt != 0 && debtDst < v.debtFloor) revert Codex__transferCollateralAndDebt_debtFloorDst();

        emit TransferCollateralAndDebt(vault, tokenId, src, dst, deltaCollateral, deltaNormalDebt);
    }

    /// @notice Confiscates a Position's collateral and debt balances
    /// @dev Sender has to be allowed to call this method
    /// @param vault Address of the Vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param user Address of the user
    /// @param collateralizer Address of who puts up or receives the collateral delta
    /// @param debtor Address of who provides or receives the debt delta
    /// @param deltaCollateral Amount of collateral to put up (+) for or remove (-) from this Position [wad]
    /// @param deltaNormalDebt Amount of normalized debt (gross, before rate is applied) to generate (+) or
    /// settle (-) on this Position [wad]
    function confiscateCollateralAndDebt(
        address vault,
        uint256 tokenId,
        address user,
        address collateralizer,
        address debtor,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    ) external override checkCaller {
        Position storage position = positions[vault][tokenId][user];
        Vault storage v = vaults[vault];

        position.collateral = add(position.collateral, deltaCollateral);
        position.normalDebt = add(position.normalDebt, deltaNormalDebt);
        v.totalNormalDebt = add(v.totalNormalDebt, deltaNormalDebt);

        int256 deltaDebt = wmul(v.rate, deltaNormalDebt);

        balances[vault][tokenId][collateralizer] = sub(balances[vault][tokenId][collateralizer], deltaCollateral);
        unbackedDebt[debtor] = sub(unbackedDebt[debtor], deltaDebt);
        globalUnbackedDebt = sub(globalUnbackedDebt, deltaDebt);

        emit ConfiscateCollateralAndDebt(
            vault,
            tokenId,
            user,
            collateralizer,
            debtor,
            deltaCollateral,
            deltaNormalDebt
        );
    }

    /// ======== Unbacked Debt ======== ///

    /// @notice Settles unbacked debt with the sender's credit
    /// @dev Reverts if the sender does not have sufficient credit available to settle the debt
    /// @param debt Amount of debt to settle [wawd]
    function settleUnbackedDebt(uint256 debt) external override {
        address debtor = msg.sender;
        unbackedDebt[debtor] = sub(unbackedDebt[debtor], debt);
        credit[debtor] = sub(credit[debtor], debt);
        globalUnbackedDebt = sub(globalUnbackedDebt, debt);
        globalDebt = sub(globalDebt, debt);
        emit SettleUnbackedDebt(debtor, debt);
    }

    /// @notice Create unbacked debt / credit
    /// @dev Sender has to be allowed to call this method
    /// @param debtor Address of the account who takes the unbacked debt
    /// @param creditor Address of the account who gets the credit
    /// @param debt Amount of unbacked debt / credit to generate [wad]
    function createUnbackedDebt(
        address debtor,
        address creditor,
        uint256 debt
    ) external override checkCaller {
        unbackedDebt[debtor] = add(unbackedDebt[debtor], debt);
        credit[creditor] = add(credit[creditor], debt);
        globalUnbackedDebt = add(globalUnbackedDebt, debt);
        globalDebt = add(globalDebt, debt);
        emit CreateUnbackedDebt(debtor, creditor, debt);
    }

    /// ======== Debt Interest Rates ======== ///

    /// @notice Updates the rate value and collects the accrued interest for a Vault
    /// @dev Sender has to be allowed to call this method
    /// @param vault Address of the vault
    /// @param creditor Address of the account who gets the accrued interest
    /// @param deltaRate Delta to increase (+) or decrease (-) the rate [percentage in wad]
    function modifyRate(
        address vault,
        address creditor,
        int256 deltaRate
    ) external override checkCaller {
        if (live == 0) revert Codex__modifyRate_notLive();
        Vault storage v = vaults[vault];
        v.rate = add(v.rate, deltaRate);
        int256 wad = wmul(v.totalNormalDebt, deltaRate);
        credit[creditor] = add(credit[creditor], wad);
        globalDebt = add(globalDebt, wad);
        emit ModifyRate(vault, creditor, deltaRate);
    }

    /// ======== Shutdown ======== ///

    /// @notice Locks the contract
    /// @dev Sender has to be allowed to call this method
    function lock() external override checkCaller {
        live = 0;
        emit Lock();
    }
}
