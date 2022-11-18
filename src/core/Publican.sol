// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2018 Rain <rainbreak@riseup.net>
pragma solidity ^0.8.4;

import {IAer} from "../interfaces/IAer.sol";
import {ICodex} from "../interfaces/ICodex.sol";
import {IPublican} from "../interfaces/IPublican.sol";

import {Guarded} from "./utils/Guarded.sol";
import {WAD, diff, add, sub, wmul, wpow} from "./utils/Math.sol";

/// @title Publican
/// @notice `Publican` is responsible for setting the debt interest rate and collecting interest
/// Uses Jug.sol from DSS (MakerDAO) / TaxCollector.sol from GEB (Reflexer Labs) as a blueprint
/// Changes from Jug.sol / TaxCollector.sol:
/// - only WAD precision is used (no RAD and RAY)
/// - uses a method signature based authentication scheme
/// - configuration by Vaults
contract Publican is Guarded, IPublican {
    /// ======== Custom Errors ======== ///

    error Publican__init_vaultAlreadyInit();
    error Publican__setParam_notCollected();
    error Publican__setParam_unrecognizedParam();
    error Publican__collect_invalidBlockTimestamp();

    /// ======== Storage ======== ///

    // Vault specific configuration data
    struct VaultConfig {
        // Collateral-specific, per-second stability fee contribution [wad]
        uint256 interestPerSecond;
        // Time of last drip [unix epoch time]
        uint256 lastCollected;
    }

    /// @notice Vault Configs
    /// @dev Vault => Vault Config
    mapping(address => VaultConfig) public override vaults;

    /// @notice Codex
    ICodex public immutable override codex;
    /// @notice Aer
    IAer public override aer;

    /// @notice Global, per-second stability fee contribution [wad]
    uint256 public override baseInterest;

    /// ======== Events ======== ///
    event Init(address indexed vault);
    event SetParam(bytes32 indexed param, uint256);
    event SetParam(bytes32 indexed param, address indexed data);
    event SetParam(address indexed vault, bytes32 indexed param, uint256 data);
    event Collect(address indexed vault);

    constructor(address codex_) Guarded() {
        codex = ICodex(codex_);
    }

    /// ======== Configuration ======== ///

    /// @notice Initializes a new Vault
    /// @dev Sender has to be allowed to call this method
    /// @param vault Address of the Vault
    function init(address vault) external override checkCaller {
        VaultConfig storage v = vaults[vault];
        if (v.interestPerSecond != 0) revert Publican__init_vaultAlreadyInit();
        v.interestPerSecond = WAD;
        v.lastCollected = block.timestamp;
        emit Init(vault);
    }

    /// @notice Sets various variables for a Vault
    /// @dev Sender has to be allowed to call this method
    /// @param vault Address of the Vault
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(
        address vault,
        bytes32 param,
        uint256 data
    ) external override checkCaller {
        if (block.timestamp != vaults[vault].lastCollected) revert Publican__setParam_notCollected();
        if (param == "interestPerSecond") vaults[vault].interestPerSecond = data;
        else revert Publican__setParam_unrecognizedParam();
        emit SetParam(vault, param, data);
    }

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(bytes32 param, uint256 data) external override checkCaller {
        if (param == "baseInterest") baseInterest = data;
        else revert Publican__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [address]
    function setParam(bytes32 param, address data) external override checkCaller {
        if (param == "aer") aer = IAer(data);
        else revert Publican__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// ======== Interest Rates ======== ///

    /// @notice Returns the up to date rate (virtual rate) for a given vault as the rate stored in Codex
    /// might be outdated
    /// @param vault Address of the Vault
    /// @return rate Virtual rate
    function virtualRate(address vault) external view override returns (uint256 rate) {
        (, uint256 prev, , ) = codex.vaults(vault);
        if (block.timestamp < vaults[vault].lastCollected) return prev;
        rate = wmul(
            wpow(
                add(baseInterest, vaults[vault].interestPerSecond),
                sub(block.timestamp, vaults[vault].lastCollected),
                WAD
            ),
            prev
        );
    }

    /// @notice Collects accrued interest from all Position on a Vault by updating the Vault's rate
    /// @param vault Address of the Vault
    /// @return rate Set rate
    function collect(address vault) public override returns (uint256 rate) {
        if (block.timestamp < vaults[vault].lastCollected) revert Publican__collect_invalidBlockTimestamp();
        (, uint256 prev, , ) = codex.vaults(vault);
        rate = wmul(
            wpow(
                add(baseInterest, vaults[vault].interestPerSecond),
                sub(block.timestamp, vaults[vault].lastCollected),
                WAD
            ),
            prev
        );
        codex.modifyRate(vault, address(aer), diff(rate, prev));
        vaults[vault].lastCollected = block.timestamp;
        emit Collect(vault);
    }

    /// @notice Batches interest collection. See `collect(address vault)`.
    /// @param vaults_ Array of Vault addresses
    /// @return rates Set rates for each updated Vault
    function collectMany(address[] memory vaults_) external returns (uint256[] memory) {
        uint256[] memory rates = new uint256[](vaults_.length);
        for (uint256 i = 0; i < vaults_.length; i++) {
            rates[i] = collect(vaults_[i]);
        }
        return rates;
    }
}
