// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2020-2021 Maker Ecosystem Growth Holdings, INC.
pragma solidity ^0.8.4;

import {ICodex} from "../interfaces/ICodex.sol";
import {ICollateralAuction} from "../interfaces/ICollateralAuction.sol";
import {IAer} from "../interfaces/IAer.sol";
import {ILimes} from "../interfaces/ILimes.sol";
import {IVault} from "../interfaces/IVault.sol";

import {Guarded} from "./utils/Guarded.sol";
import {WAD, min, add, sub, mul, wmul} from "./utils/Math.sol";

/// @title Limes
/// @notice `Limes` is responsible for triggering liquidations of unsafe Positions and
/// putting the Position's collateral up for auction
/// Uses Dog.sol from DSS (MakerDAO) as a blueprint
/// Changes from Dog.sol:
/// - only WAD precision is used (no RAD and RAY)
/// - uses a method signature based authentication scheme
/// - supports ERC1155, ERC721 style assets by TokenId
contract Limes is Guarded, ILimes {
    /// ======== Custom Errors ======== ///

    error Limes__setParam_liquidationPenaltyLtWad();
    error Limes__setParam_unrecognizedParam();
    error Limes__liquidate_notLive();
    error Limes__liquidate_notUnsafe();
    error Limes__liquidate_maxDebtOnAuction();
    error Limes__liquidate_dustyAuctionFromPartialLiquidation();
    error Limes__liquidate_nullAuction();
    error Limes__liquidate_overflow();

    /// ======== Storage ======== ///

    // Vault specific configuration data
    struct VaultConfig {
        // Auction contract for collateral
        address collateralAuction;
        // Liquidation penalty [wad]
        uint256 liquidationPenalty;
        // Max credit needed to cover debt+fees of active auctions per vault [wad]
        uint256 maxDebtOnAuction;
        // Amount of credit needed to cover debt+fees for all active auctions per vault [wad]
        uint256 debtOnAuction;
    }

    /// @notice Vault Configs
    /// @dev Vault => Vault Config
    mapping(address => VaultConfig) public override vaults;

    /// @notice Codex
    ICodex public immutable override codex;
    /// @notice Aer
    IAer public override aer;

    /// @notice Max credit needed to cover debt+fees of active auctions [wad]
    uint256 public override globalMaxDebtOnAuction;
    /// @notice Amount of credit needed to cover debt+fees for all active auctions [wad]
    uint256 public override globalDebtOnAuction;

    /// @notice Boolean indicating if this contract is live (0 - not live, 1 - live)
    uint256 public override live;

    /// ======== Events ======== ///

    event SetParam(bytes32 indexed param, uint256 data);
    event SetParam(bytes32 indexed param, address data);
    event SetParam(address indexed vault, bytes32 indexed param, uint256 data);
    event SetParam(address indexed vault, bytes32 indexed param, address collateralAuction);

    event Liquidate(
        address indexed vault,
        uint256 indexed tokenId,
        address position,
        uint256 collateral,
        uint256 normalDebt,
        uint256 due,
        address collateralAuction,
        uint256 indexed auctionId
    );
    event Liquidated(address indexed vault, uint256 indexed tokenId, uint256 debt);
    event Lock();

    constructor(address codex_) Guarded() {
        codex = ICodex(codex_);
        live = 1;
    }

    /// ======== Configuration ======== ///

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [address]
    function setParam(bytes32 param, address data) external override checkCaller {
        if (param == "aer") aer = IAer(data);
        else revert Limes__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(bytes32 param, uint256 data) external override checkCaller {
        if (param == "globalMaxDebtOnAuction") globalMaxDebtOnAuction = data;
        else revert Limes__setParam_unrecognizedParam();
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
        if (param == "liquidationPenalty") {
            if (data < WAD) revert Limes__setParam_liquidationPenaltyLtWad();
            vaults[vault].liquidationPenalty = data;
        } else if (param == "maxDebtOnAuction") vaults[vault].maxDebtOnAuction = data;
        else revert Limes__setParam_unrecognizedParam();
        emit SetParam(vault, param, data);
    }

    /// @notice Sets various variables for a Vault
    /// @dev Sender has to be allowed to call this method
    /// @param vault Address of the Vault
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [address]
    function setParam(
        address vault,
        bytes32 param,
        address data
    ) external override checkCaller {
        if (param == "collateralAuction") {
            vaults[vault].collateralAuction = data;
        } else revert Limes__setParam_unrecognizedParam();
        emit SetParam(vault, param, data);
    }

    /// ======== Liquidations ======== ///

    /// @notice Direct access to the current liquidation penalty set for a Vault
    /// @param vault Address of the Vault
    /// @return liquidation penalty [wad]
    function liquidationPenalty(address vault) external view override returns (uint256) {
        return vaults[vault].liquidationPenalty;
    }

    /// @notice Liquidate a Position and start a Dutch auction to sell its collateral for credit.
    /// @dev The third argument is the address that will receive the liquidation reward, if any.
    /// The entire Position will be liquidated except when the target amount of credit to be raised in
    /// the resulting auction (debt of Position + liquidation penalty) causes either globalDebtOnAuction to exceed
    /// globalMaxDebtOnAuction or vault.debtOnAuction to exceed vault.maxDebtOnAuction by an economically
    /// significant amount. In that case, a partial liquidation is performed to respect the global and per-vault limits
    /// on outstanding credit target. The one exception is if the resulting auction would likely
    /// have too little collateral to be of interest to Keepers (debt taken from Position < vault.debtFloor),
    /// in which case the function reverts. Please refer to the code and comments within if more detail is desired.
    /// @param vault Address of the Position's Vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20) of the Position
    /// @param position Address of the owner of the Position
    /// @param keeper Address of the keeper who triggers the liquidation and receives the reward
    /// @return auctionId Indentifier of the started auction
    function liquidate(
        address vault,
        uint256 tokenId,
        address position,
        address keeper
    ) external override returns (uint256 auctionId) {
        if (live == 0) revert Limes__liquidate_notLive();

        VaultConfig memory mvault = vaults[vault];
        uint256 deltaNormalDebt;
        uint256 rate;
        uint256 debtFloor;
        uint256 deltaCollateral;
        unchecked {
            {
                (uint256 collateral, uint256 normalDebt) = codex.positions(vault, tokenId, position);
                uint256 price = IVault(vault).fairPrice(tokenId, true, false);
                (, rate, , debtFloor) = codex.vaults(vault);
                if (price == 0 || mul(collateral, price) >= mul(normalDebt, rate)) revert Limes__liquidate_notUnsafe();

                // Get the minimum value between:
                // 1) Remaining space in the globalMaxDebtOnAuction
                // 2) Remaining space in the vault.maxDebtOnAuction
                if (!(globalMaxDebtOnAuction > globalDebtOnAuction && mvault.maxDebtOnAuction > mvault.debtOnAuction))
                    revert Limes__liquidate_maxDebtOnAuction();

                uint256 room = min(
                    globalMaxDebtOnAuction - globalDebtOnAuction,
                    mvault.maxDebtOnAuction - mvault.debtOnAuction
                );

                // normalize room by subtracting rate and liquidationPenalty
                deltaNormalDebt = min(normalDebt, (((room * WAD) / rate) * WAD) / mvault.liquidationPenalty);

                // Partial liquidation edge case logic
                if (normalDebt > deltaNormalDebt) {
                    if (wmul(normalDebt - deltaNormalDebt, rate) < debtFloor) {
                        // If the leftover Position would be dusty, just liquidate it entirely.
                        // This will result in at least one of v.debtOnAuction > v.maxDebtOnAuction or
                        // globalDebtOnAuction > globalMaxDebtOnAuction becoming true. The amount of excess will
                        // be bounded above by ceiling(v.debtFloor * v.liquidationPenalty / WAD). This deviation is
                        // assumed to be small compared to both v.maxDebtOnAuction and globalMaxDebtOnAuction, so that
                        // the extra amount of credit is not of economic concern.
                        deltaNormalDebt = normalDebt;
                    } else {
                        // In a partial liquidation, the resulting auction should also be non-dusty.
                        if (wmul(deltaNormalDebt, rate) < debtFloor)
                            revert Limes__liquidate_dustyAuctionFromPartialLiquidation();
                    }
                }

                deltaCollateral = mul(collateral, deltaNormalDebt) / normalDebt;
            }
        }

        if (deltaCollateral == 0) revert Limes__liquidate_nullAuction();
        if (!(deltaNormalDebt <= 2**255 && deltaCollateral <= 2**255)) revert Limes__liquidate_overflow();

        codex.confiscateCollateralAndDebt(
            vault,
            tokenId,
            position,
            mvault.collateralAuction,
            address(aer),
            -int256(deltaCollateral),
            -int256(deltaNormalDebt)
        );

        uint256 due = wmul(deltaNormalDebt, rate);
        aer.queueDebt(due);

        {
            // Avoid stack too deep
            // This calcuation will overflow if deltaNormalDebt*rate exceeds ~10^14
            uint256 debt = wmul(due, mvault.liquidationPenalty);
            globalDebtOnAuction = add(globalDebtOnAuction, debt);
            vaults[vault].debtOnAuction = add(mvault.debtOnAuction, debt);

            auctionId = ICollateralAuction(mvault.collateralAuction).startAuction({
                debt: debt,
                collateralToSell: deltaCollateral,
                vault: vault,
                tokenId: tokenId,
                user: position,
                keeper: keeper
            });
        }

        emit Liquidate(
            vault,
            tokenId,
            position,
            deltaCollateral,
            deltaNormalDebt,
            due,
            mvault.collateralAuction,
            auctionId
        );
    }

    /// @notice Marks the liquidated Position's debt as sold
    /// @dev Sender has to be allowed to call this method
    /// @param vault Address of the liquidated Position's Vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20) of the liquidated Position
    /// @param debt Amount of debt sold
    function liquidated(
        address vault,
        uint256 tokenId,
        uint256 debt
    ) external override checkCaller {
        globalDebtOnAuction = sub(globalDebtOnAuction, debt);
        vaults[vault].debtOnAuction = sub(vaults[vault].debtOnAuction, debt);
        emit Liquidated(vault, tokenId, debt);
    }

    /// ======== Shutdown ======== ///

    /// @notice Locks the contract
    /// @dev Sender has to be allowed to call this method
    function lock() external override checkCaller {
        live = 0;
        emit Lock();
    }
}
