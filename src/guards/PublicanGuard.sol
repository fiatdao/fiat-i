// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Publican} from "../core/Publican.sol";
import {WAD} from "../core/utils/Math.sol";

import {Delayed} from "./Delayed.sol";
import {BaseGuard} from "./BaseGuard.sol";

/// @title PublicanGuard
/// @notice Contract which guards parameter updates for `Publican`
contract PublicanGuard is BaseGuard {
    /// ======== Custom Errors ======== ///

    error PublicanGuard__isGuard_cantCall();

    /// ======== Storage ======== ///

    /// @notice Address of Publican
    Publican public immutable publican;

    constructor(
        address senatus,
        address guardian,
        uint256 delay,
        address publican_
    ) BaseGuard(senatus, guardian, delay) {
        publican = Publican(publican_);
    }

    /// @notice See `BaseGuard`
    function isGuard() external view override returns (bool) {
        if (!publican.canCall(publican.ANY_SIG(), address(this))) revert PublicanGuard__isGuard_cantCall();
        return true;
    }

    /// ======== Capabilities ======== ///

    /// @notice Sets the `aer` parameter on Publican after the `delay` has passed.
    /// @dev Can only be called by the guardian. After `delay` has passed it can be `execute`'d.
    /// @param aer See. Publican
    function setAer(address aer) external isDelayed {
        publican.setParam("aer", aer);
    }

    /// @notice Sets the `baseInterest` parameter on Publican
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param baseInterest See. Publican
    function setBaseInterest(uint256 baseInterest) external isGuardian {
        _inRange(baseInterest, WAD, 1000000006341958396); // 0 - 20%
        publican.setParam("baseInterest", baseInterest);
    }

    /// @notice Sets the `interestPerSecond` parameter on Publican
    /// @dev Can only be called by the guardian. Checks if the value is in the allowed range.
    /// @param vault Address of the vault for which to set the parameter
    /// @param interestPerSecond See. Publican
    function setInterestPerSecond(address vault, uint256 interestPerSecond) external isGuardian {
        _inRange(interestPerSecond, WAD, 1000000006341958396); // 0 - 20%
        publican.setParam(vault, "interestPerSecond", interestPerSecond);
    }
}
