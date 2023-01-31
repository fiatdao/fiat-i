// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1155Holder} from "openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {Codex} from "../../../core/Codex.sol";
import {Collybus, ICollybus} from "../../../core/Collybus.sol";
import {WAD, wdiv} from "../../../core/utils/Math.sol";

import {Caller} from "../../../test/utils/Caller.sol";

import {VaultFY} from "../../../vaults/VaultFY.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";

interface IFYToken {
    function maturity() external view returns (uint256);
}

interface IFYPool {
    function sellBasePreview(uint128 baseIn) external view returns (uint128);

    function sellBase(address to, uint128 min) external returns (uint128);

    function sellFYTokenPreview(uint128 fyTokenIn) external view returns (uint128);

    function sellFYToken(address to, uint128 min) external returns (uint128);
}

contract VaultFY_ModifyPositionCollateralizationTest is Test, ERC1155Holder {
    address internal fyUSDC04 = address(0x30FaDeEaAB2d7a23Cb1C35c05e2f8145001fA533);
    address internal fyUSDC04LP = address(0x407353d527053F3a6140AAA7819B93Af03114227);
    address internal fyDAI04 = address(0x0119451f94E98716c3fa17ff31d19C98d134DD6d);
    IERC20 internal underlierUSDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    IERC20 internal underlierDAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F); // DAI

    Codex internal codex;
    address internal collybus = address(0xc0111b115);
    VaultFY internal impl;
    VaultFY internal vaultFY_USDC04;
    VaultFactory vaultFactory;
    Caller kakaroto;

    uint256 internal tokenId = 0;
    address internal me = address(this);

    uint256 ONE_USDC = 1e6;

    uint256 constant MAX_DECIMALS = 38; // ~type(int256).max ~= 1e18*1e18
    uint256 constant MAX_AMOUNT = 10**(MAX_DECIMALS);

    function _mintUSDC(address to, uint256 amount) internal {
        // USDC minters
        vm.store(address(underlierUSDC), keccak256(abi.encode(address(this), uint256(12))), bytes32(uint256(1)));
        // USDC minterAllowed
        vm.store(
            address(underlierUSDC),
            keccak256(abi.encode(address(this), uint256(13))),
            bytes32(uint256(type(uint256).max))
        );
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(underlierUSDC).call(abi.encodeWithSignature(sig, to, amount));
        assert(ok);
    }

    function _mintDAI(address to, uint256 amount) internal {
        vm.store(address(underlierDAI), keccak256(abi.encode(address(address(this)), uint256(0))), bytes32(uint256(1)));
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(underlierDAI).call(abi.encodeWithSignature(sig, to, amount));
        assert(ok);
    }

    function _balance(address vault, address user) internal view returns (uint256) {
        return codex.balances(vault, 0, user);
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 13700000);

        vaultFactory = new VaultFactory();
        codex = new Codex();
        kakaroto = new Caller();

        impl = new VaultFY(address(codex), address(underlierUSDC));

        codex.setParam("globalDebtCeiling", uint256(1000 ether));

        _mintUSDC(me, 10000 * ONE_USDC);
        _mintDAI(me, 10000 * WAD);

        uint128 minFYToken = IFYPool(fyUSDC04LP).sellBasePreview(uint128(1000 * ONE_USDC));
        underlierUSDC.transfer(fyUSDC04LP, 1000 * ONE_USDC);
        IFYPool(fyUSDC04LP).sellBase(address(this), minFYToken);

        address instance = vaultFactory.createVault(address(impl), abi.encode(address(fyUSDC04), collybus));
        vaultFY_USDC04 = VaultFY(instance);
        codex.setParam(instance, "debtCeiling", uint256(1000 ether));
        codex.allowCaller(codex.modifyBalance.selector, instance);
        codex.init(instance);

        IERC20(fyUSDC04).approve(instance, type(uint256).max);
    }

    function testFail_initialize_with_wrong_ptoken() public {
        vaultFactory.createVault(address(impl), abi.encode(fyDAI04, collybus));
    }

    function test_initialize_with_right_ptoken() public {
        vaultFactory.createVault(address(impl), abi.encode(fyUSDC04, collybus));
    }

    function test_initialize_parameters() public {
        address instance = vaultFactory.createVault(address(impl), abi.encode(fyUSDC04, collybus));
        assertEq(address(VaultFY(instance).token()), fyUSDC04);
        assertEq(VaultFY(instance).tokenScale(), 10**IERC20Metadata(fyUSDC04).decimals());
        assertEq(VaultFY(instance).maturity(0), IFYToken(fyUSDC04).maturity());
        assertEq(VaultFY(instance).underlierToken(), address(underlierUSDC));
        assertEq(VaultFY(instance).underlierScale(), 10**IERC20Metadata(address(underlierUSDC)).decimals());
        assertEq(address(VaultFY(instance).collybus()), collybus);
    }

    function test_enter(uint32 rnd) public {
        vm.assume(rnd != 0);
        uint256 amount = rnd % IERC20(fyUSDC04).balanceOf(address(this));

        uint256 balanceBefore = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC04));
        uint256 collateralBefore = _balance(address(vaultFY_USDC04), address(me));

        vaultFY_USDC04.enter(0, me, amount);

        assertEq(IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC04)), balanceBefore + amount);

        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(fyUSDC04).decimals());
        assertEq(_balance(address(vaultFY_USDC04), address(me)), collateralBefore + wadAmount);
    }

    function test_exit(uint32 rndA, uint32 rndB) public {
        vm.assume(rndA != 0);
        vm.assume(rndB != 0);
        uint256 amountEnter = rndA % IERC20(fyUSDC04).balanceOf(address(this));
        uint256 amountExit = rndB % amountEnter;

        vaultFY_USDC04.enter(0, me, amountEnter);

        uint256 balanceBefore = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC04));
        uint256 collateralBefore = _balance(address(vaultFY_USDC04), address(me));

        vaultFY_USDC04.exit(0, me, amountExit);
        assertEq(IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC04)), balanceBefore - amountExit);

        uint256 wadAmount = wdiv(amountExit, 10**IERC20Metadata(fyUSDC04).decimals());
        assertEq(_balance(address(vaultFY_USDC04), address(me)), collateralBefore - wadAmount);
    }

    function test_fairPrice_calls_into_collybus_face() public {
        uint256 fairPriceExpected = 100;
        bytes memory query = abi.encodeWithSelector(
            Collybus.read.selector,
            address(vaultFY_USDC04),
            address(underlierUSDC),
            0,
            block.timestamp,
            true
        );
        
        vm.mockCall(collybus, query, abi.encode(uint256(fairPriceExpected)));
        uint256 fairPriceReturned = vaultFY_USDC04.fairPrice(0, true, true);
        assertEq(fairPriceReturned, fairPriceExpected);
    }

    function test_fairPrice_calls_into_collybus_no_face() public {
        uint256 fairPriceExpected = 100;
        bytes memory query = abi.encodeWithSelector(
            Collybus.read.selector,
            address(vaultFY_USDC04),
            address(underlierUSDC),
            0,
            vaultFY_USDC04.maturity(0),
            true
        );

        vm.mockCall(collybus, query, abi.encode(uint256(fairPriceExpected)));
        uint256 fairPriceReturned = vaultFY_USDC04.fairPrice(0, true, false);
        assertEq(fairPriceReturned, fairPriceExpected);
    }

    function test_allowCaller_can_be_called_by_root() public {
        vaultFY_USDC04.allowCaller(vaultFY_USDC04.setParam.selector, address(kakaroto));
        assertTrue(vaultFY_USDC04.canCall(vaultFY_USDC04.setParam.selector, address(kakaroto)));
    }

    function test_lock_can_be_called_by_root() public {
        vaultFY_USDC04.lock();
        assertEq(vaultFY_USDC04.live(), 0);
    }

    function test_setParam_can_be_called_by_root() public {
        vaultFY_USDC04.setParam(bytes32("collybus"), me);
        assertEq(address(vaultFY_USDC04.collybus()), me);
    }

    function test_setParam_can_be_called_by_authorized() public {
        vaultFY_USDC04.allowCaller(vaultFY_USDC04.setParam.selector, address(kakaroto));

        (bool ok, ) = kakaroto.externalCall(
            address(vaultFY_USDC04),
            abi.encodeWithSelector(vaultFY_USDC04.setParam.selector, bytes32("collybus"), me)
        );
        assertTrue(ok);
        assertEq(address(vaultFY_USDC04.collybus()), me);
    }
}
