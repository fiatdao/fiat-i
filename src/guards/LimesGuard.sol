// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Limes} from "../core/Limes.sol";
import {WAD} from "../core/utils/Math.sol";

import {Delayed} from "./Delayed.sol";
import {BaseGuard} from "./BaseGuard.sol";

/// @title LimesGuard
/// @notice Contract which guards parameter updates for `Limes`
contract LimesGuard is BaseGuard {
    /// ======== Custom Errors ======== ///

    error LimesGuard__isGuard_cantCall();

    /// ======== Storage ======== ///

    /// @notice Address of Limes
    Limes public immutable limes;

    constructor(
        address senatus,
        address guardian,
        uint256 delay,
        address limes_
    ) BaseGuard(senatus, guardian, delay) {
        limes = Limes(limes_);
    }

    /// @notice See `BaseGuard`
    function isGuard() external view override returns (bool) {
        if (!limes.canCall(limes.ANY_SIG(), address(this))) revert LimesGuard__isGuard_cantCall();
        return true;
    }

    /// ======== Capabilities ======== ///

    /// @notice Sets the `aer` parameter on Limes after the `delay` has passed.
    /// @dev Can only be called by the guardian. After `delay` has passed it can be `execute`'d.
    /// @param aer See. Limes
    function setAer(address aer) external isDelayed {
        limes.setParam("aer", aer);
    }

    /// @notice Sets the `globalMaxDebtOnAuction` parameter on Limes
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param globalMaxDebtOnAuction See. Limes
    function setGlobalMaxDebtOnAuction(uint256 globalMaxDebtOnAuction) external isGuardian {
        _inRange(globalMaxDebtOnAuction, 0, 10_000_000 * WAD);
        limes.setParam("globalMaxDebtOnAuction", globalMaxDebtOnAuction);
    }

    /// @notice Sets the `liquidationPenalty` parameter on Limes
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param vault Address of the vault for which to set the parameter
    /// @param liquidationPenalty See. Limes
    function setLiquidationPenalty(address vault, uint256 liquidationPenalty) external isGuardian {
        _inRange(liquidationPenalty, WAD, 2 * WAD);
        limes.setParam(vault, "liquidationPenalty", liquidationPenalty);
    }

    /// @notice Sets the `maxDebtOnAuction` parameter on Limes
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param vault Address of the vault for which to set the parameter
    /// @param maxDebtOnAuction See. Limes
    function setMaxDebtOnAuction(address vault, uint256 maxDebtOnAuction) external isGuardian {
        _inRange(maxDebtOnAuction, 0, 5_000_000 * WAD);
        limes.setParam(vault, "maxDebtOnAuction", maxDebtOnAuction);
    }

    /// @notice Sets the `collateralAuction` parameter on Limes after the `delay` has passed.
    /// @dev Can only be called by the guardian. After `delay` has passed it can be `execute`'d.
    /// @param vault Address of the vault for which to set the parameter
    /// @param collateralAuction See. Limes
    function setCollateralAuction(address vault, address collateralAuction) external isDelayed {
        limes.setParam(vault, "collateralAuction", collateralAuction);
        limes.allowCaller(limes.liquidated.selector, collateralAuction);
    }
}
