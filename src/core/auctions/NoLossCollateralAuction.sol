// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2020-2021 Maker Ecosystem Growth Holdings, INC.
pragma solidity ^0.8.4;

import {IPriceCalculator} from "../../interfaces/IPriceCalculator.sol";
import {ICodex} from "../../interfaces/ICodex.sol";
import {CollateralAuctionCallee} from "../../interfaces/ICollateralAuction.sol";
import {INoLossCollateralAuction} from "../../interfaces/INoLossCollateralAuction.sol";
import {ICollybus} from "../../interfaces/ICollybus.sol";
import {IAer} from "../../interfaces/IAer.sol";
import {ILimes} from "../../interfaces/ILimes.sol";
import {IVault} from "../../interfaces/IVault.sol";

import {Guarded} from "../utils/Guarded.sol";
import {WAD, max, min, add, sub, mul, wmul, wdiv} from "../utils/Math.sol";

/// @title NoLossCollateralAuction
/// @notice Same as CollateralAuction but enforces a floor price of debt / collateral
/// Uses Clip.sol from DSS (MakerDAO) as a blueprint
/// Changes from Clip.sol:
/// - only WAD precision is used (no RAD and RAY)
/// - uses a method signature based authentication scheme
/// - supports ERC1155, ERC721 style assets by TokenId
contract NoLossCollateralAuction is Guarded, INoLossCollateralAuction {
    /// ======== Custom Errors ======== ///

    error NoLossCollateralAuction__init_vaultAlreadyInit();
    error NoLossCollateralAuction__checkReentrancy_reentered();
    error NoLossCollateralAuction__isStopped_stoppedIncorrect();
    error NoLossCollateralAuction__setParam_unrecognizedParam();
    error NoLossCollateralAuction__startAuction_zeroDebt();
    error NoLossCollateralAuction__startAuction_zeroCollateralToSell();
    error NoLossCollateralAuction__startAuction_zeroUser();
    error NoLossCollateralAuction__startAuction_overflow();
    error NoLossCollateralAuction__startAuction_zeroStartPrice();
    error NoLossCollateralAuction__redoAuction_notRunningAuction();
    error NoLossCollateralAuction__redoAuction_cannotReset();
    error NoLossCollateralAuction__redoAuction_zeroStartPrice();
    error NoLossCollateralAuction__takeCollateral_notRunningAuction();
    error NoLossCollateralAuction__takeCollateral_needsReset();
    error NoLossCollateralAuction__takeCollateral_tooExpensive();
    error NoLossCollateralAuction__takeCollateral_noPartialPurchase();
    error NoLossCollateralAuction__cancelAuction_notRunningAction();

    /// ======== Storage ======== ///

    // Vault specific configuration data
    struct VaultConfig {
        // Multiplicative factor to increase start price [wad]
        uint256 multiplier;
        // Time elapsed before auction reset [seconds]
        uint256 maxAuctionDuration;
        // Cache (v.debtFloor * v.liquidationPenalty) to prevent excessive SLOADs [wad]
        uint256 auctionDebtFloor;
        // Collateral price module
        ICollybus collybus;
        // Current price calculator
        IPriceCalculator calculator;
    }

    /// @notice Vault Configs
    /// @dev Vault => Vault Config
    mapping(address => VaultConfig) public override vaults;

    /// @notice Codex
    ICodex public immutable override codex;
    /// @notice Limes
    ILimes public override limes;
    /// @notice Aer (Recipient of credit raised in auctions)
    IAer public override aer;
    /// @notice Percentage of debt to mint from aer to incentivize keepers [wad]
    uint64 public override feeTip;
    /// @notice Flat fee to mint from aer to incentivize keepers [wad]
    uint192 public override flatTip;
    /// @notice Total auctions (includes past auctions)
    uint256 public override auctionCounter;
    /// @notice Array of active auction ids
    uint256[] public override activeAuctions;

    // Auction State
    struct Auction {
        // Index in activeAuctions array
        uint256 index;
        // Debt to sell == Credit to raise [wad]
        uint256 debt;
        // collateral to sell [wad]
        uint256 collateralToSell;
        // Vault of the liquidated Positions collateral
        address vault;
        // TokenId of the liquidated Positions collateral
        uint256 tokenId;
        // Owner of the liquidated Position
        address user;
        // Auction start time
        uint96 startsAt;
        // Starting price [wad]
        uint256 startPrice;
    }
    /// @notice State of auctions
    /// @dev AuctionId => Auction
    mapping(uint256 => Auction) public override auctions;

    // reentrancy guard
    uint256 private entered;

    /// @notice Circuit breaker level
    /// Levels for circuit breaker
    /// 0: no breaker
    /// 1: no new startAuction()
    /// 2: no new startAuction() or redoAuction()
    /// 3: no new startAuction(), redoAuction(), or takeCollateral()
    uint256 public override stopped = 0;

    /// ======== Events ======== ///

    event Init(address vault);

    event SetParam(bytes32 indexed param, uint256 data);
    event SetParam(address indexed vault, bytes32 indexed param, uint256 data);
    event SetParam(bytes32 indexed param, address data);
    event SetParam(address indexed vault, bytes32 indexed param, address data);

    event StartAuction(
        uint256 indexed auctionId,
        uint256 startPrice,
        uint256 debt,
        uint256 collateralToSell,
        address vault,
        uint256 tokenId,
        address user,
        address indexed keeper,
        uint256 tip
    );
    event TakeCollateral(
        uint256 indexed auctionId,
        uint256 maxPrice,
        uint256 price,
        uint256 owe,
        uint256 debt,
        uint256 collateralToSell,
        address vault,
        uint256 tokenId,
        address indexed user
    );
    event RedoAuction(
        uint256 indexed auctionId,
        uint256 startPrice,
        uint256 debt,
        uint256 collateralToSell,
        address vault,
        uint256 tokenId,
        address user,
        address indexed keeper,
        uint256 tip
    );

    event StopAuction(uint256 auctionId);

    event UpdateAuctionDebtFloor(address indexed vault, uint256 auctionDebtFloor);

    constructor(address codex_, address limes_) Guarded() {
        codex = ICodex(codex_);
        limes = ILimes(limes_);
    }

    modifier checkReentrancy() {
        if (entered == 0) {
            entered = 1;
            _;
            entered = 0;
        } else revert NoLossCollateralAuction__checkReentrancy_reentered();
    }

    modifier isStopped(uint256 level) {
        if (stopped < level) {
            _;
        } else revert NoLossCollateralAuction__isStopped_stoppedIncorrect();
    }

    /// ======== Configuration ======== ///

    /// @notice Initializes a new Vault for which collateral can be auctioned off
    /// @dev Sender has to be allowed to call this method
    /// @param vault Address of the Vault
    /// @param collybus Address of the Collybus the Vault uses for pricing
    function init(address vault, address collybus) external override checkCaller {
        if (vaults[vault].calculator != IPriceCalculator(address(0)))
            revert NoLossCollateralAuction__init_vaultAlreadyInit();
        vaults[vault].multiplier = WAD;
        vaults[vault].collybus = ICollybus(collybus);

        emit Init(vault);
    }

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(bytes32 param, uint256 data) external override checkCaller checkReentrancy {
        if (param == "feeTip")
            feeTip = uint64(data); // Percentage of debt to incentivize (max: 2^64 - 1 => 18.xxx WAD = 18xx%)
        else if (param == "flatTip")
            flatTip = uint192(data); // Flat fee to incentivize keepers (max: 2^192 - 1 => 6.277T WAD)
        else if (param == "stopped")
            stopped = data; // Set breaker (0, 1, 2, or 3)
        else revert NoLossCollateralAuction__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [address]
    function setParam(bytes32 param, address data) external override checkCaller checkReentrancy {
        if (param == "limes") limes = ILimes(data);
        else if (param == "aer") aer = IAer(data);
        else revert NoLossCollateralAuction__setParam_unrecognizedParam();
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
    ) external override checkCaller checkReentrancy {
        if (param == "multiplier") vaults[vault].multiplier = data;
        else if (param == "maxAuctionDuration")
            vaults[vault].maxAuctionDuration = data; // Time elapsed before auction reset
        else revert NoLossCollateralAuction__setParam_unrecognizedParam();
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
    ) external override checkCaller checkReentrancy {
        if (param == "collybus") vaults[vault].collybus = ICollybus(data);
        else if (param == "calculator") vaults[vault].calculator = IPriceCalculator(data);
        else revert NoLossCollateralAuction__setParam_unrecognizedParam();
        emit SetParam(vault, param, data);
    }

    /// ======== No Loss Collateral Auction ======== ///

    // get price at maturity
    function _getPrice(address vault, uint256 tokenId) internal view returns (uint256) {
        return IVault(vault).fairPrice(tokenId, false, true);
    }

    /// @notice Starts a collateral auction
    /// The start price `startPrice` is obtained as follows:
    ///     startPrice = val * multiplier / redemptionPrice
    /// Where `val` is the collateral's unitary value in USD, `multiplier` is a
    /// multiplicative factor to increase the start price, and `redemptionPrice` is a reference per Credit.
    /// @dev Sender has to be allowed to call this method
    /// - trusts the caller to transfer collateral to the contract
    /// - reverts if circuit breaker is set to 1 (no new auctions)
    /// @param debt Amount of debt to sell / credit to buy [wad]
    /// @param collateralToSell Amount of collateral to sell [wad]
    /// @param vault Address of the collaterals Vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20) of the collateral
    /// @param user Address that will receive any leftover collateral
    /// @param keeper Address that will receive incentives
    /// @return auctionId Identifier of started auction
    function startAuction(
        uint256 debt,
        uint256 collateralToSell,
        address vault,
        uint256 tokenId,
        address user,
        address keeper
    ) external override checkCaller checkReentrancy isStopped(1) returns (uint256 auctionId) {
        // Input validation
        if (debt == 0) revert NoLossCollateralAuction__startAuction_zeroDebt();
        if (collateralToSell == 0) revert NoLossCollateralAuction__startAuction_zeroCollateralToSell();
        if (user == address(0)) revert NoLossCollateralAuction__startAuction_zeroUser();
        unchecked {
            auctionId = ++auctionCounter;
        }
        if (auctionId == 0) revert NoLossCollateralAuction__startAuction_overflow();

        activeAuctions.push(auctionId);

        auctions[auctionId].index = activeAuctions.length - 1;

        auctions[auctionId].debt = debt;
        auctions[auctionId].collateralToSell = collateralToSell;
        auctions[auctionId].vault = vault;
        auctions[auctionId].tokenId = tokenId;
        auctions[auctionId].user = user;
        auctions[auctionId].startsAt = uint96(block.timestamp);

        uint256 startPrice;
        startPrice = wmul(_getPrice(vault, tokenId), vaults[vault].multiplier);
        if (startPrice <= 0) revert NoLossCollateralAuction__startAuction_zeroStartPrice();
        auctions[auctionId].startPrice = startPrice;

        // incentive to startAuction auction
        uint256 _tip = flatTip;
        uint256 _feeTip = feeTip;
        uint256 tip;
        if (_tip > 0 || _feeTip > 0) {
            tip = add(_tip, wmul(debt, _feeTip));
            codex.createUnbackedDebt(address(aer), keeper, tip);
        }

        emit StartAuction(auctionId, startPrice, debt, collateralToSell, vault, tokenId, user, keeper, tip);
    }

    /// @notice Resets an existing collateral auction
    /// See `startAuction` above for an explanation of the computation of `startPrice`.
    /// multiplicative factor to increase the start price, and `redemptionPrice` is a reference per Credit.
    /// @dev Reverts if circuit breaker is set to 2 (no new auctions and no redos of auctions)
    /// @param auctionId Id of the auction to reset
    /// @param keeper Address that will receive incentives
    function redoAuction(uint256 auctionId, address keeper) external override checkReentrancy isStopped(2) {
        // Read auction data
        Auction memory auction = auctions[auctionId];

        if (auction.user == address(0)) revert NoLossCollateralAuction__redoAuction_notRunningAuction();

        // Check that auction needs reset
        // and compute current price [wad]
        {
            (bool done, ) = status(auction);
            if (!done) revert NoLossCollateralAuction__redoAuction_cannotReset();
        }

        uint256 debt = auctions[auctionId].debt;
        uint256 collateralToSell = auctions[auctionId].collateralToSell;
        auctions[auctionId].startsAt = uint96(block.timestamp);

        uint256 price = _getPrice(auction.vault, auction.tokenId);
        uint256 startPrice = wmul(price, vaults[auction.vault].multiplier);
        if (startPrice <= 0) revert NoLossCollateralAuction__redoAuction_zeroStartPrice();
        auctions[auctionId].startPrice = startPrice;

        // incentive to redoAuction auction
        uint256 tip;
        {
            uint256 _tip = flatTip;
            uint256 _feeTip = feeTip;
            if (_tip > 0 || _feeTip > 0) {
                uint256 _auctionDebtFloor = vaults[auction.vault].auctionDebtFloor;
                if (debt >= _auctionDebtFloor && wmul(collateralToSell, price) >= _auctionDebtFloor) {
                    tip = add(_tip, wmul(debt, _feeTip));
                    codex.createUnbackedDebt(address(aer), keeper, tip);
                }
            }
        }

        emit RedoAuction(
            auctionId,
            startPrice,
            debt,
            collateralToSell,
            auction.vault,
            auction.tokenId,
            auction.user,
            keeper,
            tip
        );
    }

    /// @notice Buy up to `collateralAmount` of collateral from the auction indexed by `id`
    ///
    /// Auctions will not collect more Credit than their assigned Credit target,`debt`;
    /// thus, if `collateralAmount` would cost more Credit than `debt` at the current price, the
    /// amount of collateral purchased will instead be just enough to collect `debt` in Credit.
    ///
    /// To avoid partial purchases resulting in very small leftover auctions that will
    /// never be cleared, any partial purchase must leave at least `CollateralAuction.auctionDebtFloor`
    /// remaining Credit target. `auctionDebtFloor` is an asynchronously updated value equal to
    /// (Codex.debtFloor * Limes.liquidationPenalty(vault) / WAD) where the values are understood to be determined
    /// by whatever they were when CollateralAuction.updateAuctionDebtFloor() was last called. Purchase amounts
    /// will be minimally decreased when necessary to respect this limit; i.e., if the
    /// specified `collateralAmount` would leave `debt < auctionDebtFloor` but `debt > 0`, the amount actually
    /// purchased will be such that `debt == auctionDebtFloor`.
    ///
    /// If `debt <= auctionDebtFloor`, partial purchases are no longer possible; that is, the remaining
    /// collateral can only be purchased entirely, or not at all.
    ///
    /// Enforces a price floor of debt / collateral
    ///
    /// @dev Reverts if circuit breaker is set to 3 (no new auctions, no redos of auctions and no collateral buying)
    /// @param auctionId Id of the auction to buy collateral from
    /// @param collateralAmount Upper limit on amount of collateral to buy [wad]
    /// @param maxPrice Maximum acceptable price (Credit / collateral) [wad]
    /// @param recipient Receiver of collateral and external call address
    /// @param data Data to pass in external call; if length 0, no call is done
    function takeCollateral(
        uint256 auctionId, // Auction id
        uint256 collateralAmount, // Upper limit on amount of collateral to buy [wad]
        uint256 maxPrice, // Maximum acceptable price (Credit / collateral) [wad]
        address recipient, // Receiver of collateral and external call address
        bytes calldata data // Data to pass in external call; if length 0, no call is done
    ) external override checkReentrancy isStopped(3) {
        Auction memory auction = auctions[auctionId];

        if (auction.user == address(0)) revert NoLossCollateralAuction__takeCollateral_notRunningAuction();

        uint256 price;
        {
            bool done;
            (done, price) = status(auction);

            // Check that auction doesn't need reset
            if (done) revert NoLossCollateralAuction__takeCollateral_needsReset();
            // Ensure price is acceptable to buyer
            if (maxPrice < price) revert NoLossCollateralAuction__takeCollateral_tooExpensive();
        }

        uint256 collateralToSell = auction.collateralToSell;
        uint256 debt = auction.debt;
        uint256 owe;

        unchecked {
            {
                // Purchase as much as possible, up to collateralAmount
                // collateralSlice <= collateralToSell
                uint256 collateralSlice = min(collateralToSell, collateralAmount);

                // Credit needed to buy a collateralSlice of this auction
                owe = wmul(collateralSlice, price);

                // owe can be greater than debt and thus user would pay a premium to the recipient

                if (owe < debt && collateralSlice < collateralToSell) {
                    // If collateralSlice == collateralToSell => auction completed => debtFloor doesn't matter
                    uint256 _auctionDebtFloor = vaults[auction.vault].auctionDebtFloor;
                    if (debt - owe < _auctionDebtFloor) {
                        // safe as owe < debt
                        // If debt <= auctionDebtFloor, buyers have to take the entire collateralToSell.
                        if (debt <= _auctionDebtFloor)
                            revert NoLossCollateralAuction__takeCollateral_noPartialPurchase();
                        // Adjust amount to pay
                        owe = debt - _auctionDebtFloor; // owe' <= owe
                        // Adjust collateralSlice
                        // collateralSlice' = owe' / price < owe / price == collateralSlice < collateralToSell
                        collateralSlice = wdiv(owe, price);
                    }
                }

                // Calculate remaining collateralToSell after operation
                collateralToSell = collateralToSell - collateralSlice;

                // Send collateral to recipient
                codex.transferBalance(auction.vault, auction.tokenId, address(this), recipient, collateralSlice);

                // Do external call (if data is defined) but to be
                // extremely careful we don't allow to do it to the two
                // contracts which the CollateralAuction needs to be authorized
                ILimes limes_ = limes;
                if (data.length > 0 && recipient != address(codex) && recipient != address(limes_)) {
                    CollateralAuctionCallee(recipient).collateralAuctionCall(msg.sender, owe, collateralSlice, data);
                }

                // Get Credit from caller
                codex.transferCredit(msg.sender, address(aer), owe);

                // Removes Credit out for liquidation from accumulator
                // if all collateral has been sold or owe is larger than remaining debt
                //  then just remove the remaining debt from the accumulator
                limes_.liquidated(auction.vault, auction.tokenId, (collateralToSell == 0 || debt < owe) ? debt : owe);

                // Calculate remaining debt after operation
                debt = (owe < debt) ? debt - owe : 0; // safe since owe <= debt
            }
        }

        if (collateralToSell == 0) {
            _remove(auctionId);
        } else if (debt == 0) {
            codex.transferBalance(auction.vault, auction.tokenId, address(this), auction.user, collateralToSell);
            _remove(auctionId);
        } else {
            auctions[auctionId].debt = debt;
            auctions[auctionId].collateralToSell = collateralToSell;
        }

        emit TakeCollateral(
            auctionId,
            maxPrice,
            price,
            owe,
            debt,
            collateralToSell,
            auction.vault,
            auction.tokenId,
            auction.user
        );
    }

    // Removes an auction from the active auctions array
    function _remove(uint256 auctionId) internal {
        uint256 _move = activeAuctions[activeAuctions.length - 1];
        if (auctionId != _move) {
            uint256 _index = auctions[auctionId].index;
            activeAuctions[_index] = _move;
            auctions[_move].index = _index;
        }
        activeAuctions.pop();
        delete auctions[auctionId];
    }

    /// @notice The number of active auctions
    /// @return Number of active auctions
    function count() external view override returns (uint256) {
        return activeAuctions.length;
    }

    /// @notice Returns the entire array of active auctions
    /// @return List of active auctions
    function list() external view override returns (uint256[] memory) {
        return activeAuctions;
    }

    /// @notice Externally returns boolean for if an auction needs a redo and also the current price
    /// @param auctionId Id of the auction to get the status for
    /// @return needsRedo If the auction needs a redo (max duration or max discount exceeded)
    /// @return price Current price of the collateral determined by the calculator [wad]
    /// @return collateralToSell Amount of collateral left to buy for credit [wad]
    /// @return debt Amount of debt / credit to sell for collateral [wad]
    function getStatus(uint256 auctionId)
        external
        view
        override
        returns (
            bool needsRedo,
            uint256 price,
            uint256 collateralToSell,
            uint256 debt
        )
    {
        Auction memory auction = auctions[auctionId];

        bool done;
        (done, price) = status(auction);

        needsRedo = auction.user != address(0) && done;
        collateralToSell = auction.collateralToSell;
        debt = auction.debt;
    }

    // Internally returns boolean for if an auction needs a redo
    function status(Auction memory auction) internal view returns (bool done, uint256 price) {
        uint256 floorPrice = wdiv(auction.debt, auction.collateralToSell);
        price = max(
            floorPrice,
            vaults[auction.vault].calculator.price(auction.startPrice, sub(block.timestamp, auction.startsAt))
        );
        done = (sub(block.timestamp, auction.startsAt) > vaults[auction.vault].maxAuctionDuration ||
            price == floorPrice);
    }

    /// @notice Public function to update the cached vault.debtFloor*vault.liquidationPenalty value
    /// @param vault Address of the Vault for which to update the auctionDebtFloor variable
    function updateAuctionDebtFloor(address vault) external override {
        (, , , uint256 _debtFloor) = ICodex(codex).vaults(vault);
        uint256 auctionDebtFloor = wmul(_debtFloor, limes.liquidationPenalty(vault));
        vaults[vault].auctionDebtFloor = auctionDebtFloor;
        emit UpdateAuctionDebtFloor(vault, auctionDebtFloor);
    }

    /// ======== Shutdown ======== ///

    /// @notice Cancels an auction during shutdown or via governance action
    /// @dev Sender has to be allowed to call this method
    /// @param auctionId Id of the auction to cancel
    function cancelAuction(uint256 auctionId) external override checkCaller checkReentrancy {
        if (auctions[auctionId].user == address(0)) revert NoLossCollateralAuction__cancelAuction_notRunningAction();
        address vault = auctions[auctionId].vault;
        uint256 tokenId = auctions[auctionId].tokenId;
        limes.liquidated(vault, tokenId, auctions[auctionId].debt);
        codex.transferBalance(vault, tokenId, address(this), msg.sender, auctions[auctionId].collateralToSell);
        _remove(auctionId);
        emit StopAuction(auctionId);
    }
}
