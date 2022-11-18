// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IGuard} from "../interfaces/IGuard.sol";

import {Delayed} from "./Delayed.sol";

abstract contract BaseGuard is Delayed, IGuard {
    /// ======== Custom Errors ======== ///

    error BaseGuard__isSenatus_notSenatus();
    error BaseGuard__isGuardian_notGuardian();
    error BaseGuard__isDelayed_notSelf(address, address);
    error BaseGuard__inRange_notInRange();

    /// ======== Storage ======== ///

    /// @notice Address of the DAO
    address public senatus;
    /// @notice Address of the guardian
    address public guardian;

    constructor(
        address senatus_,
        address guardian_,
        uint256 delay
    ) Delayed(delay) {
        senatus = senatus_;
        guardian = guardian_;
    }

    modifier isSenatus() {
        if (msg.sender != senatus) revert BaseGuard__isSenatus_notSenatus();
        _;
    }

    modifier isGuardian() {
        if (msg.sender != guardian) revert BaseGuard__isGuardian_notGuardian();
        _;
    }

    modifier isDelayed() {
        if (msg.sender != address(this)) revert BaseGuard__isDelayed_notSelf(msg.sender, address(this));
        _;
    }

    /// @notice Callback method which allows Guard to check if he has sufficient rights over the corresponding contract
    /// @return bool True if he has sufficient rights
    function isGuard() external view virtual override returns (bool);

    /// @notice Updates the address of senatus
    /// @dev Can only be called by Senatus
    /// @param senatus_ Address of the new senatus
    function setSenatus(address senatus_) external isSenatus {
        senatus = senatus_;
    }

    /// @notice Updates the address of the guardian
    /// @dev Can only be called by Senatus
    /// @param guardian_ Address of the new guardian
    function setGuardian(address guardian_) external isSenatus {
        guardian = guardian_;
    }

    /// ======== Capabilities ======== ///

    /// @notice Updates the time which has to elapse for certain parameter updates
    /// @dev Can only be called by Senatus
    /// @param delay Time which has to elapse before parameter can be updated [seconds]
    function setDelay(uint256 delay) external isSenatus {
        _setParam("delay", delay);
    }

    /// @notice Schedule method call for methods which have to be delayed
    /// @dev Can only be called by the guardian
    /// @param data Call data
    function schedule(bytes calldata data) external isGuardian {
        _delay(address(this), data, block.timestamp + delay);
    }

    /// ======== Helper Methods ======== ///

    /// @notice Checks if `value` is at least equal to `min_` or at most equal to `max`
    /// @dev Revers if check failed
    /// @param value Value to check
    /// @param min_ Min. value for `value`
    /// @param max Max. value for `value`
    function _inRange(
        uint256 value,
        uint256 min_,
        uint256 max
    ) internal pure {
        if (max < value || value < min_) revert BaseGuard__inRange_notInRange();
    }
}
