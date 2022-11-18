// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {Codex} from "../../../core/Codex.sol";

import {TestERC20} from "../../../test/utils/TestERC20.sol";

import {Vault20} from "../../../vaults/Vault.sol";

contract Vault20Test is Test {
    Vault20 vault;

    address internal codex = address(0xc0d311);
    address internal collybus = address(0xc0111b115);
    TestERC20 token;

    uint256 constant MAX_DECIMALS = 38; // ~type(int256).max ~= 1e18*1e18

    function setUp() public {
        token = new TestERC20("Test Token", "TKN", 18);
        vault = new Vault20(address(codex), address(token), address(collybus));

        vm.mockCall(codex, abi.encodeWithSelector(Codex.modifyBalance.selector), abi.encode(true));
    }

    function test_vaultType() public {
        assertEq(vault.vaultType(), bytes32("ERC20"));
    }

    function test_enter_transfers_to_vault(address owner, uint128 amount_) public {
        vm.assume(owner != address(vault));
        uint256 amount = uint256(amount_);

        token.approve(address(vault), amount);
        token.mint(address(this), amount);

        vault.enter(0, owner, amount);

        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(vault)), amount);
    }

    function test_enter_calls_codex_modifyBalance(address owner, uint128 amount_) public {
        vm.assume(owner != address(vault));
        uint256 amount = uint256(amount_);

        token.approve(address(vault), amount);
        token.mint(address(this), amount);

        vm.expectCall(codex, abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, owner, amount));
        vault.enter(0, owner, amount);

        emit log_bytes(abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, owner, amount));
    }

    function test_exit_transfers_tokens(address owner, uint128 amount_) public {
        vm.assume(owner != address(vault));
        uint256 amount = uint256(amount_);

        token.approve(address(vault), amount);
        token.mint(address(this), amount);

        vault.enter(0, address(this), amount);
        vault.exit(0, owner, amount);

        assertEq(token.balanceOf(owner), amount);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_exit_calls_codex_modifyBalance(address owner, uint128 amount_) public {
        vm.assume(owner != address(vault));
        uint256 amount = uint256(amount_);

        token.approve(address(vault), amount);
        token.mint(address(this), amount);

        vault.enter(0, address(this), amount);

        vm.expectCall(codex, abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, address(this), -int256(amount)));
        vault.exit(0, owner, amount);

        emit log_bytes(
            abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, address(this), -int256(amount))
        );
    }

    function test_enter_scales_amount_to_wad(uint8 decimals) public {
        if (decimals > MAX_DECIMALS) return;

        address owner = address(this);
        uint256 vanillaAmount = 12345678901234567890;
        uint256 amount = vanillaAmount * 10**decimals;

        token = new TestERC20("Test Token", "TKN", uint8(decimals));
        vault = new Vault20(address(codex), address(token), address(collybus));

        token.approve(address(vault), amount);
        token.mint(address(this), amount);

        uint256 scaledAmount = vanillaAmount * 10**18;
        vm.expectCall(codex, abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, address(this), scaledAmount));
        vault.enter(0, owner, amount);
    }

    function test_exit_scales_wad_to_native(uint8 decimals) public {
        if (decimals > MAX_DECIMALS) return;

        address owner = address(this);
        uint256 vanillaAmount = 12345678901234567890;
        uint256 amount = vanillaAmount * 10**decimals;

        token = new TestERC20("Test Token", "TKN", uint8(decimals));
        vault = new Vault20(address(codex), address(token), address(collybus));

        token.approve(address(vault), amount);
        token.mint(address(vault), amount);

        int256 scaledAmount = int256(vanillaAmount) * 10**18 * -1;
        vm.expectCall(codex, abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, address(this), scaledAmount));
        vault.exit(0, owner, amount);
    }
}
