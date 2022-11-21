// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {PRBMathUD60x18} from "prb-math/contracts/PRBMathUD60x18.sol";

import {ICodex} from "../interfaces/ICodex.sol";
import {ICollybus} from "../interfaces/ICollybus.sol";

import {Guarded} from "./utils/Guarded.sol";
import {WAD, add, sub, wmul, wdiv} from "./utils/Math.sol";

/// @title Collybus
/// @notice `Collybus` stores a spot price and discount rate for every Vault / asset.
contract Collybus is Guarded, ICollybus {
    /// ======== Custom Errors ======== ///

    error Collybus__setParam_notLive();
    error Collybus__setParam_unrecognizedParam();
    error Collybus__updateSpot_notLive();
    error Collybus__updateDiscountRate_notLive();
    error Collybus__updateDiscountRate_invalidRateId();
    error Collybus__updateDiscountRate_invalidRate();

    using PRBMathUD60x18 for uint256;

    /// ======== Storage ======== ///

    struct VaultConfig {
        // Liquidation ratio [wad]
        uint128 liquidationRatio;
        // Default fixed interest rate oracle system rateId
        uint128 defaultRateId;
    }

    /// @notice Vault Configuration
    /// @dev Vault => Vault Config
    mapping(address => VaultConfig) public override vaults;
    /// @notice Spot prices by token address
    /// @dev Token address => spot price [wad]
    mapping(address => uint256) public override spots;
    /// @notice Fixed interest rate oracle system rateId
    /// @dev RateId => Discount Rate [wad]
    mapping(uint256 => uint256) public override rates;
    // Fixed interest rate oracle system rateId for each TokenId
    // Vault => TokenId => RateId
    mapping(address => mapping(uint256 => uint256)) public override rateIds;

    /// @notice Redemption Price of a Credit unit [wad]
    uint256 public immutable override redemptionPrice;

    /// @notice Boolean indicating if this contract is live (0 - not live, 1 - live)
    uint256 public override live;

    /// ======== Events ======== ///
    event SetParam(bytes32 indexed param, uint256 data);
    event SetParam(address indexed vault, bytes32 indexed param, uint256 data);
    event SetParam(address indexed vault, uint256 indexed tokenId, bytes32 indexed param, uint256 data);
    event UpdateSpot(address indexed token, uint256 spot);
    event UpdateDiscountRate(uint256 indexed rateId, uint256 rate);
    event Lock();

    // TODO: why not making timeScale and redemption price function arguments?
    constructor() Guarded() {
        redemptionPrice = WAD; // 1.0
        live = 1;
    }

    /// ======== Configuration ======== ///

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(bytes32 param, uint256 data) external override checkCaller {
        if (live == 0) revert Collybus__setParam_notLive();
        if (param == "live") live = data;
        else revert Collybus__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// @notice Sets various variables for a Vault
    /// @dev Sender has to be allowed to call this method
    /// @param vault Address of the Vault
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(
        address vault,
        bytes32 param,
        uint128 data
    ) external override checkCaller {
        if (live == 0) revert Collybus__setParam_notLive();
        if (param == "liquidationRatio") vaults[vault].liquidationRatio = data;
        else if (param == "defaultRateId") vaults[vault].defaultRateId = data;
        else revert Collybus__setParam_unrecognizedParam();
        emit SetParam(vault, param, data);
    }

    /// @notice Sets various variables for a Vault
    /// @dev Sender has to be allowed to call this method
    /// @param vault Address of the Vault
    /// @param param Name of the variable to set
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param data New value to set for the variable [wad]
    function setParam(
        address vault,
        uint256 tokenId,
        bytes32 param,
        uint256 data
    ) external override checkCaller {
        if (live == 0) revert Collybus__setParam_notLive();
        if (param == "rateId") rateIds[vault][tokenId] = data;
        else revert Collybus__setParam_unrecognizedParam();
        emit SetParam(vault, tokenId, param, data);
    }

    /// ======== Spot Prices ======== ///

    /// @notice Sets a token's spot price
    /// @dev Sender has to be allowed to call this method
    /// @param token Address of the token
    /// @param spot Spot price [wad]
    function updateSpot(address token, uint256 spot) external override checkCaller {
        if (live == 0) revert Collybus__updateSpot_notLive();
        spots[token] = spot;
        emit UpdateSpot(token, spot);
    }

    /// ======== Discount Rate ======== ///

    /// @notice Sets the discount rate by RateId
    /// @param rateId RateId of the discount rate feed
    /// @param rate Discount rate [wad]
    function updateDiscountRate(uint256 rateId, uint256 rate) external override checkCaller {
        if (live == 0) revert Collybus__updateDiscountRate_notLive();
        if (rateId >= type(uint128).max) revert Collybus__updateDiscountRate_invalidRateId();
        if (rate >= 2e10) revert Collybus__updateDiscountRate_invalidRate();
        rates[rateId] = rate;
        emit UpdateDiscountRate(rateId, rate);
    }

    /// @notice Returns the internal price for an asset
    /// @dev
    ///                 redemptionPrice
    /// v = ----------------------------------------
    ///                       (maturity - timestamp)
    ///     (1 + discountRate)
    ///
    /// @param vault Address of the asset corresponding Vault
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param maturity Maturity of the asset [unix timestamp in seconds]
    /// @param net Boolean (true - with liquidation safety margin, false - without)
    /// @return price Internal price [wad]
    function read(
        address vault,
        address underlier,
        uint256 tokenId,
        uint256 maturity,
        bool net
    ) external view override returns (uint256 price) {
        VaultConfig memory vaultConfig = vaults[vault];
        // fetch applicable fixed interest rate oracle system rateId
        uint256 rateId = rateIds[vault][tokenId];
        if (rateId == uint256(0)) rateId = vaultConfig.defaultRateId; // if not set, use default rateId
        // fetch discount rate
        uint256 discountRate = rates[rateId];
        // apply discount rate if discountRate > 0
        if (discountRate != 0 && maturity > block.timestamp) {
            uint256 rate = add(WAD, discountRate).powu(sub(maturity, block.timestamp));
            price = wdiv(redemptionPrice, rate); // den. in Underlier
        } else {
            price = redemptionPrice; // den. in Underlier
        }
        price = wmul(price, spots[underlier]); // den. in USD
        if (net) price = wdiv(price, vaultConfig.liquidationRatio); // with liquidation safety margin
    }

    /// ======== Shutdown ======== ///

    /// @notice Locks the contract
    /// @dev Sender has to be allowed to call this method
    function lock() external override checkCaller {
        live = 0;
        emit Lock();
    }
}
