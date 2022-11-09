// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {Codex} from "../../../Codex.sol";

import {MockProvider} from "../utils/MockProvider.sol";
import {TestERC20} from "../utils/TestERC20.sol";

import {Vault20} from "../../Vault.sol";

contract Vault20Test is Test {
    Vault20 vault;

    MockProvider codex;
    MockProvider collybus;
    TestERC20 token;

    uint256 constant MAX_DECIMALS = 38; // ~type(int256).max ~= 1e18*1e18

    function setUp() public {
        codex = new MockProvider();
        collybus = new MockProvider();
        token = new TestERC20("Test Token", "TKN", 18);
        vault = new Vault20(address(codex), address(token), address(collybus));
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

        vault.enter(0, owner, amount);

        MockProvider.CallData memory cd = codex.getCallData(0);
        assertEq(cd.caller, address(vault));
        assertEq(cd.functionSelector, Codex.modifyBalance.selector);
        assertEq(
            keccak256(cd.data),
            keccak256(abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, owner, amount))
        );
        emit log_bytes(cd.data);
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
        vault.exit(0, owner, amount);

        MockProvider.CallData memory cd = codex.getCallData(1);
        assertEq(cd.caller, address(vault));
        assertEq(cd.functionSelector, Codex.modifyBalance.selector);
        assertEq(
            keccak256(cd.data),
            keccak256(
                abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, address(this), -int256(amount))
            )
        );
        emit log_bytes(cd.data);
        emit log_bytes(
            abi.encodeWithSelector(Codex.modifyBalance.selector, address(vault), 0, address(this), -int256(amount))
        );
    }

    function test_enter_scales_amount_to_wad(uint8 decimals) public {
        if (decimals > MAX_DECIMALS) return;

        address owner = address(this);
        uint256 vanillaAmount = 12345678901234567890;
        uint256 amount = vanillaAmount * 10 ** decimals;

        codex = new MockProvider();
        collybus = new MockProvider();
        token = new TestERC20("Test Token", "TKN", uint8(decimals));
        vault = new Vault20(address(codex), address(token), address(collybus));

        token.approve(address(vault), amount);
        token.mint(address(this), amount);

        vault.enter(0, owner, amount);

        MockProvider.CallData memory cd = codex.getCallData(0);
        (, , , uint256 sentAmount) = abi.decode(cd.arguments, (address, uint256, address, uint256));

        uint256 scaledAmount = vanillaAmount * 10 ** 18;
        assertEq(scaledAmount, sentAmount);
    }

    function test_exit_scales_wad_to_native(uint8 decimals) public {
        if (decimals > MAX_DECIMALS) return;

        address owner = address(this);
        uint256 vanillaAmount = 12345678901234567890;
        uint256 amount = vanillaAmount * 10 ** decimals;

        codex = new MockProvider();
        collybus = new MockProvider();
        token = new TestERC20("Test Token", "TKN", uint8(decimals));
        vault = new Vault20(address(codex), address(token), address(collybus));

        token.approve(address(vault), amount);
        token.mint(address(vault), amount);

        vault.exit(0, owner, amount);

        MockProvider.CallData memory cd = codex.getCallData(0);
        (, , , int256 sentAmount) = abi.decode(cd.arguments, (address, uint256, address, int256));

        // exit decreases the amount in Codex by that much
        int256 scaledAmount = int256(vanillaAmount) * 10 ** 18 * -1;
        assertEq(sentAmount, scaledAmount);
    }
}
