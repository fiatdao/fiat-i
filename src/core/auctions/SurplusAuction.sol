// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2018 Rain <rainbreak@riseup.net>
pragma solidity ^0.8.4;

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICodex} from "../../interfaces/ICodex.sol";
import {ISurplusAuction} from "../../interfaces/ISurplusAuction.sol";

import {Guarded} from "../utils/Guarded.sol";
import {WAD, add48, sub, mul} from "../utils/Math.sol";

/// @title SurplusAuction
/// @notice
/// Uses Flap.sol from DSS (MakerDAO) as a blueprint
/// Changes from Flap.sol:
/// - only WAD precision is used (no RAD and RAY)
/// - uses a method signature based authentication scheme
/// - supports ERC1155, ERC721 style assets by TokenId
contract SurplusAuction is Guarded, ISurplusAuction {
    using SafeERC20 for IERC20;
    /// ======== Custom Errors ======== ///

    error SurplusAuction__setParam_unrecognizedParam();
    error SurplusAuction__startAuction_notLive();
    error SurplusAuction__startAuction_overflow();
    error SurplusAuction__redoAuction_notFinished();
    error SurplusAuction__redoAuction_bidAlreadyPlaced();
    error SurplusAuction__submitBid_notLive();
    error SurplusAuction__submit_recipientNotSet();
    error SurplusAuction__submitBid_alreadyFinishedBidExpiry();
    error SurplusAuction__submitBid_alreadyFinishedAuctionExpiry();
    error SurplusAuction__submitBid_creditToSellNotMatching();
    error SurplusAuction__submitBid_bidNotHigher();
    error SurplusAuction__submitBid_insufficientIncrease();
    error SurplusAuction__closeAuction_notLive();
    error SurplusAuction__closeAuction_notFinished();
    error SurplusAuction__cancelAuction_stillLive();
    error SurplusAuction__cancelAuction_recipientNotSet();

    /// ======== Storage ======== ///

    // Auction State
    struct Auction {
        // tokens paid for credit [wad]
        uint256 bid;
        // amount of credit to sell for tokens (bid) [wad]
        uint256 creditToSell;
        // current highest bidder
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
    /// @notice Tokens to receive for credit
    IERC20 public immutable override token;
    /// @notice 5% minimum bid increase
    uint256 public override minBidBump = 1.05e18;
    /// @notice 3 hours bid duration [seconds]
    uint48 public override bidDuration = 3 hours;
    /// @notice 2 days total auction length [seconds]
    uint48 public override auctionDuration = 2 days;
    /// @notice Auction Counter
    uint256 public override auctionCounter = 0;

    /// @notice Boolean indicating if this contract is live (0 - not live, 1 - live)
    uint256 public override live;

    /// ======== Events ======== ///

    event StartAuction(uint256 id, uint256 creditToSell, uint256 bid);

    constructor(address codex_, address token_) Guarded() {
        codex = ICodex(codex_);
        token = IERC20(token_);
        live = 1;
    }

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(bytes32 param, uint256 data) external override checkCaller {
        if (param == "minBidBump") minBidBump = data;
        else if (param == "bidDuration") bidDuration = uint48(data);
        else if (param == "auctionDuration") auctionDuration = uint48(data);
        else revert SurplusAuction__setParam_unrecognizedParam();
    }

    /// ======== Surplus Auction ======== ///

    /// @notice Start a new surplus auction
    /// @dev Sender has to be allowed to call this method
    /// @param creditToSell Amount of credit to sell for tokens [wad]
    /// @param bid Starting bid (in tokens) of the auction [wad]
    /// @return auctionId Id of the started surplus auction
    function startAuction(uint256 creditToSell, uint256 bid) external override checkCaller returns (uint256 auctionId) {
        if (live == 0) revert SurplusAuction__startAuction_notLive();
        if (auctionCounter >= ~uint256(0)) revert SurplusAuction__startAuction_overflow();
        unchecked {
            auctionId = ++auctionCounter;
        }

        auctions[auctionId].bid = bid;
        auctions[auctionId].creditToSell = creditToSell;
        auctions[auctionId].recipient = msg.sender; // configurable??
        auctions[auctionId].auctionExpiry = add48(uint48(block.timestamp), auctionDuration);

        codex.transferCredit(msg.sender, address(this), creditToSell);

        emit StartAuction(auctionId, creditToSell, bid);
    }

    /// @notice Resets an existing surplus auction
    /// @dev Auction expiry has to be exceeded and no bids have to be made
    /// @param auctionId Id of the auction to reset
    function redoAuction(uint256 auctionId) external override {
        if (auctions[auctionId].auctionExpiry >= block.timestamp) revert SurplusAuction__redoAuction_notFinished();
        if (auctions[auctionId].bidExpiry != 0) revert SurplusAuction__redoAuction_bidAlreadyPlaced();
        auctions[auctionId].auctionExpiry = add48(uint48(block.timestamp), auctionDuration);
    }

    /// @notice Bid for the fixed credit amount (`creditToSell`) with a higher amount of tokens (`bid`)
    /// @param auctionId Id of the debt auction
    /// @param creditToSell Amount of credit to receive (has to match)
    /// @param bid Amount of tokens to pay for credit (has to be higher than prev. bid)
    function submitBid(
        uint256 auctionId,
        uint256 creditToSell,
        uint256 bid
    ) external override {
        if (live == 0) revert SurplusAuction__submitBid_notLive();
        if (auctions[auctionId].recipient == address(0)) revert SurplusAuction__submit_recipientNotSet();
        if (auctions[auctionId].bidExpiry <= block.timestamp && auctions[auctionId].bidExpiry != 0)
            revert SurplusAuction__submitBid_alreadyFinishedBidExpiry();
        if (auctions[auctionId].auctionExpiry <= block.timestamp)
            revert SurplusAuction__submitBid_alreadyFinishedAuctionExpiry();

        if (creditToSell != auctions[auctionId].creditToSell)
            revert SurplusAuction__submitBid_creditToSellNotMatching();
        if (bid <= auctions[auctionId].bid) revert SurplusAuction__submitBid_bidNotHigher();
        if (mul(bid, WAD) < mul(minBidBump, auctions[auctionId].bid))
            revert SurplusAuction__submitBid_insufficientIncrease();

        if (msg.sender != auctions[auctionId].recipient) {
            token.transferFrom(msg.sender, auctions[auctionId].recipient, auctions[auctionId].bid);
            auctions[auctionId].recipient = msg.sender;
        }
        token.transferFrom(msg.sender, address(this), sub(bid, auctions[auctionId].bid));

        auctions[auctionId].bid = bid;
        auctions[auctionId].bidExpiry = add48(uint48(block.timestamp), bidDuration);
    }

    /// @notice Closes a finished auction and mints new tokens to the winning bidders
    /// @param auctionId Id of the debt auction to close
    function closeAuction(uint256 auctionId) external override {
        if (live == 0) revert SurplusAuction__closeAuction_notLive();
        if (
            !(auctions[auctionId].bidExpiry != 0 &&
                (auctions[auctionId].bidExpiry < block.timestamp ||
                    auctions[auctionId].auctionExpiry < block.timestamp))
        ) revert SurplusAuction__closeAuction_notFinished();
        codex.transferCredit(address(this), auctions[auctionId].recipient, auctions[auctionId].creditToSell);
        ERC20Burnable(address(token)).burn(auctions[auctionId].bid);
        delete auctions[auctionId];
    }

    /// ======== Shutdown ======== ///

    /// @notice Locks the contract and transfer the credit in this contract to the caller
    /// @dev Sender has to be allowed to call this method
    function lock(uint256 credit) external override checkCaller {
        live = 0;
        codex.transferCredit(address(this), msg.sender, credit);
    }

    /// @notice Cancels an existing auction by returning the tokens bid to its bidder
    /// @dev Can only be called when the contract is locked
    /// @param auctionId Id of the surplus auction to cancel
    function cancelAuction(uint256 auctionId) external override {
        if (live == 1) revert SurplusAuction__cancelAuction_stillLive();
        if (auctions[auctionId].recipient == address(0)) revert SurplusAuction__cancelAuction_recipientNotSet();
        token.safeTransfer(auctions[auctionId].recipient, auctions[auctionId].bid);
        delete auctions[auctionId];
    }
}
