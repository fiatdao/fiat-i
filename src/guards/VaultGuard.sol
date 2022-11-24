// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IVault} from "../interfaces/IVault.sol";
import {IGuarded} from "../interfaces/IGuarded.sol";

import {Codex} from "../core/Codex.sol";
import {Publican} from "../core/Publican.sol";
import {Limes} from "../core/Limes.sol";
import {Collybus} from "../core/Collybus.sol";
import {NoLossCollateralAuction} from "../core/auctions/NoLossCollateralAuction.sol";
import {LinearDecrease, StairstepExponentialDecrease, ExponentialDecrease} from "../core/auctions/PriceCalculator.sol";
import {WAD} from "../core/utils/Math.sol";

import {Delayed} from "./Delayed.sol";
import {BaseGuard} from "./BaseGuard.sol";

contract PriceCalculatorFactory {
    function newLinearDecrease(address owner) public returns (LinearDecrease priceCalculator) {
        priceCalculator = new LinearDecrease();
        priceCalculator.allowCaller(priceCalculator.ANY_SIG(), owner);
        priceCalculator.blockCaller(priceCalculator.ANY_SIG(), address(this));
    }

    function newStairstepExponentialDecrease(address owner)
        public
        returns (StairstepExponentialDecrease priceCalculator)
    {
        priceCalculator = new StairstepExponentialDecrease();
        priceCalculator.allowCaller(priceCalculator.ANY_SIG(), owner);
        priceCalculator.blockCaller(priceCalculator.ANY_SIG(), address(this));
    }

    function newExponentialDecrease(address owner) public returns (ExponentialDecrease priceCalculator) {
        priceCalculator = new ExponentialDecrease();
        priceCalculator.allowCaller(priceCalculator.ANY_SIG(), owner);
        priceCalculator.blockCaller(priceCalculator.ANY_SIG(), address(this));
    }
}

/// @title VaultGuard
/// @notice Contract which guards parameter updates for Vaults
contract VaultGuard is BaseGuard {
    /// ======== Custom Errors ======== ///

    error VaultGuard__isGuard_cantCall();
    error VaultGuard__setVault_cantCall();

    /// ======== Storage ======== ///

    PriceCalculatorFactory public priceCalculatorFactory;

    /// @notice Address of Codex
    Codex public codex;
    /// @notice Address of Publican
    Publican public publican;
    /// @notice Address of Limes
    Limes public limes;
    /// @notice Address of NoLossCollateralAuction
    NoLossCollateralAuction public collateralAuction;
    /// @notice Address of Collybus
    Collybus public collybus;

    constructor(
        address senatus,
        address guardian,
        uint256 delay,
        address codex_,
        address publican_,
        address limes_,
        address collybus_,
        address collateralAuction_,
        address priceCalculatorFactory_
    ) BaseGuard(senatus, guardian, delay) {
        codex = Codex(codex_);
        publican = Publican(publican_);
        limes = Limes(limes_);
        collybus = Collybus(collybus_);
        collateralAuction = NoLossCollateralAuction(collateralAuction_);
        priceCalculatorFactory = PriceCalculatorFactory(priceCalculatorFactory_);
    }

    /// @notice See `BaseGuard`
    function isGuard() external view override returns (bool) {
        if (
            !codex.canCall(codex.ANY_SIG(), address(this)) ||
            !publican.canCall(publican.ANY_SIG(), address(this)) ||
            !limes.canCall(limes.ANY_SIG(), address(this)) ||
            !collybus.canCall(collybus.ANY_SIG(), address(this)) ||
            !collateralAuction.canCall(collateralAuction.ANY_SIG(), address(this))
        ) revert VaultGuard__isGuard_cantCall();
        return true;
    }

    /// ======== Capabilities ======== ///

    /// @notice Sets the initial parameters for a Vault
    /// @dev Can only be called by the guardian
    /// @param vault Address of the vault to initialize
    /// @param auctionGuard Address of the AuctionGuard
    /// @param calculatorType PriceCalculator to use (LinearDecrease, StairstepExponentialDecrease, ExponentialDecrease)
    /// @param debtCeiling See Codex
    /// @param debtFloor See Codex
    /// @param interestPerSecond See Publican
    /// @param multiplier See CollateralAuction
    /// @param maxAuctionDuration See CollateralAuction
    /// @param liquidationRatio See Collybus
    /// @param liquidationPenalty See Limes
    /// @param maxDebtOnAuction See Limes
    function setVault(
        address vault,
        address auctionGuard,
        bytes32 calculatorType,
        uint256 debtCeiling,
        uint256 debtFloor,
        uint256 interestPerSecond,
        uint256 multiplier,
        uint256 maxAuctionDuration,
        uint128 liquidationRatio,
        uint256 liquidationPenalty,
        uint256 maxDebtOnAuction
    ) public isGuardian {
        if (!IGuarded(vault).canCall(IGuarded(vault).ANY_SIG(), address(this))) revert VaultGuard__setVault_cantCall();

        // fails if vault is already initialized
        codex.init(vault);
        publican.init(vault);

        codex.allowCaller(codex.modifyBalance.selector, vault);

        // deploy new PriceCalculator
        address calculator;
        if (calculatorType == "LinearDecrease") {
            LinearDecrease ld = priceCalculatorFactory.newLinearDecrease(address(this));
            calculator = address(ld);
            ld.setParam("duration", maxAuctionDuration);
            ld.allowCaller(ld.ANY_SIG(), auctionGuard);
        } else if (calculatorType == "StairstepExponentialDecrease") {
            StairstepExponentialDecrease sed = priceCalculatorFactory.newStairstepExponentialDecrease(address(this));
            calculator = address(sed);
            sed.setParam("duration", maxAuctionDuration);
            sed.allowCaller(sed.ANY_SIG(), auctionGuard);
        } else if (calculatorType == "ExponentialDecrease") {
            ExponentialDecrease ed = priceCalculatorFactory.newExponentialDecrease(address(this));
            calculator = address(ed);
            ed.setParam("duration", maxAuctionDuration);
            ed.allowCaller(ed.ANY_SIG(), auctionGuard);
        }

        // Internal references set up
        limes.setParam(vault, "collateralAuction", address(collateralAuction));
        collateralAuction.setParam(vault, "calculator", address(calculator));
        collateralAuction.setParam(vault, "collybus", address(collybus));

        // Config
        codex.setParam(vault, "debtCeiling", debtCeiling);
        codex.setParam(vault, "debtFloor", debtFloor);
        publican.setParam(vault, "interestPerSecond", interestPerSecond);
        collateralAuction.setParam(vault, "multiplier", multiplier);
        collateralAuction.setParam(vault, "maxAuctionDuration", maxAuctionDuration);
        collybus.setParam(vault, "liquidationRatio", liquidationRatio);

        limes.setParam(vault, "liquidationPenalty", liquidationPenalty);
        limes.setParam(vault, "maxDebtOnAuction", maxDebtOnAuction);

        collateralAuction.updateAuctionDebtFloor(vault);
    }

    /// @notice Locks a Vault
    /// @dev Can only be called by the guardian
    /// @param vault Address of the vault to lock
    function lockVault(address vault) public isGuardian {
        codex.blockCaller(codex.modifyBalance.selector, vault);
        IVault(vault).lock();
    }
}
