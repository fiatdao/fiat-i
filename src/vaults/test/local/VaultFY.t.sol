// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {MockProvider} from "../../../test/utils/MockProvider.sol";
import {TestERC20} from "../../../test/utils/TestERC20.sol";

import {Codex} from "../../../Codex.sol";
import {VaultFactory} from "../../VaultFactory.sol";
import {VaultFY} from "../../VaultFY.sol";
import {IVault} from "../../../interfaces/IVault.sol";

contract TestFYToken {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name = "Test Token";
    string public symbol = "TKN";
    uint8 public decimals = 18;

    uint256 public maturity;
    address public underlying;

    constructor() {}

    function setMaturity(uint256 maturity_) external {
        maturity = maturity_;
    }

    function setDecimals(uint8 _decimals) external {
        decimals = _decimals;
    }

    function setUnderlying(address underlying_) external {
        underlying = underlying_;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) public returns (bool) {
        balanceOf[msg.sender] -= value;
        unchecked {
            balanceOf[to] += value;
        }
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= value;
        }
        balanceOf[from] -= value;
        unchecked {
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
        return true;
    }

    function mint(address to, uint256 value) public {
        totalSupply += value;
        unchecked {
            balanceOf[to] += value;
        }
        emit Transfer(address(0), to, value);
    }

    function burn(address from, uint256 value) public {
        balanceOf[from] -= value;
        unchecked {
            totalSupply -= value;
        }
        emit Transfer(from, address(0), value);
    }
}

contract VaultFYTest is Test {
    VaultFactory vaultFactory;
    VaultFY impl;
    IVault vault;

    TestFYToken token;
    TestERC20 underlier;

    MockProvider codex;
    MockProvider collybus;

    uint256 maturity;

    uint256 constant MAX_DECIMALS = 38; // ~type(int256).max ~= 1e18*1e18

    function setUp() public {
        vaultFactory = new VaultFactory();
        codex = new MockProvider();
        collybus = new MockProvider();
        maturity = block.timestamp + 12 weeks;
        underlier = new TestERC20("Test Token", "TKN", 18);

        token = new TestFYToken();
        token.setMaturity(maturity);
        token.setUnderlying(address(underlier));

        impl = new VaultFY(address(codex), address(underlier));
        address vaultAddr = vaultFactory.createVault(address(impl), abi.encode(address(token), address(collybus)));
        vault = IVault(vaultAddr);
    }

    function test_codex() public {
        assertEq(address(vault.codex()), address(codex));
    }

    function test_collybus() public {
        assertEq(address(vault.collybus()), address(collybus));
    }

    function test_token() public {
        assertEq(vault.token(), address(token));
    }

    function test_tokenScale() public {
        assertEq(vault.tokenScale(), 10 ** token.decimals());
    }

    function test_live() public {
        assertEq(uint256(vault.live()), uint256(1));
    }

    function test_maturity() public {
        assertEq(vault.maturity(0), maturity);
    }

    function test_underlierToken() public {
        assertEq(vault.underlierToken(), address(underlier));
    }

    function test_underlierScale() public {
        assertEq(vault.underlierScale(), 10 ** underlier.decimals());
    }

    function test_vaultType() public {
        assertEq(vault.vaultType(), bytes32("ERC20:FY"));
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

        underlier = new TestERC20("Test Token", "TKN", decimals);
        token.setDecimals(decimals);
        token.setUnderlying(address(underlier));
        vault = IVault(
            vaultFactory.createVault(
                address(new VaultFY(address(codex), address(underlier))),
                abi.encode(address(token), address(collybus))
            )
        );

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

        underlier = new TestERC20("Test Token", "TKN", decimals);
        token.setDecimals(decimals);
        token.setUnderlying(address(underlier));
        vault = IVault(
            vaultFactory.createVault(
                address(new VaultFY(address(codex), address(underlier))),
                abi.encode(address(token), address(collybus))
            )
        );

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
