// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {IERC1155} from "openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC1155, ERC1155Supply} from "openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {IERC721} from "openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ERC721Holder} from "openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {IERC721Receiver} from "openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC165} from "openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICodex} from "../interfaces/ICodex.sol";
import {ICollybus} from "../interfaces/ICollybus.sol";
import {IVault} from "../interfaces/IVault.sol";
import {Guarded} from "../core/utils/Guarded.sol";
import {WAD, toInt256, add, sub, wmul, wdiv, mul, div} from "../core/utils/Math.sol";

interface ISmartYield {
    struct SeniorBond {
        uint256 principal;
        uint256 gain;
        uint256 issuedAt;
        uint256 maturesAt;
        bool liquidated;
    }

    function controller() external view returns (address);

    function pool() external view returns (address);

    function seniorBond() external view returns (address);

    function seniorBonds(uint256 bondId_) external view returns (SeniorBond memory);

    function seniorBondId() external view returns (uint256);

    function bondGain(uint256 principalAmount_, uint16 forDays_) external returns (uint256);

    function buyBond(
        uint256 principalAmount_,
        uint256 minGain_,
        uint256 deadline_,
        uint16 forDays_
    ) external returns (uint256);

    function redeemBond(uint256 bondId_) external;
}

interface ISmartYieldController {
    function EXP_SCALE() external view returns (uint256);

    function FEE_REDEEM_SENIOR_BOND() external view returns (uint256);

    function underlyingDecimals() external view returns (uint256);
}

interface ISmartYieldProvider {
    function uToken() external view returns (address);
}

/// @title VaultSY (BarnBridge Smart Yield Senior Bond Vault)
/// @notice Collateral adapter for BarnBridge Smart Yield senior bonds
/// @dev To be instantiated by Smart Yield market
contract VaultSY is Guarded, IVault, ERC165, ERC1155Supply, ERC721Holder {
    using SafeERC20 for IERC20;

    /// ======== Custom Errors ======== ///

    error VaultSY__setParam_notLive();
    error VaultSY__setParam_unrecognizedParam();
    error VaultSY__enter_notLive();
    error VaultSY__enter_overflow();
    error VaultSY__exit_overflow();
    error VaultSY__wrap_maturedBond();
    error VaultSY__unwrap_bondNotMatured();
    error VaultSY__unwrap_notOwnerOfBond();
    error VaultSY__updateBond_redeemedBond();

    /// ======== Storage ======== ///

    /// @notice Codex
    ICodex public immutable override codex;
    /// @notice Price Feed
    ICollybus public override collybus;

    // Bond Cache
    struct Bond {
        uint256 principal; // Cached value of (principal + gain) of the bond [underlierScale]
        uint256 conversion; // Cached value of principal / totalSupply(bondId) [wad]
        uint128 maturity; // Cached maturity of bond [seconds]
        uint64 owned; // True if the bond is owned by this contract [0, 1]
        uint64 redeemed; // True after when updateBond is initially called after maturity [0, 1]
    }

    /// @notice Keeps track of deposited bonds because `ownerOf` reverts after bond is burned during redemption
    /// BondId => Bond
    mapping(uint256 => Bond) public bonds;

    /// @notice Smart Yield Market (e.g. SY Compound USDC)
    ISmartYield public immutable market;
    /// @notice Smart Yield Senior Bond ERC721 token
    IERC721 public immutable seniorBond;

    /// @notice Maximum amount of principal that can remain after a user redeems a partial amount
    /// of tokens [underlierScale]
    uint256 public principalFloor;

    /// @notice Collateral token
    address public immutable override token;
    /// @notice Scale of collateral token
    uint256 public immutable override tokenScale; // == WAD for this implementation
    /// @notice Underlier of collateral token (corresponds to a SY market)
    address public immutable override underlierToken;
    /// @notice Scale of underlier of collateral token
    uint256 public immutable override underlierScale;

    /// @notice The vault type
    bytes32 public immutable override vaultType;

    /// @notice Boolean indicating if this contract is live (0 - not live, 1 - live)
    uint256 public override live;

    /// ======== Events ======== ///

    event SetParam(bytes32 indexed param, address data);
    event SetParam(bytes32 indexed param, uint256 data);

    event Enter(uint256 indexed tokenId, address indexed user, uint256 amount);
    event Exit(uint256 indexed tokenId, address indexed user, uint256 amount);

    event Wrap(uint256 indexed bondId, address indexed to);
    event Unwrap(uint256 indexed tokenId, address indexed to);
    event Unwrap(uint256 indexed tokenId, address indexed to, uint256 amount);

    event BondUpdated(uint256 indexed bondId);

    event Lock();

    constructor(
        address codex_,
        address collybus_,
        address market_,
        string memory uri
    ) Guarded() ERC1155(uri) {
        live = 1;
        codex = ICodex(codex_);
        collybus = ICollybus(collybus_);

        market = ISmartYield(market_);
        seniorBond = IERC721(ISmartYield(market_).seniorBond());

        token = address(this);
        // allows for using wmul and wdiv operations
        tokenScale = WAD;
        underlierToken = ISmartYieldProvider(ISmartYield(market_).pool()).uToken();
        underlierScale = 10**ISmartYieldController(ISmartYield(market_).controller()).underlyingDecimals();
        vaultType = bytes32("ERC1155_W721:SY");
    }

    /// ======== Configuration ======== ///

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [address]
    function setParam(bytes32 param, address data) external virtual override checkCaller {
        if (live == 0) revert VaultSY__setParam_notLive();
        if (param == "collybus") collybus = ICollybus(data);
        else revert VaultSY__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// @notice Sets various variables for this contract
    /// @dev Sender has to be allowed to call this method
    /// @param param Name of the variable to set
    /// @param data New value to set for the variable [wad]
    function setParam(bytes32 param, uint256 data) external virtual checkCaller {
        if (param == "principalFloor") principalFloor = data;
        else revert VaultSY__setParam_unrecognizedParam();
        emit SetParam(param, data);
    }

    /// ======== Bond Terms ======== ///

    /// @notice Returns the bond terms
    /// @param bondId Id of the bond
    /// @return principal Principal value of the bond [underlierScale]
    /// @return maturity_ Maturity of the bond [seconds]
    /// @return liquidated Boolean if the underlier has been redeemed for the matured bond [bool]
    function terms(uint256 bondId)
        public
        view
        returns (
            uint256 principal,
            uint256 maturity_,
            bool liquidated
        )
    {
        ISmartYield.SeniorBond memory bond = market.seniorBonds(bondId);
        return (
            add(
                bond.principal,
                // Using WAD here since its the same precision as in the SY market (EXP_SCALE)
                sub(bond.gain, wmul(bond.gain, ISmartYieldController(market.controller()).FEE_REDEEM_SENIOR_BOND()))
            ),
            bond.maturesAt,
            bond.liquidated
        );
    }

    /// ======== Wrapping and Unwrapping ======== ///

    /// @notice Returns the amount of underliers of the matured bond that can be unwrapped for the wrapped tokens
    /// @param bondId Id of the bond
    /// @param amount Amount of wrapped tokens [tokenScale]
    /// @return Amount of underlier [underlierScale]
    function unwraps(uint256 bondId, uint256 amount) external view returns (uint256) {
        uint256 principal;
        // principal is fixed after bond has been redeemed for underlier (fee already deducated)
        if (bonds[bondId].redeemed == 1) {
            principal = bonds[bondId].principal;
        } else {
            (principal, , ) = terms(bondId);
        }
        uint256 conversion = wdiv(principal, totalSupply(bondId));
        return wmul(amount, conversion);
    }

    /// @notice Wraps the claim on a senior bond principal at maturity as ERC1155 tokens
    /// @param bondId Id of the bond
    /// @param to Recipient of the wrapped tokens
    /// @return Principal amount of wrapped bond [underlierScale]
    function wrap(uint256 bondId, address to) external returns (uint256) {
        (uint256 principal, uint256 _maturity, ) = terms(bondId);
        if (block.timestamp >= _maturity) revert VaultSY__wrap_maturedBond();
        // Cache bond terms
        bonds[bondId] = Bond(principal, WAD, uint128(_maturity), 1, 0);

        IERC721(seniorBond).transferFrom(msg.sender, address(this), bondId);
        _mint(to, bondId, wdiv(principal, underlierScale), new bytes(0));

        emit Wrap(bondId, to);

        return principal;
    }

    /// @notice Unwraps the fractionalized claim and returns the original senior bond ERC721 token
    /// @dev Caller has to own the total supply of the wrapped tokens for that bond
    /// @param bondId Id of the bond
    /// @param to Recipient of unwrapped bond
    function unwrap(uint256 bondId, address to) external {
        _burn(msg.sender, bondId, totalSupply(bondId));
        IERC721(seniorBond).transferFrom(address(this), to, bondId);
        bonds[bondId].owned = 0;

        emit Unwrap(bondId, to);
    }

    /// @notice Redeems a proportional amount of the fractionalized claim on a matured senior bonds principal
    /// @dev If the remaining amount of principal is less than `principalFloor` it is gifted to the caller
    /// @param bondId Id of the bond
    /// @param to Recipient of unwrapped bond
    /// @param amount Amount of wrapped tokens to unwrap [tokenScale]
    function unwrap(
        uint256 bondId,
        address to,
        uint256 amount
    ) external {
        if (bonds[bondId].redeemed == 0) updateBond(bondId);
        // use updated values
        Bond memory bond = bonds[bondId];
        if (bond.owned == 0) revert VaultSY__unwrap_notOwnerOfBond();
        if (bond.maturity > block.timestamp) revert VaultSY__unwrap_bondNotMatured();

        _burn(msg.sender, bondId, amount);

        // if leftover is less than `principalFloor` then caller gets the entire remaining principal
        uint256 share = wmul(wmul(amount, bond.conversion), underlierScale);
        if (sub(bond.principal, share) < principalFloor) share = bond.principal;
        bonds[bondId].principal = sub(bond.principal, share);

        IERC20(underlierToken).safeTransfer(to, share);

        emit Unwrap(bondId, to, amount);
    }

    /// ======== Entering and Exiting Collateral ======== ///

    /// @notice Enters `amount` collateral into the system and credits it to `user`
    /// @dev Caller has to set allowance for this contract
    /// @param tokenId ERC1155 TokenId
    /// @param user Address to whom the collateral should be credited to in Codex
    /// @param amount Amount of collateral to enter [tokenScale]
    function enter(
        uint256 tokenId,
        address user,
        uint256 amount
    ) external virtual override {
        if (live == 0) revert VaultSY__enter_notLive();
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

    /// @notice Returns the maturity of a bond
    /// @param bondId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @return maturity [seconds]
    function maturity(uint256 bondId) external view override returns (uint256) {
        return uint256(bonds[bondId].maturity);
    }

    /// ======== Valuing Collateral ======== ///

    /// @notice Updates a senior bond principal and conversion rate if SY fee schedule changes and
    /// redeems the bond for the underlier after maturity
    /// @param bondId Id of the bond
    function updateBond(uint256 bondId) public {
        // principal is fixed after bond has been redeemed for underlier (fee already deducated)
        if (bonds[bondId].redeemed == 1) revert VaultSY__updateBond_redeemedBond();

        // recalculate principal of bond after fee change
        (uint256 principal, uint256 _maturity, bool liquidated) = terms(bondId);
        if (block.timestamp >= _maturity) {
            // redeem if it hasn't been already
            if (!liquidated) market.redeemBond(bondId);
            // mark as redeemed if bond has been redeemed (liquidated)
            bonds[bondId].redeemed = 1;
        }
        bonds[bondId].principal = principal;
        bonds[bondId].conversion = wdiv(wdiv(principal, underlierScale), totalSupply(bondId));

        emit BondUpdated(bondId);
    }

    /// @notice Returns the fair price of a single collateral unit
    /// @param tokenId ERC1155 or ERC721 style TokenId (leave at 0 for ERC20)
    /// @param net Boolean indicating whether the liquidation safety margin should be applied to the fair value
    /// @param face Boolean indicating whether the current fair value or the fair value at maturity should be returned
    /// @return fair price [wad]
    function fairPrice(
        uint256 tokenId,
        bool net,
        bool face
    ) external view override returns (uint256) {
        return
            wmul(
                ICollybus(collybus).read(
                    address(this),
                    underlierToken,
                    tokenId,
                    (face) ? block.timestamp : uint256(bonds[tokenId].maturity),
                    net
                ),
                bonds[tokenId].conversion
            );
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

    /// ======== EIP165 ======== ///

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, ERC165) returns (bool) {
        return (interfaceId == type(IERC721Receiver).interfaceId ||
            interfaceId == type(IERC1155Receiver).interfaceId ||
            super.supportsInterface(interfaceId));
    }

    /// ======== Shutdown ======== ///

    /// @notice Locks the contract
    /// @dev Sender has to be allowed to call this method
    function lock() external virtual override checkCaller {
        live = 0;
        emit Lock();
    }
}
