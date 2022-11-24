// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2020 Maker Ecosystem Growth Holdings, INC.
pragma solidity ^0.8.4;

import {IPriceCalculator} from "../../interfaces/IPriceCalculator.sol";

import {Guarded} from "../utils/Guarded.sol";
import {WAD, sub, wmul, wdiv, wpow} from "../utils/Math.sol";

/// @title LinearDecrease
/// @notice Implements a linear decreasing price curve for the collateral auction
/// Uses LinearDecrease.sol from DSS (MakerDAO) as a blueprint
/// Changes from LinearDecrease.sol /:
/// - only WAD precision is used (no RAD and RAY)
/// - uses a method signature based authentication scheme
/// - supports ERC1155, ERC721 style assets by TokenId
contract LinearDecrease is Guarded, IPriceCalculator {
    /// ======== Custom Errors ======== ///

    error LinearDecrease__setParam_unrecognizedParam();

    /// ======== Storage ======== ///

    /// @notice Seconds after auction start when the price reaches zero [seconds]
    uint256 public duration;

    /// ======== Events ======== ///

    event SetParam(bytes32 indexed param, uint256 data);

    constructor() Guarded() {}

    /// ======== Configuration ======== ///

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(bytes32 param, uint256 data) external checkCaller {
        if (param == "duration") duration = data;
        else revert LinearDecrease__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// ======== Pricing ======== ///

    /// @notice Price calculation when price is decreased linearly in proportion to time:
    /// @dev `duration` The number of seconds after the start of the auction where the price will hit 0
    /// Note the internal call to mul multiples by WAD, thereby ensuring that the wmul calculation
    /// which utilizes startPrice and duration (WAD values) is also a WAD value.
    /// @param startPrice: Initial price [wad]
    /// @param time Current seconds since the start of the auction [seconds]
    /// @return Returns y = startPrice * ((duration - time) / duration)
    function price(uint256 startPrice, uint256 time) external view override returns (uint256) {
        if (time >= duration) return 0;
        return wmul(startPrice, wdiv(sub(duration, time), duration));
    }
}

/// @title StairstepExponentialDecrease
/// @notice Implements a stairstep like exponential decreasing price curve for the collateral auction
/// Uses StairstepExponentialDecrease.sol from DSS (MakerDAO) as a blueprint
/// Changes from StairstepExponentialDecrease.sol /:
/// - only WAD precision is used (no RAD and RAY)
/// - uses a method signature based authentication scheme
/// - supports ERC1155, ERC721 style assets by TokenId
contract StairstepExponentialDecrease is Guarded, IPriceCalculator {
    /// ======== Custom Errors ======== ///

    error StairstepExponentialDecrease__setParam_factorGtWad();
    error StairstepExponentialDecrease__setParam_unrecognizedParam();

    /// ======== Storage ======== ///
    /// @notice Length of time between price drops [seconds]
    uint256 public step;
    /// @notice Per-step multiplicative factor [wad]
    uint256 public factor;

    /// ======== Events ======== ///

    event SetParam(bytes32 indexed param, uint256 data);

    // `factor` and `step` values must be correctly set for this contract to return a valid price
    constructor() Guarded() {}

    /// ======== Configuration ======== ///

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(bytes32 param, uint256 data) external checkCaller {
        if (param == "factor") {
            if (data > WAD) revert StairstepExponentialDecrease__setParam_factorGtWad();
            factor = data;
        } else if (param == "step") step = data;
        else revert StairstepExponentialDecrease__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// ======== Pricing ======== ///

    /// @notice Price calculation when price is decreased stairstep like, exponential in proportion to time:
    /// @dev `step` seconds between a price drop,
    /// `factor` factor encodes the percentage to decrease per step.
    ///   For efficiency, the values is set as (1 - (% value / 100)) * WAD
    ///   So, for a 1% decrease per step, factor would be (1 - 0.01) * WAD
    /// @param startPrice: Initial price [wad]
    /// @param time Current seconds since the start of the auction [seconds]
    /// @return Returns startPrice * (factor ^ time)
    function price(uint256 startPrice, uint256 time) external view override returns (uint256) {
        return wmul(startPrice, wpow(factor, time / step, WAD));
    }
}

/// @title ExponentialDecrease
/// @notice Implements a linear decreasing price curve for the collateral auction
/// While an equivalent function can be obtained by setting step = 1 in StairstepExponentialDecrease,
/// this continous (i.e. per-second) exponential decrease has be implemented as it is more gas-efficient
/// than using the stairstep version with step = 1 (primarily due to 1 fewer SLOAD per price calculation).
///
/// Uses ExponentialDecrease.sol from DSS (MakerDAO) as a blueprint
/// Changes from ExponentialDecrease.sol /:
/// - only WAD precision is used (no RAD and RAY)
/// - uses a method signature based authentication scheme
/// - supports ERC1155, ERC721 style assets by TokenId
contract ExponentialDecrease is Guarded, IPriceCalculator {
    /// ======== Custom Errors ======== ///

    error ExponentialDecrease__setParam_factorGtWad();
    error ExponentialDecrease__setParam_unrecognizedParam();

    /// ======== Storage ======== ///

    /// @notice Per-second multiplicative factor [wad]
    uint256 public factor;

    /// ======== Events ======== ///

    event SetParam(bytes32 indexed param, uint256 data);

    // `factor` value must be correctly set for this contract to return a valid price
    constructor() Guarded() {}

    /// ======== Configuration ======== ///

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(bytes32 param, uint256 data) external checkCaller {
        if (param == "factor") {
            if (data > WAD) revert ExponentialDecrease__setParam_factorGtWad();
            factor = data;
        } else revert ExponentialDecrease__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// ======== Pricing ======== ///

    /// @notice Price calculation when price is decreased exponentially in proportion to time:
    /// @dev `factor`: factor encodes the percentage to decrease per second.
    ///   For efficiency, the values is set as (1 - (% value / 100)) * WAD
    ///   So, for a 1% decrease per second, factor would be (1 - 0.01) * WAD
    /// @param startPrice: Initial price [wad]
    /// @param time Current seconds since the start of the auction [seconds]
    /// @return Returns startPrice * (factor ^ time)
    function price(uint256 startPrice, uint256 time) external view override returns (uint256) {
        return wmul(startPrice, wpow(factor, time, WAD));
    }
}
