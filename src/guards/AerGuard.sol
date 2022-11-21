// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Aer} from "../core/Aer.sol";
import {WAD} from "../core/utils/Math.sol";

import {BaseGuard} from "./BaseGuard.sol";

/// @title AerGuard
/// @notice Contract which guards parameter updates for `Aer`
contract AerGuard is BaseGuard {
    /// ======== Custom Errors ======== ///

    error AerGuard__isGuard_cantCall();

    /// ======== Storage ======== ///

    /// @notice Address of Aer
    Aer public immutable aer;

    constructor(
        address senatus,
        address guardian,
        uint256 delay,
        address aer_
    ) BaseGuard(senatus, guardian, delay) {
        aer = Aer(aer_);
    }

    /// @notice See `BaseGuard`
    function isGuard() external view override returns (bool) {
        if (!aer.canCall(aer.ANY_SIG(), address(this))) revert AerGuard__isGuard_cantCall();
        return true;
    }

    /// ======== Capabilities ======== ///

    /// @notice Sets the `auctionDelay` parameter on Aer
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param auctionDelay See. Aer
    function setAuctionDelay(uint256 auctionDelay) external isGuardian {
        _inRange(auctionDelay, 0, 7 days);
        aer.setParam("auctionDelay", auctionDelay);
    }

    /// @notice Sets the `surplusAuctionSellSize` parameter on Aer
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param surplusAuctionSellSize See. Aer
    function setSurplusAuctionSellSize(uint256 surplusAuctionSellSize) external isGuardian {
        _inRange(surplusAuctionSellSize, 0, 200_000 * WAD);
        aer.setParam("surplusAuctionSellSize", surplusAuctionSellSize);
    }

    /// @notice Sets the `debtAuctionBidSize` parameter on Aer
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param debtAuctionBidSize See. Aer
    function setDebtAuctionBidSize(uint256 debtAuctionBidSize) external isGuardian {
        _inRange(debtAuctionBidSize, 0, 200_000 * WAD);
        aer.setParam("debtAuctionBidSize", debtAuctionBidSize);
    }

    /// @notice Sets the `debtAuctionSellSize` parameter on Aer
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param debtAuctionSellSize See. Aer
    function setDebtAuctionSellSize(uint256 debtAuctionSellSize) external isGuardian {
        _inRange(debtAuctionSellSize, 0, 200_000 * WAD);
        aer.setParam("debtAuctionSellSize", debtAuctionSellSize);
    }

    /// @notice Sets the `surplusBuffer` parameter on Aer
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param surplusBuffer See. Aer
    function setSurplusBuffer(uint256 surplusBuffer) external isGuardian {
        _inRange(surplusBuffer, 0, 1_000_000 * WAD);
        aer.setParam("surplusBuffer", surplusBuffer);
    }

    /// @notice Sets the `surplusAuction` parameter on Aer after the `delay` has passed.
    /// @dev Can only be called by the guardian. After `delay` has passed it can be `execute`'d.
    /// @param surplusAuction See. Aer
    function setSurplusAuction(address surplusAuction) external isDelayed {
        aer.setParam("surplusAuction", surplusAuction);
    }

    /// @notice Sets the `debtAuction` parameter on Aer after the `delay` has passed.
    /// @dev Can only be called by the guardian. After `delay` has passed it can be `execute`'d.
    /// @param debtAuction See. Aer
    function setDebtAuction(address debtAuction) external isDelayed {
        aer.setParam("debtAuction", debtAuction);
    }
}
