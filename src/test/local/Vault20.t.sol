// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";
import "forge-std/Vm.sol";

import {TestERC20} from "../utils/TestERC20.sol";

import {Codex} from "../../Codex.sol";
import {Vault20} from "../../Vault.sol";

contract Vault20Test is Test {
    Vault20 vault;

    address internal codex = address(0xc0d311);
    address internal collybus = address(0xc0111b115);

    TestERC20 token;

    uint256 constant MAX_DECIMALS = 38; // ~type(int256).max ~= 1e18*1e18
    uint256 constant MAX_AMOUNT = 10**(MAX_DECIMALS);

    function setUp() public {
        token = new TestERC20("Test Token", "TKN", 18);
        vault = new Vault20(address(codex), address(token), address(collybus));
        vm.mockCall(codex, abi.encodeWithSelector(Codex.modifyBalance.selector), abi.encode(true));
    }

    function test_vaultType() public {
        assertEq(vault.vaultType(), bytes32("ERC20"));
    }

    function test_enter_transfers_to_vault(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        token.approve(address(vault), amount);
        token.mint(address(this), amount);

        vault.enter(0, owner, amount);

        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(vault)), amount);
    }

    function test_enter_calls_codex_modifyBalance(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        token.approve(address(vault), amount);
        token.mint(address(this), amount);

        vm.expectCall(codex, abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, owner, amount));
        vault.enter(0, owner, amount);
        
        emit log_bytes(abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, owner, amount));
    }

    function test_exit_transfers_tokens(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        token.approve(address(vault), amount);
        token.mint(address(this), amount);

        vault.enter(0, address(this), amount);
        vault.exit(0, owner, amount);

        assertEq(token.balanceOf(owner), amount);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_exit_calls_codex_modifyBalance(address owner, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        token.approve(address(vault), amount);
        token.mint(address(this), amount);

        vault.enter(0, address(this), amount);

        vm.expectCall(codex, abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, address(this), -int256(amount)));

        vault.exit(0, owner, amount);
        
        emit log_bytes(
            abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, address(this), -int256(amount))
        );
    }

    function testFail_enter_amount_cannot_be_casted(uint256 amount) public {
        if (amount <= uint256(type(int256).max)) assert(false);

        token.approve(address(vault), amount);
        token.mint(address(this), amount);

        vault.enter(0, address(this), amount);
    }

    function testFail_exit_amount_cannot_be_casted(uint256 amount) public {
        if (amount <= MAX_AMOUNT) assert(false);

        token.approve(address(vault), MAX_AMOUNT);
        token.mint(address(this), MAX_AMOUNT);

        vault.enter(0, address(this), amount);
        vault.exit(0, address(this), amount);
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
        vm.expectCall(codex, abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, owner, scaledAmount));

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
        vm.expectCall(codex, abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, owner, scaledAmount));

        vault.exit(0, owner, amount);
    }
}
