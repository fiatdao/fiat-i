// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2018 Rain <rainbreak@riseup.net>
// Copyright (C) 2018 Lev Livnev <lev@liv.nev.org.uk>
// Copyright (C) 2020-2021 Maker Ecosystem Growth Holdings, INC.
pragma solidity ^0.8.4;

import {ICodex} from "../interfaces/ICodex.sol";
import {ICollateralAuction} from "../interfaces/ICollateralAuction.sol";
import {ICollybus} from "../interfaces/ICollybus.sol";
import {IAer} from "../interfaces/IAer.sol";
import {ILimes} from "../interfaces/ILimes.sol";
import {ITenebrae} from "../interfaces/ITenebrae.sol";
import {IVault} from "../interfaces/IVault.sol";

import {Guarded} from "./utils/Guarded.sol";
import {WAD, min, add, sub, wmul, wdiv} from "./utils/Math.sol";

/// @title Tenebrae
/// @notice `Tenebrae` coordinates Global Settlement. This is an involved, stateful process that takes
/// place over nine steps.
///
/// Uses End.sol from DSS (MakerDAO) / GlobalSettlement SafeEngine.sol from GEB (Reflexer Labs) as a blueprint
/// Changes from End.sol / GlobalSettlement.sol:
/// - only WAD precision is used (no RAD and RAY)
/// - uses a method signature based authentication scheme
/// - supports ERC1155, ERC721 style assets by TokenId
///
/// @dev
/// First we freeze the system and lock the prices for each vault and TokenId.
///
/// 1. `lock()`:
///     - freezes user entrypoints
///     - cancels debtAuction/surplusAuction auctions
///     - starts cooldown period
///
/// We must process some system state before it is possible to calculate
/// the final credit / collateral price. In particular, we need to determine
///
///     a. `debt`, the outstanding credit supply after including system surplus / deficit
///
///     b. `lostCollateral`, the collateral shortfall per collateral type by
///     considering under-collateralised Positions.
///
/// We determine (a) by processing ongoing credit generating processes,
/// i.e. auctions. We need to ensure that auctions will not generate any
/// further credit income.
///
/// In the case of the Dutch Auctions model (CollateralAuction) they keep recovering
/// debt during the whole lifetime and there isn't a max duration time
/// guaranteed for the auction to end.
/// So the way to ensure the protocol will not receive extra credit income is:
///
///     2a. i) `skipAuctions`: cancel all ongoing auctions and seize the collateral.
///
///         `skipAuctions(vault, id)`:
///          - cancel individual running collateralAuction auctions
///          - retrieves remaining collateral and debt (including penalty) to owner's Position
///
/// We determine (b) by processing all under-collateralised Positions with `offsetPosition`:
///
/// 3. `offsetPosition(vault, tokenId, position)`:
///     - cancels the Position's debt with an equal amount of collateral
///
/// When a Position has been processed and has no debt remaining, the
/// remaining collateral can be removed.
///
/// 4. `closePosition(vault)`:
///     - remove collateral from the caller's Position
///     - owner can call as needed
///
/// After the processing period has elapsed, we enable calculation of
/// the final price for each collateral type.
///
/// 5. `fixGlobalDebt()`:
///     - only callable after processing time period elapsed
///     - assumption that all under-collateralised Positions are processed
///     - fixes the total outstanding supply of credit
///     - may also require extra Position processing to cover aer surplus
///
/// At this point we have computed the final price for each collateral
/// type and credit holders can now turn their credit into collateral. Each
/// unit credit can claim a fixed basket of collateral.
///
/// Finally, collateral can be obtained with `redeem`.
///
/// 6. `redeem(vault, tokenId wad)`:
///     - exchange some credit for collateral tokens from a specific vault and tokenId
contract Tenebrae is Guarded, ITenebrae {
    /// ======== Custom Errors ======== ///

    error Tenebrae__setParam_notLive();
    error Tenebrae__setParam_unknownParam();
    error Tenebrae__lock_notLive();
    error Tenebrae__skipAuction_debtNotZero();
    error Tenebrae__skipAuction_overflow();
    error Tenebrae__offsetPosition_debtNotZero();
    error Tenebrae__offsetPosition_overflow();
    error Tenebrae__closePosition_stillLive();
    error Tenebrae__closePosition_debtNotZero();
    error Tenebrae__closePosition_normalDebtNotZero();
    error Tenebrae__closePosition_overflow();
    error Tenebrae__fixGlobalDebt_stillLive();
    error Tenebrae__fixGlobalDebt_debtNotZero();
    error Tenebrae__fixGlobalDebt_surplusNotZero();
    error Tenebrae__fixGlobalDebt_cooldownNotFinished();
    error Tenebrae__redeem_redemptionPriceZero();

    /// ======== Storage ======== ///

    /// @notice Codex
    ICodex public override codex;
    /// @notice Limes
    ILimes public override limes;
    /// @notice Aer
    IAer public override aer;
    /// @notice Collybus
    ICollybus public override collybus;

    /// @notice Time of lock [unix epoch time]
    uint256 public override lockedAt;
    /// @notice  // Processing Cooldown Length [seconds]
    uint256 public override cooldownDuration;
    /// @notice Total outstanding credit after processing all positions and auctions [wad]
    uint256 public override debt;

    /// @notice Boolean indicating if this contract is live (0 - not live, 1 - live)
    uint256 public override live;

    /// @notice Total collateral shortfall for each asset
    /// @dev Vault => TokenId => Collateral shortfall [wad]
    mapping(address => mapping(uint256 => uint256)) public override lostCollateral;
    /// @notice Total normalized debt for each asset
    /// @dev Vault => TokenId => Total debt per vault [wad]
    mapping(address => mapping(uint256 => uint256)) public override normalDebtByTokenId;
    /// @notice Amount of collateral claimed by users
    /// @dev Vault => TokenId => Account => Collateral claimed [wad]
    mapping(address => mapping(uint256 => mapping(address => uint256))) public override claimed;

    /// ======== Events ======== ///

    event SetParam(bytes32 indexed param, uint256 data);
    event SetParam(bytes32 indexed param, address data);

    event Lock();
    event SkipAuction(
        uint256 indexed auctionId,
        address vault,
        uint256 tokenId,
        address indexed user,
        uint256 debt,
        uint256 collateralToSell,
        uint256 normalDebt
    );
    event SettlePosition(
        address indexed vault,
        uint256 indexed tokenId,
        address indexed user,
        uint256 settledCollateral,
        uint256 normalDebt
    );
    event ClosePosition(
        address indexed vault,
        uint256 indexed tokenId,
        address indexed user,
        uint256 collateral,
        uint256 normalDebt
    );
    event FixGlobalDebt();
    event Redeem(address indexed vault, uint256 indexed tokenId, address indexed user, uint256 credit);

    constructor() Guarded() {
        live = 1;
    }

    /// ======== Configuration ======== ///

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [address]
    function setParam(bytes32 param, address data) external override checkCaller {
        if (live == 0) revert Tenebrae__setParam_notLive();
        if (param == "codex") codex = ICodex(data);
        else if (param == "limes") limes = ILimes(data);
        else if (param == "aer") aer = IAer(data);
        else if (param == "collybus") collybus = ICollybus(data);
        else revert Tenebrae__setParam_unknownParam();
        emit SetParam(param, data);
    }

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(bytes32 param, uint256 data) external override checkCaller {
        if (live == 0) revert Tenebrae__setParam_notLive();
        if (param == "cooldownDuration") cooldownDuration = data;
        else revert Tenebrae__setParam_unknownParam();
        emit SetParam(param, data);
    }

    /// ======== Shutdown ======== ///

    /// @notice Returns the price fixed when the system got locked
    /// @dev Fair price remains fixed since no new rates or spot prices are submitted to Collybus
    /// @param vault Address of the Vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @return lockPrice [wad]
    function lockPrice(address vault, uint256 tokenId) public view override returns (uint256) {
        return wdiv(collybus.redemptionPrice(), IVault(vault).fairPrice(tokenId, false, true));
    }

    /// @notice Returns the price at which credit can be redeemed for collateral
    /// @notice vault Address of the Vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @return redemptionPrice [wad]
    function redemptionPrice(address vault, uint256 tokenId) public view override returns (uint256) {
        if (debt == 0) return 0;
        (, uint256 rate, , ) = codex.vaults(vault);
        uint256 collateral = wmul(wmul(normalDebtByTokenId[vault][tokenId], rate), lockPrice(vault, tokenId));
        return wdiv(sub(collateral, lostCollateral[vault][tokenId]), wmul(debt, WAD));
    }

    /// @notice Locks the system. See 1.
    /// @dev Sender has to be allowed to call this method
    function lock() external override checkCaller {
        if (live == 0) revert Tenebrae__lock_notLive();
        live = 0;
        lockedAt = block.timestamp;
        codex.lock();
        limes.lock();
        aer.lock();
        collybus.lock();
        emit Lock();
    }

    /// @notice Skips on-going collateral auction. See 2.
    /// @dev Has to be performed before global debt is fixed
    /// @param vault Address of the Vault
    /// @param auctionId Id of the collateral auction the skip
    function skipAuction(address vault, uint256 auctionId) external override {
        if (debt != 0) revert Tenebrae__skipAuction_debtNotZero();
        (address _collateralAuction, , , ) = limes.vaults(vault);
        ICollateralAuction collateralAuction = ICollateralAuction(_collateralAuction);
        (, uint256 rate, , ) = codex.vaults(vault);
        (, uint256 debt_, uint256 collateralToSell, , uint256 tokenId, address user, , ) = collateralAuction.auctions(
            auctionId
        );
        codex.createUnbackedDebt(address(aer), address(aer), debt_);
        collateralAuction.cancelAuction(auctionId);
        uint256 normalDebt = wdiv(debt_, rate);
        if (!(int256(collateralToSell) >= 0 && int256(normalDebt) >= 0)) revert Tenebrae__skipAuction_overflow();
        codex.confiscateCollateralAndDebt(
            vault,
            tokenId,
            user,
            address(this),
            address(aer),
            int256(collateralToSell),
            int256(normalDebt)
        );
        emit SkipAuction(auctionId, vault, tokenId, user, debt_, collateralToSell, normalDebt);
    }

    /// @notice Offsets the debt of a Position with its collateral. See 3.
    /// @dev Has to be performed before global debt is fixed
    /// @param vault Address of the Vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param user Address of the Position's owner
    function offsetPosition(
        address vault,
        uint256 tokenId,
        address user
    ) external override {
        if (debt != 0) revert Tenebrae__offsetPosition_debtNotZero();
        (, uint256 rate, , ) = codex.vaults(vault);
        (uint256 collateral, uint256 normalDebt) = codex.positions(vault, tokenId, user);
        // get price at maturity
        uint256 owedCollateral = wdiv(wmul(normalDebt, rate), IVault(vault).fairPrice(tokenId, false, true));
        uint256 offsetCollateral;
        if (owedCollateral > collateral) {
            // owing more collateral than the Position has
            lostCollateral[vault][tokenId] = add(lostCollateral[vault][tokenId], sub(owedCollateral, collateral));
            offsetCollateral = collateral;
        } else {
            offsetCollateral = owedCollateral;
        }
        normalDebtByTokenId[vault][tokenId] = add(normalDebtByTokenId[vault][tokenId], normalDebt);
        if (!(offsetCollateral <= 2**255 && normalDebt <= 2**255)) revert Tenebrae__offsetPosition_overflow();
        codex.confiscateCollateralAndDebt(
            vault,
            tokenId,
            user,
            address(this),
            address(aer),
            -int256(offsetCollateral),
            -int256(normalDebt)
        );
        emit SettlePosition(vault, tokenId, user, offsetCollateral, normalDebt);
    }

    /// @notice Closes a user's position, such that the user can exit part of their collateral. See 4.
    /// @dev Has to be performed before global debt is fixed
    /// @param vault Address of the Vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    function closePosition(address vault, uint256 tokenId) external override {
        if (live != 0) revert Tenebrae__closePosition_stillLive();
        if (debt != 0) revert Tenebrae__closePosition_debtNotZero();
        (uint256 collateral, uint256 normalDebt) = codex.positions(vault, tokenId, msg.sender);
        if (normalDebt != 0) revert Tenebrae__closePosition_normalDebtNotZero();
        normalDebtByTokenId[vault][tokenId] = add(normalDebtByTokenId[vault][tokenId], normalDebt);
        if (collateral > 2**255) revert Tenebrae__closePosition_overflow();
        codex.confiscateCollateralAndDebt(vault, tokenId, msg.sender, msg.sender, address(aer), -int256(collateral), 0);
        emit ClosePosition(vault, tokenId, msg.sender, collateral, normalDebt);
    }

    /// @notice Fixes the global debt of the system. See 5.
    /// @dev Can only be called once.
    function fixGlobalDebt() external override {
        if (live != 0) revert Tenebrae__fixGlobalDebt_stillLive();
        if (debt != 0) revert Tenebrae__fixGlobalDebt_debtNotZero();
        if (codex.credit(address(aer)) != 0) revert Tenebrae__fixGlobalDebt_surplusNotZero();
        if (block.timestamp < add(lockedAt, cooldownDuration)) revert Tenebrae__fixGlobalDebt_cooldownNotFinished();
        debt = codex.globalDebt();
        emit FixGlobalDebt();
    }

    /// @notice Gives users the ability to redeem their remaining collateral with credit. See 6.
    /// @dev Has to be performed after global debt is fixed otherwise redemptionPrice is 0
    /// @param vault Address of the Vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param credit Amount of credit to redeem for collateral [wad]
    function redeem(
        address vault,
        uint256 tokenId,
        uint256 credit // credit amount
    ) external override {
        uint256 price = redemptionPrice(vault, tokenId);
        if (price == 0) revert Tenebrae__redeem_redemptionPriceZero();
        codex.transferCredit(msg.sender, address(aer), credit);
        aer.settleDebtWithSurplus(credit);
        codex.transferBalance(vault, tokenId, address(this), msg.sender, wmul(credit, price));
        claimed[vault][tokenId][msg.sender] = add(claimed[vault][tokenId][msg.sender], credit);
        emit Redeem(vault, tokenId, msg.sender, credit);
    }
}
