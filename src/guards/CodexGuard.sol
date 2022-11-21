// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2018-2020 Maker Ecosystem Growth Holdings, INC.
pragma solidity ^0.8.4;

import {INoLossCollateralAuction} from "../interfaces/INoLossCollateralAuction.sol";
import {Codex} from "../core/Codex.sol";
import {WAD, min, add, sub, wmul} from "../core/utils/Math.sol";

import {BaseGuard} from "./BaseGuard.sol";

/// @title CodexGuard
/// @notice Contract which guards parameter updates for `Codex`
contract CodexGuard is BaseGuard {
    /// ======== Custom Errors ======== ///

    error CodexGuard__isGuard_cantCall();
    error CodexGuard__addDebtCeilingAdjuster_invalidDelay();

    /// ======== Storage ======== ///

    struct DebtCeilingAdjuster {
        // Max. ceiling possible [wad]
        uint256 maxDebtCeiling;
        // Max. value between current debt and maxDebtCeiling to be set [wad]
        uint256 maxDelta;
        // Min. time to pass before a new increase [seconds]
        uint48 delay;
        // Last block the ceiling was updated [blocks]
        uint48 last;
        // Last time the ceiling was increased compared to its previous value [seconds]
        uint48 lastInc;
    }
    /// @notice Map of states defining the conditions according to which a vaults debt ceiling can be updated
    /// Address of Vault => DebtCeilingAdjuster
    mapping(address => DebtCeilingAdjuster) public debtCeilingAdjusters;

    /// @notice Address of Codex
    Codex public immutable codex;

    constructor(
        address senatus,
        address guardian,
        uint256 delay,
        address codex_
    ) BaseGuard(senatus, guardian, delay) {
        codex = Codex(codex_);
    }

    /// @notice See `BaseGuard`
    function isGuard() external view override returns (bool) {
        if (!codex.canCall(codex.ANY_SIG(), address(this))) revert CodexGuard__isGuard_cantCall();
        return true;
    }

    /// ======== Capabilities ======== ///

    /// @notice Updates the debt ceiling adjuster function for a vault
    /// @dev Can only be called by Senatus
    /// @param vault Address of the vault for which to set the adjuster
    /// @param maxDelta Max. amount by which the vaults debt ceiling can be adjusted at a given time [wad]
    /// @param delay Min. time between debt ceiling adjustments [seconds]
    function setDebtCeilingAdjuster(
        address vault,
        uint256 maxDebtCeiling,
        uint256 maxDelta,
        uint256 delay
    ) external isSenatus {
        if (maxDebtCeiling == 0) maxDebtCeiling = 10_000_000 * WAD;
        if (delay >= type(uint48).max) revert CodexGuard__addDebtCeilingAdjuster_invalidDelay();
        debtCeilingAdjusters[vault] = DebtCeilingAdjuster(maxDebtCeiling, maxDelta, uint48(delay), 0, 0);
    }

    /// @notice Removes the debt ceiling adjuster for a vault
    /// @dev Can only be called by Senatus
    /// @param vault Address of the vault for which to remove the debt ceiling adjuster
    function removeDebtCeilingAdjuster(address vault) external isSenatus {
        delete debtCeilingAdjusters[vault];
    }

    /// @notice Sets the `debtceiling` parameter on Codex
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param vault Address of the vault for which to adjust the debt ceiling
    function setDebtCeiling(address vault) external returns (uint256) {
        (uint256 totalNormalDebt, uint256 rate, uint256 currentDebtCeiling, ) = codex.vaults(vault);
        DebtCeilingAdjuster memory dca = debtCeilingAdjusters[vault];

        // return if the vault is not enabled
        if (dca.maxDebtCeiling == 0) return currentDebtCeiling;
        // return if there was already an update in the same block
        if (dca.last == block.number) return currentDebtCeiling;

        // calculate debt
        uint256 debt = wmul(totalNormalDebt, rate);
        // calculate new debtCeiling based on the minimum between maxDebtCeiling and actual debt + maxDelta
        uint256 debtCeiling = min(add(debt, dca.maxDelta), dca.maxDebtCeiling);

        // short-circuit if there wasn't an update or if the time since last increment has not passed
        if (
            debtCeiling == currentDebtCeiling ||
            (debtCeiling > currentDebtCeiling && block.timestamp < add(dca.lastInc, dca.delay))
        ) return currentDebtCeiling;

        // set debt ceiling
        codex.setParam(vault, "debtCeiling", debtCeiling);
        // set global debt ceiling
        codex.setParam("globalDebtCeiling", add(sub(codex.globalDebtCeiling(), currentDebtCeiling), debtCeiling));

        // update lastInc if it is an increment in the debt ceiling
        // and update last whatever the update is
        if (debtCeiling > currentDebtCeiling) {
            debtCeilingAdjusters[vault].lastInc = uint48(block.timestamp);
            debtCeilingAdjusters[vault].last = uint48(block.number);
        } else {
            debtCeilingAdjusters[vault].last = uint48(block.number);
        }

        return debtCeiling;
    }

    /// @notice Sets the `debtFloor` parameter on Codex
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param vault Vault for which to set the parameter
    /// @param debtFloor See. Codex
    /// @param collateralAuctions Impacted CollateralAuction's for which `updateAuctionDebtFloor` has to be triggered
    function setDebtFloor(
        address vault,
        uint256 debtFloor,
        address[] calldata collateralAuctions
    ) external isGuardian {
        _inRange(debtFloor, 0, 10_000 * WAD);
        codex.setParam(vault, "debtFloor", debtFloor);
        // update auctionDebtFloor for the provided collateral auction contracts
        for (uint256 i = 0; i < collateralAuctions.length; i++) {
            INoLossCollateralAuction(collateralAuctions[i]).updateAuctionDebtFloor(vault);
        }
    }
}
