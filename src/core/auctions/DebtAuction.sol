// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2018 Rain <rainbreak@riseup.net>
pragma solidity ^0.8.4;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IAer} from "../../interfaces/IAer.sol";
import {ICodex} from "../../interfaces/ICodex.sol";
import {ICollybus} from "../../interfaces/ICollybus.sol";
import {IDebtAuction} from "../../interfaces/IDebtAuction.sol";

import {Guarded} from "../utils/Guarded.sol";
import {WAD, min, add48, mul} from "../utils/Math.sol";

/// @title DebtAuction
/// @notice
/// Uses Flop.sol from DSS (MakerDAO) as a blueprint
/// Changes from Flop.sol:
/// - only WAD precision is used (no RAD and RAY)
/// - uses a method signature based authentication scheme
/// - supports ERC1155, ERC721 style assets by TokenId
contract DebtAuction is Guarded, IDebtAuction {
    /// ======== Custom Errors ======== ///

    error DebtAuction__setParam_unrecognizedParam();
    error DebtAuction__startAuction_notLive();
    error DebtAuction__startAuction_overflow();
    error DebtAuction__redoAuction_notFinished();
    error DebtAuction__redoAuction_bidAlreadyPlaced();
    error DebtAuction__submitBid_notLive();
    error DebtAuction__submitBid_recipientNotSet();
    error DebtAuction__submitBid_expired();
    error DebtAuction__submitBid_alreadyFinishedAuctionExpiry();
    error DebtAuction__submitBid_notMatchingBid();
    error DebtAuction__submitBid_tokensToSellNotLower();
    error DebtAuction__submitBid_insufficientDecrease();
    error DebtAuction__closeAuction_notLive();
    error DebtAuction__closeAuction_notFinished();
    error DebtAuction__cancelAuction_stillLive();
    error DebtAuction__cancelAuction_recipientNotSet();

    /// ======== Storage ======== ///

    // Auction State
    struct Auction {
        // credit paid [wad]
        uint256 bid;
        // tokens in return for bid [wad]
        uint256 tokensToSell;
        // high bidder
        address recipient;
        // bid expiry time [unix epoch time]
        uint48 bidExpiry;
        // auction expiry time [unix epoch time]
        uint48 auctionExpiry;
    }

    /// @notice State of auctions
    // AuctionId => Auction
    mapping(uint256 => Auction) public override auctions;

    /// @notice Codex
    ICodex public immutable override codex;
    /// @notice Token to sell for debt
    IERC20 public immutable override token;

    /// @notice 5% minimum bid increase
    uint256 public override minBidBump = 1.05e18;
    /// @notice 50% tokensToSell increase for redoAuction
    uint256 public override tokenToSellBump = 1.50e18;
    /// @notice 3 hours bid lifetime [seconds]
    uint48 public override bidDuration = 3 hours;
    /// @notice 2 days total auction length [seconds]
    uint48 public override auctionDuration = 2 days;
    /// @notice Auction Counter
    uint256 public override auctionCounter = 0;

    /// @notice Boolean indicating if this contract is live (0 - not live, 1 - live)
    uint256 public override live;

    /// @notice Aer, not used until shutdown
    address public override aer;

    /// ======== Events ======== ///

    event StartAuction(uint256 id, uint256 tokensToSell, uint256 bid, address indexed recipient);

    constructor(address codex_, address token_) Guarded() {
        codex = ICodex(codex_);
        token = IERC20(token_);
        live = 1;
    }

    /// ======== Configuration ======== ///

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(bytes32 param, uint256 data) external override checkCaller {
        if (param == "minBidBump") minBidBump = data;
        else if (param == "tokenToSellBump") tokenToSellBump = data;
        else if (param == "bidDuration") bidDuration = uint48(data);
        else if (param == "auctionDuration") auctionDuration = uint48(data);
        else revert DebtAuction__setParam_unrecognizedParam();
    }

    /// ======== Debt Auction ======== ///

    /// @notice Start a new debt auction
    /// @dev Sender has to be allowed to call this method
    /// @param recipient Initial recipient of the credit
    /// @param tokensToSell Amount of tokens to sell for credit [wad]
    /// @param bid Starting bid (in credit) of the auction [wad]
    /// @return auctionId Id of the started debt auction
    function startAuction(
        address recipient,
        uint256 tokensToSell,
        uint256 bid
    ) external override checkCaller returns (uint256 auctionId) {
        if (live == 0) revert DebtAuction__startAuction_notLive();
        if (auctionCounter >= type(uint256).max) revert DebtAuction__startAuction_overflow();
        unchecked {
            auctionId = ++auctionCounter;
        }

        auctions[auctionId].bid = bid;
        auctions[auctionId].tokensToSell = tokensToSell;
        auctions[auctionId].recipient = recipient;
        auctions[auctionId].auctionExpiry = add48(uint48(block.timestamp), uint48(auctionDuration));

        emit StartAuction(auctionId, tokensToSell, bid, recipient);
    }

    /// @notice Resets an existing debt auction
    /// @dev Auction expiry has to be exceeded and no bids have to be made
    /// @param auctionId Id of the auction to reset
    function redoAuction(uint256 auctionId) external override {
        if (auctions[auctionId].auctionExpiry >= block.timestamp) revert DebtAuction__redoAuction_notFinished();
        if (auctions[auctionId].bidExpiry != 0) revert DebtAuction__redoAuction_bidAlreadyPlaced();
        auctions[auctionId].tokensToSell = mul(tokenToSellBump, auctions[auctionId].tokensToSell) / WAD;
        auctions[auctionId].auctionExpiry = add48(uint48(block.timestamp), auctionDuration);
    }

    /// @notice Bid for the fixed credit amount (`bid`) by accepting a lower amount of `tokensToSell`
    /// @param auctionId Id of the debt auction
    /// @param tokensToSell Amount of tokens to receive (has to be lower than prev. bid)
    /// @param bid Amount of credit to pay for tokens (has to match)
    function submitBid(
        uint256 auctionId,
        uint256 tokensToSell,
        uint256 bid
    ) external override {
        if (live == 0) revert DebtAuction__submitBid_notLive();
        if (auctions[auctionId].recipient == address(0)) revert DebtAuction__submitBid_recipientNotSet();
        if (auctions[auctionId].bidExpiry <= block.timestamp && auctions[auctionId].bidExpiry != 0)
            revert DebtAuction__submitBid_expired();
        if (auctions[auctionId].auctionExpiry <= block.timestamp)
            revert DebtAuction__submitBid_alreadyFinishedAuctionExpiry();

        if (bid != auctions[auctionId].bid) revert DebtAuction__submitBid_notMatchingBid();
        if (tokensToSell >= auctions[auctionId].tokensToSell) revert DebtAuction__submitBid_tokensToSellNotLower();
        if (mul(minBidBump, tokensToSell) > mul(auctions[auctionId].tokensToSell, WAD))
            revert DebtAuction__submitBid_insufficientDecrease();

        if (msg.sender != auctions[auctionId].recipient) {
            codex.transferCredit(msg.sender, auctions[auctionId].recipient, bid);

            // on first submitBid, clear as much debtOnAuction as possible
            if (auctions[auctionId].bidExpiry == 0) {
                uint256 debtOnAuction = IAer(auctions[auctionId].recipient).debtOnAuction();
                IAer(auctions[auctionId].recipient).settleAuctionedDebt(min(bid, debtOnAuction));
            }

            auctions[auctionId].recipient = msg.sender;
        }

        auctions[auctionId].tokensToSell = tokensToSell;
        auctions[auctionId].bidExpiry = add48(uint48(block.timestamp), bidDuration);
    }

    /// @notice Closes a finished auction and transfers tokens to the winning bidders
    /// @param auctionId Id of the debt auction to close
    function closeAuction(uint256 auctionId) external override {
        if (live == 0) revert DebtAuction__closeAuction_notLive();
        if (
            !(auctions[auctionId].bidExpiry != 0 &&
                (auctions[auctionId].bidExpiry < block.timestamp ||
                    auctions[auctionId].auctionExpiry < block.timestamp))
        ) revert DebtAuction__closeAuction_notFinished();
        token.transfer(auctions[auctionId].recipient, auctions[auctionId].tokensToSell);
        delete auctions[auctionId];
    }

    /// ======== Shutdown ======== ///

    /// @notice Locks the contract and sets the address of Aer
    /// @dev Sender has to be allowed to call this method
    function lock() external override checkCaller {
        live = 0;
        aer = msg.sender;
    }

    /// @notice Cancels an existing auction by minting new credit directly to the auctions recipient
    /// @dev Can only be called when the contract is locked
    /// @param auctionId Id of the debt auction to cancel
    function cancelAuction(uint256 auctionId) external override {
        if (live == 1) revert DebtAuction__cancelAuction_stillLive();
        if (auctions[auctionId].recipient == address(0)) revert DebtAuction__cancelAuction_recipientNotSet();
        codex.createUnbackedDebt(aer, auctions[auctionId].recipient, auctions[auctionId].bid);
        delete auctions[auctionId];
    }
}
