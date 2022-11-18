// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {IERC1155} from "openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Receiver} from "openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC1155PresetMinterPauser} from "openzeppelin/contracts/token/ERC1155/presets/ERC1155PresetMinterPauser.sol";
import {IERC165} from "openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165} from "openzeppelin/contracts/utils/introspection/ERC165.sol";

import {Codex} from "../../../core/Codex.sol";

import {Vault1155} from "../../../vaults/Vault.sol";

contract Receiver is ERC165, IERC1155Receiver {
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

    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165, ERC165) returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId || super.supportsInterface(interfaceId);
    }
}

contract Vault1155Test is Test {
    Vault1155 vault;

    address codex = address(0xc0d311);
    address collybus = address(0xc0111b115);
    ERC1155PresetMinterPauser token;

    Receiver receiver;

    uint256 constant MAX_DECIMALS = 38; // ~type(int256).max ~= 1e18*1e18

    function setUp() public {
        token = new ERC1155PresetMinterPauser("");
        vault = new Vault1155(codex, address(token), collybus, "");

        receiver = new Receiver();

        vm.mockCall(
            codex, 
            abi.encodeWithSelector(Codex.modifyBalance.selector),
            abi.encode(true)
        );
    }

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

    function test_vaultType() public {
        assertEq(vault.vaultType(), bytes32("ERC1155"));
    }

    function test_token() public {
        assertEq(address(vault.token()), address(token));
    }

    function test_tokenScale() public {
        assertEq(vault.tokenScale(), 10**18);
    }

    function test_implements_ERC165Support_For_ERC1155Receiver() public {
        assertTrue(vault.supportsInterface(type(IERC1155Receiver).interfaceId));
    }

    function test_implements_onERC1155Received() public {
        assertEq(
            vault.onERC1155Received(address(0), address(0), 0, 0, new bytes(0)),
            IERC1155Receiver.onERC1155Received.selector
        );
    }

    function test_implements_onERC1155BatchReceived() public {
        assertEq(
            vault.onERC1155BatchReceived(address(0), address(0), new uint256[](0), new uint256[](0), new bytes(0)),
            IERC1155Receiver.onERC1155BatchReceived.selector
        );
    }

    function test_enter_transfersTokens_to_vault(
        uint256 tokenId,
        address owner,
        uint128 amount
    ) public {
        vm.assume(owner != address(vault));

        token.setApprovalForAll(address(vault), true);
        token.mint(address(this), tokenId, amount, new bytes(0));

        vault.enter(tokenId, owner, amount);

        assertEq(token.balanceOf(address(this), tokenId), 0);
        assertEq(token.balanceOf(address(vault), tokenId), amount);
    }

    function test_enter_calls_codex_modifyBalance(
        uint256 tokenId,
        address owner,
        uint128 amount
    ) public {
        vm.assume(owner != address(vault));

        token.setApprovalForAll(address(vault), true);
        token.mint(address(this), tokenId, amount, new bytes(0));

        vm.mockCall(
            codex, 
            abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), tokenId, owner, amount),
            abi.encode(true)
        );

        vm.expectCall(
            codex,
            abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), tokenId, owner, amount)
        );

        vault.enter(tokenId, owner, amount);
    }

    function test_exit_transfers_tokens(uint256 tokenId, uint128 amount) public {
        token.setApprovalForAll(address(vault), true);
        token.mint(address(this), tokenId, amount, new bytes(0));

        vault.enter(tokenId, address(this), amount);
        vault.exit(tokenId, address(receiver), amount);

        assertEq(token.balanceOf(address(receiver), tokenId), amount);
        assertEq(token.balanceOf(address(vault), tokenId), 0);
    }

    function test_exit_calls_codex_modifyBalance(uint256 tokenId, uint128 amount) public {
        token.setApprovalForAll(address(vault), true);
        token.mint(address(this), tokenId, amount, new bytes(0));

        vault.enter(tokenId, address(this), amount);
        
        vm.mockCall(
            codex,
            abi.encodeWithSelector(
                Codex.modifyBalance.selector,
                address(vault),
                tokenId,
                address(this),
                -int256(uint256(amount))
            ),
            abi.encode(true)
        );
        
        vault.exit(tokenId, address(receiver), amount);

        emit log_bytes(
            abi.encodeWithSelector(
                Codex.modifyBalance.selector,
                address(vault),
                tokenId,
                address(this),
                -int256(uint256(amount))
            )
        );
    }
}
