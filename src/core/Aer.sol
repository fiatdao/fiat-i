// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2018 Rain <rainbreak@riseup.net>
pragma solidity ^0.8.4;

import {ICodex} from "../interfaces/ICodex.sol";
import {IDebtAuction} from "../interfaces/IDebtAuction.sol";
import {IAer} from "../interfaces/IAer.sol";
import {ISurplusAuction} from "../interfaces/ISurplusAuction.sol";

import {Guarded} from "./utils/Guarded.sol";
import {WAD, min, add, sub} from "./utils/Math.sol";

/// @title Aer (short for Aerarium)
/// @notice `Aer` is used for managing the protocol's debt and surplus balances via the DebtAuction and
/// SurplusAuction contracts.
/// Uses Vow.sol from DSS (MakerDAO) / AccountingEngine.sol from GEB (Reflexer Labs) as a blueprint
/// Changes from Vow.sol / AccountingEngine.sol:
/// - only WAD precision is used (no RAD and RAY)
/// - uses a method signature based authentication scheme
contract Aer is Guarded, IAer {
    /// ======== Custom Errors ======== ///

    error Aer__setParam_unrecognizedParam();
    error Aer__unqueueDebt_auctionDelayNotPassed();
    error Aer__settleDebtWithSurplus_insufficientSurplus();
    error Aer__settleDebtWithSurplus_insufficientDebt();
    error Aer__settleAuctionedDebt_notEnoughDebtOnAuction();
    error Aer__settleAuctionedDebt_insufficientSurplus();
    error Aer__startDebtAuction_insufficientDebt();
    error Aer__startDebtAuction_surplusNotZero();
    error Aer__startSurplusAuction_insufficientSurplus();
    error Aer__startSurplusAuction_debtNotZero();
    error Aer__transferCredit_insufficientCredit();
    error Aer__lock_notLive();

    /// ======== Storage ======== ///

    /// @notice Codex
    ICodex public immutable override codex;
    /// @notice SurplusAuction
    ISurplusAuction public override surplusAuction;
    /// @notice DebtAuction
    IDebtAuction public override debtAuction;

    /// @notice List of debt amounts to be auctioned sorted by the time at which they where queued
    /// @dev Queued at timestamp => Debt [wad]
    mapping(uint256 => uint256) public override debtQueue;
    /// @notice Queued debt amount [wad]
    uint256 public override queuedDebt;
    /// @notice Amount of debt currently on auction [wad]
    uint256 public override debtOnAuction;

    /// @notice Time after which queued debt can be put up for auction [seconds]
    uint256 public override auctionDelay;
    /// @notice Amount of tokens to sell in each debt auction [wad]
    uint256 public override debtAuctionSellSize;
    /// @notice Min. amount of (credit to bid or debt to sell) for tokens [wad]
    uint256 public override debtAuctionBidSize;

    /// @notice Amount of credit to sell in each surplus auction [wad]
    uint256 public override surplusAuctionSellSize;
    /// @notice Amount of credit required for starting a surplus auction [wad]
    uint256 public override surplusBuffer;

    /// @notice Boolean indicating if this contract is live (0 - not live, 1 - live)
    uint256 public override live;

    /// ======== Events ======== ///
    event SetParam(bytes32 indexed param, uint256 data);
    event SetParam(bytes32 indexed param, address indexed data);
    event QueueDebt(uint256 indexed queuedAt, uint256 debtQueue, uint256 queuedDebt);
    event UnqueueDebt(uint256 indexed queuedAt, uint256 queuedDebt);
    event StartDebtAuction(uint256 debtOnAuction, uint256 indexed auctionId);
    event SettleAuctionedDebt(uint256 debtOnAuction);
    event StartSurplusAuction(uint256 indexed auctionId);
    event SettleDebtWithSurplus(uint256 debt);
    event Lock();

    constructor(
        address codex_,
        address surplusAuction_,
        address debtAuction_
    ) Guarded() {
        codex = ICodex(codex_);
        surplusAuction = ISurplusAuction(surplusAuction_);
        debtAuction = IDebtAuction(debtAuction_);
        ICodex(codex_).grantDelegate(surplusAuction_);
        live = 1;
    }

    /// ======== Configuration ======== ///

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(bytes32 param, uint256 data) external override checkCaller {
        if (param == "auctionDelay") auctionDelay = data;
        else if (param == "surplusAuctionSellSize") surplusAuctionSellSize = data;
        else if (param == "debtAuctionBidSize") debtAuctionBidSize = data;
        else if (param == "debtAuctionSellSize") debtAuctionSellSize = data;
        else if (param == "surplusBuffer") surplusBuffer = data;
        else revert Aer__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [address]
    function setParam(bytes32 param, address data) external override checkCaller {
        if (param == "surplusAuction") {
            codex.revokeDelegate(address(surplusAuction));
            surplusAuction = ISurplusAuction(data);
            codex.grantDelegate(data);
        } else if (param == "debtAuction") debtAuction = IDebtAuction(data);
        else revert Aer__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// ======== Debt Auction ======== ///

    /// @notice Pushes new debt to the debt queue
    /// @dev Sender has to be allowed to call this method
    /// @param debt Amount of debt [wad]
    function queueDebt(uint256 debt) external override checkCaller {
        debtQueue[block.timestamp] = add(debtQueue[block.timestamp], debt);
        queuedDebt = add(queuedDebt, debt);
        emit QueueDebt(block.timestamp, debtQueue[block.timestamp], queuedDebt);
    }

    /// @notice Pops debt from the debt queue
    /// @param queuedAt Timestamp at which the debt has been queued [seconds]
    function unqueueDebt(uint256 queuedAt) external override {
        if (add(queuedAt, auctionDelay) > block.timestamp) revert Aer__unqueueDebt_auctionDelayNotPassed();
        queuedDebt = sub(queuedDebt, debtQueue[queuedAt]);
        debtQueue[queuedAt] = 0;
        emit UnqueueDebt(queuedAt, queuedDebt);
    }

    /// @notice Starts a debt auction
    /// @dev Sender has to be allowed to call this method
    /// Checks if enough debt exists to be put up for auction
    /// debtAuctionBidSize > (unbackedDebt - queuedDebt - debtOnAuction)
    /// @return auctionId Id of the debt auction
    function startDebtAuction() external override checkCaller returns (uint256 auctionId) {
        if (debtAuctionBidSize > sub(sub(codex.unbackedDebt(address(this)), queuedDebt), debtOnAuction))
            revert Aer__startDebtAuction_insufficientDebt();
        if (codex.credit(address(this)) != 0) revert Aer__startDebtAuction_surplusNotZero();
        debtOnAuction = add(debtOnAuction, debtAuctionBidSize);
        auctionId = debtAuction.startAuction(address(this), debtAuctionSellSize, debtAuctionBidSize);
        emit StartDebtAuction(debtOnAuction, auctionId);
    }

    /// @notice Settles debt collected from debt auctions
    /// @dev Cannot settle debt with accrued surplus (only from debt auctions)
    /// @param debt Amount of debt to settle [wad]
    function settleAuctionedDebt(uint256 debt) external override {
        if (debt > debtOnAuction) revert Aer__settleAuctionedDebt_notEnoughDebtOnAuction();
        if (debt > codex.credit(address(this))) revert Aer__settleAuctionedDebt_insufficientSurplus();
        debtOnAuction = sub(debtOnAuction, debt);
        codex.settleUnbackedDebt(debt);
        emit SettleAuctionedDebt(debtOnAuction);
    }

    /// ======== Surplus Auction ======== ///

    /// @notice Starts a surplus auction
    /// @dev Sender has to be allowed to call this method
    /// Checks if enough surplus has accrued (surplusAuctionSellSize + surplusBuffer) and there's
    /// no queued debt to be put up for a debt auction
    /// @return auctionId Id of the surplus auction
    function startSurplusAuction() external override checkCaller returns (uint256 auctionId) {
        if (
            codex.credit(address(this)) <
            add(add(codex.unbackedDebt(address(this)), surplusAuctionSellSize), surplusBuffer)
        ) revert Aer__startSurplusAuction_insufficientSurplus();
        if (sub(sub(codex.unbackedDebt(address(this)), queuedDebt), debtOnAuction) != 0)
            revert Aer__startSurplusAuction_debtNotZero();
        auctionId = surplusAuction.startAuction(surplusAuctionSellSize, 0);
        emit StartSurplusAuction(auctionId);
    }

    /// @notice Settles debt with the accrued surplus
    /// @dev Sender has to be allowed to call this method
    /// Can not settle more debt than there's unbacked debt and which is not expected
    /// to be settled via debt auctions (queuedDebt + debtOnAuction)
    /// @param debt Amount of debt to settle [wad]
    function settleDebtWithSurplus(uint256 debt) external override checkCaller {
        if (debt > codex.credit(address(this))) revert Aer__settleDebtWithSurplus_insufficientSurplus();
        if (debt > sub(sub(codex.unbackedDebt(address(this)), queuedDebt), debtOnAuction))
            revert Aer__settleDebtWithSurplus_insufficientDebt();
        codex.settleUnbackedDebt(debt);
        emit SettleDebtWithSurplus(debt);
    }

    /// @notice Transfer accrued credit surplus to another account
    /// @dev Can only transfer backed credit out of Aer
    /// @param credit Amount of debt to settle [wad]
    function transferCredit(address to, uint256 credit) external override checkCaller {
        if (credit > sub(codex.credit(address(this)), codex.unbackedDebt(address(this))))
            revert Aer__transferCredit_insufficientCredit();
        codex.transferCredit(address(this), to, credit);
    }

    /// ======== Shutdown ======== ///

    /// @notice Locks the contract
    /// @dev Sender has to be allowed to call this method
    /// Wipes queued debt and debt on auction, locks DebtAuction and SurplusAuction and
    /// settles debt with what it has available
    function lock() external override checkCaller {
        if (live == 0) revert Aer__lock_notLive();
        live = 0;
        queuedDebt = 0;
        debtOnAuction = 0;
        surplusAuction.lock(codex.credit(address(surplusAuction)));
        debtAuction.lock();
        codex.settleUnbackedDebt(min(codex.credit(address(this)), codex.unbackedDebt(address(this))));
        emit Lock();
    }
}
