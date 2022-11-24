// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IPriceCalculator} from "../interfaces/IPriceCalculator.sol";
import {NoLossCollateralAuction} from "../core/auctions/NoLossCollateralAuction.sol";
import {LinearDecrease} from "../core/auctions/PriceCalculator.sol";
import {WAD} from "../core/utils/Math.sol";

import {Delayed} from "./Delayed.sol";
import {BaseGuard} from "./BaseGuard.sol";

/// @title AuctionGuard
/// @notice Contract which guards parameter updates for `CollateralAuction`
contract AuctionGuard is BaseGuard {
    /// ======== Custom Errors ======== ///

    error AuctionGuard__isGuard_cantCall();

    /// ======== Storage ======== ///

    /// @notice Address of CollateralAuction
    NoLossCollateralAuction public immutable collateralAuction;

    constructor(
        address senatus,
        address guardian,
        uint256 delay,
        address collateralAuction_
    ) BaseGuard(senatus, guardian, delay) {
        collateralAuction = NoLossCollateralAuction(collateralAuction_);
    }

    function isGuard() external view override returns (bool) {
        if (!collateralAuction.canCall(collateralAuction.ANY_SIG(), address(this)))
            revert AuctionGuard__isGuard_cantCall();
        return true;
    }

    /// ======== Capabilities ======== ///

    /// @notice Sets the `feeTip` parameter on CollateralAuction
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param feeTip See. CollateralAuction
    function setFeeTip(uint256 feeTip) external isGuardian {
        _inRange(feeTip, 0, 1 * WAD);
        collateralAuction.setParam("feeTip", feeTip);
    }

    /// @notice Sets the `flatTip` parameter on CollateralAuction
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param flatTip See. CollateralAuction
    function setFlatTip(uint256 flatTip) external isGuardian {
        _inRange(flatTip, 0, 10_000 * WAD);
        collateralAuction.setParam("flatTip", flatTip);
    }

    /// @notice Sets the `level` parameter on CollateralAuction
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param level See. CollateralAuction
    function setStopped(uint256 level) external isGuardian {
        _inRange(level, 0, 3);
        collateralAuction.setParam("stopped", level);
    }

    /// @notice Sets the `limes` parameter on CollateralAuction after the `delay` has passed.
    /// @dev Can only be called by the guardian. After `delay` has passed it can be `execute`'d.
    /// @param limes See. CollateralAuction
    function setLimes(address limes) external isDelayed {
        collateralAuction.setParam("limes", limes);
    }

    /// @notice Sets the `aer` parameter on CollateralAuction after the `delay` has passed.
    /// @dev Can only be called by the guardian. After `delay` has passed it can be `execute`'d.
    /// @param aer See. CollateralAuction
    function setAer(address aer) external isDelayed {
        collateralAuction.setParam("aer", aer);
    }

    /// @notice Sets the `multiplier` parameter on CollateralAuction
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param multiplier See. CollateralAuction
    function setMultiplier(address vault, uint256 multiplier) external isGuardian {
        _inRange(multiplier, 0.9e18, 2 * WAD);
        collateralAuction.setParam(vault, "multiplier", multiplier);
    }

    /// @notice Sets the `maxAuctionDuration` parameter on CollateralAuction and updates the `duration`
    /// on corresponding PriceCalculator
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param maxAuctionDuration See. CollateralAuction
    function setMaxAuctionDuration(address vault, uint256 maxAuctionDuration) external isGuardian {
        _inRange(maxAuctionDuration, 3 hours, 30 days);
        collateralAuction.setParam(vault, "maxAuctionDuration", maxAuctionDuration);
        (, , , , IPriceCalculator calculator) = collateralAuction.vaults(vault);
        LinearDecrease(address(calculator)).setParam("duration", maxAuctionDuration);
    }

    /// @notice Sets the `collybus` parameter on CollateralAuction after the `delay` has passed.
    /// @dev Can only be called by the guardian. After `delay` has passed it can be `execute`'d.
    /// @param vault Address of the vault for which to set the parameter
    /// @param collybus See. CollateralAuction
    function setCollybus(address vault, address collybus) external isDelayed {
        collateralAuction.setParam(vault, "collybus", collybus);
    }

    /// @notice Sets the `calculator` parameter on CollateralAuction after the `delay` has passed.
    /// @dev Can only be called by the guardian. After `delay` has passed it can be `execute`'d.
    /// @param vault Address of the vault for which to set the parameter
    /// @param calculator See. CollateralAuction
    function setCalculator(address vault, address calculator) external isDelayed {
        collateralAuction.setParam(vault, "calculator", calculator);
    }
}
