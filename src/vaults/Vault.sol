// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC1155} from "openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC1155, ERC1155Supply} from "openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {ERC165} from "openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICodex} from "../interfaces/ICodex.sol";
import {ICollybus} from "../interfaces/ICollybus.sol";
import {IVault} from "../interfaces/IVault.sol";
import {Guarded} from "../core/utils/Guarded.sol";
import {WAD, toInt256, wmul, wdiv} from "../core/utils/Math.sol";

/// @title Vault20
/// @notice The `Vault20` adapter allows for entering plain ERC20 tokens into the system
/// Implements the IVault interface
/// Uses GemJoin.sol from DSS (MakerDAO) / BasicCollateralJoin.sol from GEB (Reflexer Labs) as a blueprint
/// Changes from GemJoin.sol / BasicCollateralJoin.sol:
/// - only WAD precision is used (no RAD and RAY)
/// - uses a method signature based authentication scheme
contract Vault20 is Guarded, IVault {
    using SafeERC20 for IERC20;

    /// ======== Custom Errors ======== ///

    error Vault20__setParam_notLive();
    error Vault20__setParam_unrecognizedParam();
    error Vault20__enter_notLive();

    /// ======== Storage ======== ///

    /// @notice Codex
    ICodex public immutable override codex;
    /// @notice Price Feed
    ICollybus public override collybus;

    /// @notice collateral token
    address public immutable override token;
    /// @notice Scale of collateral token
    uint256 public immutable override tokenScale;
    /// @notice Underlier of collateral token
    address public immutable override underlierToken;
    /// @notice Scale of underlier of collateral token
    uint256 public immutable override underlierScale;

    /// @notice The vault type
    bytes32 public immutable override vaultType;

    /// @notice Boolean indicating if this contract is live (0 - not live, 1 - live)
    uint256 public override live;

    /// ======== Events ======== ///

    event SetParam(bytes32 indexed param, address data);

    event Enter(address indexed user, uint256 amount);
    event Exit(address indexed user, uint256 amount);

    event Lock();

    constructor(
        address codex_,
        address token_,
        address collybus_
    ) Guarded() {
        uint256 scale = 10**IERC20Metadata(token_).decimals();

        live = 1;
        codex = ICodex(codex_);
        collybus = ICollybus(collybus_);
        token = token_;
        tokenScale = scale;
        underlierToken = token_;
        underlierScale = scale;
        vaultType = bytes32("ERC20");
    }

    /// ======== Configuration ======== ///

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [address]
    function setParam(bytes32 param, address data) external virtual override checkCaller {
        if (live == 0) revert Vault20__setParam_notLive();
        if (param == "collybus") collybus = ICollybus(data);
        else revert Vault20__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// ======== Entering and Exiting Collateral ======== ///

    /// @notice Enters `amount` collateral into the system and credits it to `user`
    /// @dev Caller has to set allowance for this contract
    /// @param *tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param user Address to whom the collateral should be credited to in Codex
    /// @param amount Amount of collateral to enter [tokenScale]
    function enter(
        uint256, /* tokenId */
        address user,
        uint256 amount
    ) external virtual override {
        if (live == 0) revert Vault20__enter_notLive();
        int256 wad = toInt256(wdiv(amount, tokenScale));
        codex.modifyBalance(address(this), 0, user, wad);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Enter(user, amount);
    }

    /// @notice Exits `amount` collateral into the system and credits it to `user`
    /// @param *tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param user Address to whom the collateral should be credited to
    /// @param amount Amount of collateral to exit [tokenScale]
    function exit(
        uint256, /* tokenId */
        address user,
        uint256 amount
    ) external virtual override {
        int256 wad = toInt256(wdiv(amount, tokenScale));
        codex.modifyBalance(address(this), 0, msg.sender, -int256(wad));
        IERC20(token).safeTransfer(user, amount);
        emit Exit(user, amount);
    }

    /// ======== Collateral Asset ======== ///

    /// @notice Returns the maturity of the collateral asset
    /// @param *tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @return maturity [seconds]
    function maturity(
        uint256 /* tokenId */
    ) external view virtual override returns (uint256) {
        return block.timestamp;
    }

    /// ======== Valuing Collateral ======== ///

    /// @notice Returns the fair price of a single collateral unit
    /// @dev Caller has to set allowance for this contract
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param net Boolean indicating whether the liquidation safety margin should be applied to the fair value
    /// @param *face Boolean indicating whether the current fair value or the fair value at maturity should be returned
    /// @return fair price [wad]
    function fairPrice(
        uint256 tokenId,
        bool net,
        bool /* face */
    ) external view virtual override returns (uint256) {
        return collybus.read(address(this), address(token), tokenId, block.timestamp, net);
    }

    /// ======== Shutdown ======== ///

    /// @notice Locks the contract
    /// @dev Sender has to be allowed to call this method
    function lock() external virtual override checkCaller {
        live = 0;
        emit Lock();
    }
}

/// @title Vault1155
/// @notice The `Vault1155` adapter allows for entering plain ERC1155 tokens into the system
/// Implements the IVault interface
/// Uses GemJoin.sol from DSS (MakerDAO) / BasicCollateralJoin.sol from GEB (Reflexer Labs) as a blueprint
/// Changes from GemJoin.sol / BasicCollateralJoin.sol:
/// - only WAD precision is used (no RAD and RAY)
/// - uses a method signature based authentication scheme
/// - supports ERC1155, ERC721 style assets by TokenId
contract Vault1155 is Guarded, IVault, ERC165, ERC1155Supply {
    /// ======== Custom Errors ======== ///

    error Vault1155__setParam_notLive();
    error Vault1155__setParam_unrecognizedParam();
    error Vault1155__enter_notLive();
    error Vault1155__enter_overflow();
    error Vault1155__exit_overflow();

    /// ======== Storage ======== ///

    /// @notice Codex
    ICodex public immutable override codex;
    /// @notice Price Feed
    ICollybus public override collybus;

    /// @notice collateral token
    address public immutable override token;
    /// @notice Scale of collateral token
    uint256 public immutable override tokenScale;
    /// @notice Underlier of collateral token
    address public immutable override underlierToken;
    /// @notice Scale of underlier of collateral token
    uint256 public immutable override underlierScale;

    /// @notice The vault type
    bytes32 public immutable override vaultType;

    /// @notice Boolean indicating if this contract is live (0 - not live, 1 - live)
    uint256 public override live;

    /// ======== Events ======== ///

    event SetParam(bytes32 indexed param, address data);

    event Enter(uint256 indexed tokenId, address indexed user, uint256 amount);
    event Exit(uint256 indexed tokenId, address indexed user, uint256 amount);

    event Lock();

    constructor(
        address codex_,
        address token_,
        address collybus_,
        string memory uri
    ) Guarded() ERC1155(uri) {
        live = 1;
        codex = ICodex(codex_);
        collybus = ICollybus(collybus_);
        token = token_;
        tokenScale = 10**18;
        underlierToken = token_;
        underlierScale = 10**18;
        vaultType = bytes32("ERC1155");
    }

    /// ======== Configuration ======== ///

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [address]
    function setParam(bytes32 param, address data) external virtual override checkCaller {
        if (live == 0) revert Vault1155__setParam_notLive();
        if (param == "collybus") collybus = ICollybus(data);
        else revert Vault1155__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// ======== Entering and Exiting Collateral ======== ///

    /// @notice Enters `amount` collateral into the system and credits it to `user`
    /// @dev Caller has to set allowance for this contract
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param user Address to whom the collateral should be credited to in Codex
    /// @param amount Amount of collateral to enter [tokenScale]
    function enter(
        uint256 tokenId,
        address user,
        uint256 amount
    ) external virtual override {
        if (live == 0) revert Vault1155__enter_notLive();
        int256 wad = toInt256(wdiv(amount, tokenScale));
        codex.modifyBalance(address(this), tokenId, user, int256(wad));
        IERC1155(token).safeTransferFrom(msg.sender, address(this), tokenId, amount, new bytes(0));
        emit Enter(tokenId, user, amount);
    }

    /// @notice Exits `amount` collateral into the system and credits it to `user`
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param user Address to whom the collateral should be credited to
    /// @param amount Amount of collateral to exit [tokenScale]
    function exit(
        uint256 tokenId,
        address user,
        uint256 amount
    ) external virtual override {
        int256 wad = toInt256(wdiv(amount, tokenScale));
        codex.modifyBalance(address(this), tokenId, msg.sender, -int256(wad));
        IERC1155(token).safeTransferFrom(address(this), user, tokenId, amount, new bytes(0));
        emit Exit(tokenId, user, amount);
    }

    /// ======== Collateral Asset ======== ///

    /// @notice Returns the maturity of the collateral asset
    /// @param *tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @return maturity [seconds]
    function maturity(
        uint256 /* tokenId */
    ) external view virtual override returns (uint256) {
        return block.timestamp;
    }

    /// ======== Valuing Colltateral ======== ///

    /// @notice Returns the fair price of a single collateral unit
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param net Boolean indicating whether the liquidation safety margin should be applied to the fair value
    /// @param *face Boolean indicating whether the current fair value or the fair value at maturity should be returned
    /// @return fair price [wad]
    function fairPrice(
        uint256 tokenId,
        bool net,
        bool /* face */
    ) external view virtual override returns (uint256) {
        return collybus.read(address(this), address(token), tokenId, block.timestamp, net);
    }

    /// ======== ERC1155 ======== ///

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    /// ======== ERC165 ======== ///

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC1155, ERC165) returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || super.supportsInterface(interfaceId);
    }

    /// ======== Shutdown ======== ///

    /// @notice Locks the contract
    /// @dev Sender has to be allowed to call this method
    function lock() external virtual override checkCaller {
        live = 0;
        emit Lock();
    }
}
