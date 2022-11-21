// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Collybus} from "../core/Collybus.sol";
import {WAD} from "../core/utils/Math.sol";

import {Delayed} from "./Delayed.sol";
import {BaseGuard} from "./BaseGuard.sol";

/// @title CollybusGuard
/// @notice Contract which guards parameter updates for `Collybus`
contract CollybusGuard is BaseGuard {
    /// ======== Custom Errors ======== ///

    error CollybusGuard__isGuard_cantCall();

    /// ======== Storage ======== ///

    /// @notice Address of Collybus
    Collybus public immutable collybus;

    constructor(
        address senatus,
        address guardian,
        uint256 delay,
        address collybus_
    ) BaseGuard(senatus, guardian, delay) {
        collybus = Collybus(collybus_);
    }

    /// @notice See `BaseGuard`
    function isGuard() external view override returns (bool) {
        if (!collybus.canCall(collybus.ANY_SIG(), address(this))) revert CollybusGuard__isGuard_cantCall();
        return true;
    }

    /// ======== Capabilities ======== ///

    /// @notice Sets the `liquidationRatio` parameter on Collybus
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param vault Address of the vault for which to set the parameter
    /// @param liquidationRatio See. Collybus
    function setLiquidationRatio(address vault, uint128 liquidationRatio) external isGuardian {
        _inRange(liquidationRatio, WAD, 2 * WAD);
        collybus.setParam(vault, "liquidationRatio", liquidationRatio);
    }

    /// @notice Sets the `defaultRateId` parameter on Collybus
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param vault Address of the vault for which to set the parameter
    /// @param defaultRateId See. Collybus
    function setDefaultRateId(address vault, uint128 defaultRateId) external isGuardian {
        collybus.setParam(vault, "defaultRateId", defaultRateId);
    }

    /// @notice Sets the `rateId` parameter on Collybus
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param vault Address of the vault for which to set the parameter
    /// @param tokenId TokenId for which to set the parameter
    /// @param rateId See. Collybus
    function setRateId(
        address vault,
        uint256 tokenId,
        uint256 rateId
    ) external isGuardian {
        collybus.setParam(vault, tokenId, "rateId", rateId);
    }

    /// @notice Sets the `spotRelayer` parameter on Collybus after the `delay` has passed.
    /// @dev Can only be called by the guardian. After `delay` has passed it can be `execute`'d.
    /// @param spotRelayer See. Collybus
    function setSpotRelayer(address spotRelayer) external isDelayed {
        collybus.allowCaller(Collybus.updateSpot.selector, spotRelayer);
    }

    /// @notice Unsets the `spotRelayer` parameter on Collybus after the `delay` has passed.
    /// @dev Can only be called by the guardian. After `delay` has passed it can be `execute`'d.
    /// @param spotRelayer See. Collybus
    function unsetSpotRelayer(address spotRelayer) external isDelayed {
        collybus.blockCaller(Collybus.updateSpot.selector, spotRelayer);
    }

    /// @notice Sets the `discountRateRelayer` parameter on Collybus after the `delay` has passed.
    /// @dev Can only be called by the guardian. After `delay` has passed it can be `execute`'d.
    /// @param discountRateRelayer See. Collybus
    function setDiscountRateRelayer(address discountRateRelayer) external isDelayed {
        collybus.allowCaller(Collybus.updateDiscountRate.selector, discountRateRelayer);
    }

    /// @notice Unsets the `discountRateRelayer` parameter on Collybus after the `delay` has passed.
    /// @dev Can only be called by the guardian. After `delay` has passed it can be `execute`'d.
    /// @param discountRateRelayer See. Collybus
    function unsetDiscountRateRelayer(address discountRateRelayer) external isDelayed {
        collybus.blockCaller(Collybus.updateDiscountRate.selector, discountRateRelayer);
    }
}
