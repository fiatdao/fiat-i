// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2018 Rain <rainbreak@riseup.net>
pragma solidity ^0.8.4;

import {ICodex} from "../interfaces/ICodex.sol";
import {IFIAT} from "../interfaces/IFIAT.sol";
import {IMoneta} from "../interfaces/IMoneta.sol";

import {Guarded} from "./utils/Guarded.sol";
import {WAD, wmul} from "./utils/Math.sol";

/// @title Moneta (FIAT Mint)
/// @notice The canonical mint for FIAT (Fixed Income Asset Token),
/// where users can redeem their internal credit for FIAT
contract Moneta is Guarded, IMoneta {
    /// ======== Custom Errors ======== ///

    error Moneta__exit_notLive();

    /// ======== Storage ======== ///

    /// @notice Codex
    ICodex public immutable override codex;
    /// @notice FIAT (Fixed Income Asset Token)
    IFIAT public immutable override fiat;

    /// @notice Boolean indicating if this contract is live (0 - not live, 1 - live)
    uint256 public override live;

    /// ======== Events ======== ///

    event Enter(address indexed user, uint256 amount);
    event Exit(address indexed user, uint256 amount);
    event Lock();

    constructor(address codex_, address fiat_) Guarded() {
        live = 1;
        codex = ICodex(codex_);
        fiat = IFIAT(fiat_);
    }

    /// ======== Redemption ======== ///

    /// @notice Redeems FIAT for internal credit
    /// @dev User has to set allowance for Moneta to burn FIAT
    /// @param user Address of the user
    /// @param amount Amount of FIAT to be redeemed for internal credit
    function enter(address user, uint256 amount) external override {
        codex.transferCredit(address(this), user, amount);
        fiat.burn(msg.sender, amount);
        emit Enter(user, amount);
    }

    /// @notice Redeems internal credit for FIAT
    /// @dev User has to grant the delegate of transferring credit to Moneta
    /// @param user Address of the user
    /// @param amount Amount of credit to be redeemed for FIAT
    function exit(address user, uint256 amount) external override {
        if (live == 0) revert Moneta__exit_notLive();
        codex.transferCredit(msg.sender, address(this), amount);
        fiat.mint(user, amount);
        emit Exit(user, amount);
    }

    /// ======== Shutdown ======== ///

    /// @notice Locks the contract
    /// @dev Sender has to be allowed to call this method
    function lock() external override checkCaller {
        live = 0;
        emit Lock();
    }
}
