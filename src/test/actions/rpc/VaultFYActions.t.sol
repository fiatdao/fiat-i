// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Codex} from "../../../core/Codex.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {Publican} from "../../../core/Publican.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {toInt256, WAD, wdiv} from "../../../core/utils/Math.sol";

import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {VaultFY} from "../../../vaults/VaultFY.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";

import {Caller} from "../../../test/utils/Caller.sol";

import {VaultFYActions, IFYPool} from "../../../actions/vault/VaultFYActions.sol";

contract VaultFYActions_RPC_tests is Test {
    Codex internal codex;
    Publican internal publican;
    address internal collybus = address(0xc0111b115);
    Moneta internal moneta;
    FIAT internal fiat;
    PRBProxy internal userProxy;
    PRBProxyFactory internal prbProxyFactory;
    Caller internal kakaroto;
    VaultFYActions internal vaultActions;

    VaultFactory internal vaultFactory;
    VaultFY internal vaultFY_impl;
    VaultFY internal vaultFY_USDC06;

    IERC20 internal underlierUSDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address internal fyUSDC04 = address(0x30FaDeEaAB2d7a23Cb1C35c05e2f8145001fA533);
    address internal fyUSDC04LP = address(0x407353d527053F3a6140AAA7819B93Af03114227);

    address internal me = address(this);
    uint256 internal ONE_USDC = 1e6;

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

    function _collateral(address vault, address user) internal view returns (uint256) {
        (uint256 collateral, ) = codex.positions(vault, 0, user);
        return collateral;
    }

    function _normalDebt(address vault, address user) internal view returns (uint256) {
        (, uint256 normalDebt) = codex.positions(vault, 0, user);
        return normalDebt;
    }

    function _modifyCollateralAndDebt(
        address vault,
        address token,
        address collateralizer,
        address creditor,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    ) internal {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                vault,
                token,
                0,
                address(userProxy),
                collateralizer,
                creditor,
                deltaCollateral,
                deltaNormalDebt
            )
        );
    }

    function _buyCollateralAndModifyDebt(
        address vault,
        address collateralizer,
        address creditor,
        uint256 underlierAmount,
        int256 deltaNormalDebt,
        VaultFYActions.SwapParams memory swapParams
    ) internal {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.buyCollateralAndModifyDebt.selector,
                vault,
                address(userProxy),
                collateralizer,
                creditor,
                underlierAmount,
                deltaNormalDebt,
                swapParams
            )
        );
    }

    function _sellCollateralAndModifyDebt(
        address vault,
        address collateralizer,
        address creditor,
        uint256 pTokenAmount,
        int256 deltaNormalDebt,
        VaultFYActions.SwapParams memory swapParams
    ) internal {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.sellCollateralAndModifyDebt.selector,
                vault,
                address(userProxy),
                collateralizer,
                creditor,
                pTokenAmount,
                deltaNormalDebt,
                swapParams
            )
        );
    }

    function _redeemCollateralAndModifyDebt(
        address vault,
        address collateralizer,
        address creditor,
        uint256 pTokenAmount,
        int256 deltaNormalDebt
    ) internal {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.redeemCollateralAndModifyDebt.selector,
                vault,
                VaultFY(vault).token(),
                address(userProxy),
                collateralizer,
                creditor,
                pTokenAmount,
                deltaNormalDebt
            )
        );
    }

    function _getSwapParams(
        address assetIn,
        address assetOut,
        uint256 minOutput
    ) internal view returns (VaultFYActions.SwapParams memory swapParams) {
        swapParams.yieldSpacePool = fyUSDC04LP;
        swapParams.assetIn = assetIn;
        swapParams.assetOut = assetOut;
        swapParams.minAssetOut = minOutput;
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 13700000);

        kakaroto = new Caller();
        vaultFactory = new VaultFactory();
        codex = new Codex();
        publican = new Publican(address(codex));
        fiat = new FIAT();
        moneta = new Moneta(address(codex), address(fiat));
        fiat.allowCaller(fiat.mint.selector, address(moneta));
        vaultActions = new VaultFYActions(address(codex), address(moneta), address(fiat), address(publican));

        prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        vaultFY_impl = new VaultFY(address(codex), address(underlierUSDC));

        codex.setParam("globalDebtCeiling", uint256(1000 ether));
        codex.allowCaller(keccak256("ANY_SIG"), address(publican));

        codex.setParam("globalDebtCeiling", uint256(1000 ether));
        codex.allowCaller(keccak256("ANY_SIG"), address(publican));

        _mintUSDC(me, 2000000 * ONE_USDC);

        address instance = vaultFactory.createVault(address(vaultFY_impl), abi.encode(fyUSDC04, collybus));

        vaultFY_USDC06 = VaultFY(instance);
        codex.setParam(instance, "debtCeiling", uint256(1000 ether));
        codex.allowCaller(codex.modifyBalance.selector, instance);
        codex.init(instance);

        publican.init(instance);
        publican.setParam(instance, "interestPerSecond", WAD);

        // Token approvals
        // USDC
        underlierUSDC.approve(address(userProxy), type(uint256).max);
        kakaroto.externalCall(
            address(underlierUSDC),
            abi.encodeWithSelector(underlierUSDC.approve.selector, address(userProxy), type(uint256).max)
        );
        // Collateral
        IERC20(fyUSDC04).approve(address(userProxy), type(uint256).max);
        // FIAT
        fiat.approve(address(userProxy), type(uint256).max);
        kakaroto.externalCall(
            address(fiat),
            abi.encodeWithSelector(fiat.approve.selector, address(userProxy), type(uint256).max)
        );
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), type(uint256).max)
        );

        // Mock responses
        vm.mockCall(collybus, abi.encodeWithSelector(Collybus.read.selector), abi.encode(uint256(WAD)));
    }

    function test_increaseCollateral_from_underlier() public {
        uint128 amount = 100 * uint128(ONE_USDC);
        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));
        uint256 previewOut = vaultActions.underlierToFYToken(amount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            address(0),
            amount,
            0,
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        assertEq(underlierUSDC.balanceOf(me), meInitialBalance - amount);
        assertTrue(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)) >= previewOut + vaultInitialBalance);
        assertTrue(
            _collateral(address(vaultFY_USDC06), address(userProxy)) >=
                initialCollateral + wdiv(previewOut, 10**IERC20Metadata(fyUSDC04).decimals())
        );
    }

    function test_increaseCollateral_from_user_underlier() public {
        uint256 amount = 100 * ONE_USDC;
        underlierUSDC.transfer(address(kakaroto), amount);

        uint256 kakarotoInitialBalance = underlierUSDC.balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));
        uint256 previewOut = vaultActions.underlierToFYToken(amount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            address(kakaroto),
            address(0),
            amount,
            0,
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        assertEq(underlierUSDC.balanceOf(address(kakaroto)), kakarotoInitialBalance - amount);
        assertTrue(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)) >= vaultInitialBalance + previewOut);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(fyUSDC04).decimals());
        assertTrue(_collateral(address(vaultFY_USDC06), address(userProxy)) >= initialCollateral + wadAmount);
    }

    function test_increaseCollateral_from_proxy_zero_underlier() public {
        uint256 amount = 100 * ONE_USDC;
        underlierUSDC.transfer(address(userProxy), amount);
        uint256 userProxyInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));
        uint256 previewOut = vaultActions.underlierToFYToken(amount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            address(0),
            address(0),
            amount,
            0,
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        assertEq(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance - amount);
        assertTrue(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)) >= vaultInitialBalance + amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(fyUSDC04).decimals());
        assertTrue(_collateral(address(vaultFY_USDC06), address(userProxy)) >= initialCollateral + wadAmount);
    }

    function test_increaseCollateral_from_proxy_address_underlier() public {
        uint256 amount = 100 * ONE_USDC;
        underlierUSDC.transfer(address(userProxy), amount);
        uint256 userProxyInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));
        uint256 previewOut = vaultActions.underlierToFYToken(amount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            address(userProxy),
            address(0),
            amount,
            0,
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        assertEq(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance - amount);
        assertTrue(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)) >= vaultInitialBalance + amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(fyUSDC04).decimals());
        assertTrue(_collateral(address(vaultFY_USDC06), address(userProxy)) >= initialCollateral + wadAmount);
    }

    function test_decreaseCollateral_get_underlier() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            address(0),
            testAmount,
            0,
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));

        uint256 amount = 500 * ONE_USDC;
        uint256 expectedDelta = vaultActions.fyTokenToUnderlier(amount, fyUSDC04LP);

        VaultFYActions.SwapParams memory swapParams = _getSwapParams(fyUSDC04, address(underlierUSDC), expectedDelta);

        _sellCollateralAndModifyDebt(address(vaultFY_USDC06), me, address(0), amount, 0, swapParams);

        // emit log_named_uint("meInitialBalance", meInitialBalance);
        // emit log_named_uint("expectedDelta", expectedDelta);
        // emit log_named_uint("balance", underlierUSDC.balanceOf(me));

        assertTrue(underlierUSDC.balanceOf(me) >= meInitialBalance + expectedDelta);
        assertEq(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)), vaultInitialBalance - amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(fyUSDC04).decimals());
        assertEq(_collateral(address(vaultFY_USDC06), address(userProxy)), initialCollateral - wadAmount);
    }

    function test_decreaseCollateral_send_underlier_to_user() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            address(0),
            testAmount,
            0,
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        uint256 kakarotoInitialBalance = underlierUSDC.balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));

        uint256 amount = 500 * ONE_USDC;
        uint256 expectedDelta = vaultActions.fyTokenToUnderlier(amount, fyUSDC04LP);

        VaultFYActions.SwapParams memory swapParams = _getSwapParams(fyUSDC04, address(underlierUSDC), expectedDelta);

        _sellCollateralAndModifyDebt(address(vaultFY_USDC06), address(kakaroto), address(0), amount, 0, swapParams);

        assertTrue(underlierUSDC.balanceOf(address(kakaroto)) >= kakarotoInitialBalance + expectedDelta);
        assertEq(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)), vaultInitialBalance - amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(fyUSDC04).decimals());
        assertEq(_collateral(address(vaultFY_USDC06), address(userProxy)), initialCollateral - wadAmount);
    }

    function test_decreaseCollateral_redeem_underlier() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            address(0),
            testAmount,
            0,
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));

        uint256 amount = 500 * ONE_USDC;

        vm.roll(block.number + ((vaultFY_USDC06.maturity(0) - block.timestamp) / 12));
        vm.warp(vaultFY_USDC06.maturity(0));

        _redeemCollateralAndModifyDebt(address(vaultFY_USDC06), me, address(0), amount, 0);

        assertTrue(underlierUSDC.balanceOf(me) >= meInitialBalance + amount);
        assertEq(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)), vaultInitialBalance - amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(fyUSDC04).decimals());
        assertEq(_collateral(address(vaultFY_USDC06), address(userProxy)), initialCollateral - wadAmount);
    }

    function test_decreaseCollateral_redeem_underlier_to_user() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            address(0),
            testAmount,
            0,
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));

        uint256 amount = 500 * ONE_USDC;

        vm.roll(block.number + ((vaultFY_USDC06.maturity(0) - block.timestamp) / 12));
        vm.warp(vaultFY_USDC06.maturity(0));

        _redeemCollateralAndModifyDebt(address(vaultFY_USDC06), address(kakaroto), address(0), amount, 0);

        assertTrue(underlierUSDC.balanceOf(address(kakaroto)) >= meInitialBalance + amount);
        assertEq(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)), vaultInitialBalance - amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(fyUSDC04).decimals());
        assertEq(_collateral(address(vaultFY_USDC06), address(userProxy)), initialCollateral - wadAmount);
    }

    function test_increaseDebt() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            address(0),
            testAmount,
            0,
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        uint256 meInitialBalance = fiat.balanceOf(me);
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));

        _modifyCollateralAndDebt(address(vaultFY_USDC06), fyUSDC04, address(0), me, 0, toInt256(500 * WAD));

        assertEq(fiat.balanceOf(me), meInitialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_increaseDebt_send_to_user() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            address(0),
            testAmount,
            0,
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        uint256 kakarotoInitialBalance = fiat.balanceOf(address(kakaroto));
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));

        _modifyCollateralAndDebt(
            address(vaultFY_USDC06),
            fyUSDC04,
            address(0),
            address(kakaroto),
            0,
            toInt256(500 * WAD)
        );

        assertEq(fiat.balanceOf(address(kakaroto)), kakarotoInitialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_decreaseDebt() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            me,
            testAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        uint256 meInitialBalance = fiat.balanceOf(me);
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));

        _modifyCollateralAndDebt(address(vaultFY_USDC06), fyUSDC04, address(0), me, 0, -toInt256(200 * WAD));

        assertEq(fiat.balanceOf(me), meInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decreaseDebt_get_fiat_from_user() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            me,
            testAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        fiat.transfer(address(kakaroto), 500 * WAD);

        uint256 kakarotoInitialBalance = fiat.balanceOf(address(kakaroto));
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));

        _modifyCollateralAndDebt(
            address(vaultFY_USDC06),
            fyUSDC04,
            address(0),
            address(kakaroto),
            0,
            -toInt256(200 * WAD)
        );

        assertEq(fiat.balanceOf(address(kakaroto)), kakarotoInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decreaseDebt_get_fiat_from_proxy_zero() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            me,
            testAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        fiat.transfer(address(userProxy), 500 * WAD);

        uint256 userProxyInitialBalance = fiat.balanceOf(address(userProxy));
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));

        _modifyCollateralAndDebt(address(vaultFY_USDC06), fyUSDC04, address(0), address(0), 0, -toInt256(200 * WAD));

        assertEq(fiat.balanceOf(address(userProxy)), userProxyInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decreaseDebt_get_fiat_from_proxy_address() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            me,
            testAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        fiat.transfer(address(userProxy), 500 * WAD);

        uint256 userProxyInitialBalance = fiat.balanceOf(address(userProxy));
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));

        _modifyCollateralAndDebt(
            address(vaultFY_USDC06),
            fyUSDC04,
            address(0),
            address(userProxy),
            0,
            -toInt256(200 * WAD)
        );

        assertEq(fiat.balanceOf(address(userProxy)), userProxyInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_increaseCollateral_from_underlier_and_increaseDebt() public {
        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        uint256 tokenAmount = 1000 * ONE_USDC;
        uint256 debtAmount = 500 * WAD;
        uint256 previewOut = vaultActions.underlierToFYToken(tokenAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            me,
            tokenAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        assertEq(underlierUSDC.balanceOf(me), meInitialBalance - tokenAmount);
        assertTrue(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)) >= vaultInitialBalance + tokenAmount);
        assertTrue(
            _collateral(address(vaultFY_USDC06), address(userProxy)) >=
                initialCollateral + wdiv(tokenAmount, 10**IERC20Metadata(fyUSDC04).decimals())
        );

        assertEq(fiat.balanceOf(me), fiatMeInitialBalance + debtAmount);
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt + debtAmount);
    }

    function test_increaseCollateral_from_user_underlier_and_increaseDebt() public {
        underlierUSDC.transfer(address(kakaroto), 1000 * ONE_USDC);

        uint256 meInitialBalance = underlierUSDC.balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        uint256 tokenAmount = 1000 * ONE_USDC;
        uint256 debtAmount = 500 * WAD;
        uint256 previewOut = vaultActions.underlierToFYToken(tokenAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            address(kakaroto),
            me,
            tokenAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        assertEq(underlierUSDC.balanceOf(address(kakaroto)), meInitialBalance - tokenAmount);
        assertTrue(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)) >= vaultInitialBalance + tokenAmount);
        assertTrue(
            _collateral(address(vaultFY_USDC06), address(userProxy)) >=
                initialCollateral + wdiv(tokenAmount, 10**IERC20Metadata(fyUSDC04).decimals())
        );

        assertEq(fiat.balanceOf(me), fiatMeInitialBalance + debtAmount);
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt + debtAmount);
    }

    function test_increaseCollateral_from_zeroAddress_proxy_underlier_and_increaseDebt() public {
        underlierUSDC.transfer(address(userProxy), 1000 * ONE_USDC);

        uint256 meInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        uint256 tokenAmount = 1000 * ONE_USDC;
        uint256 debtAmount = 500 * WAD;
        uint256 previewOut = vaultActions.underlierToFYToken(tokenAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            address(0),
            me,
            tokenAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        assertEq(underlierUSDC.balanceOf(address(userProxy)), meInitialBalance - tokenAmount);
        assertTrue(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)) >= vaultInitialBalance + tokenAmount);
        assertTrue(
            _collateral(address(vaultFY_USDC06), address(userProxy)) >=
                initialCollateral + wdiv(tokenAmount, 10**IERC20Metadata(fyUSDC04).decimals())
        );

        assertEq(fiat.balanceOf(me), fiatMeInitialBalance + debtAmount);
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt + debtAmount);
    }

    function test_increaseCollateral_from_proxy_underlier_and_increaseDebt() public {
        underlierUSDC.transfer(address(userProxy), 1000 * ONE_USDC);

        uint256 meInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        uint256 tokenAmount = 1000 * ONE_USDC;
        uint256 debtAmount = 500 * WAD;
        uint256 previewOut = vaultActions.underlierToFYToken(tokenAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            address(userProxy),
            me,
            tokenAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        assertEq(underlierUSDC.balanceOf(address(userProxy)), meInitialBalance - tokenAmount);
        assertTrue(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)) >= vaultInitialBalance + tokenAmount);
        assertTrue(
            _collateral(address(vaultFY_USDC06), address(userProxy)) >=
                initialCollateral + wdiv(tokenAmount, 10**IERC20Metadata(fyUSDC04).decimals())
        );

        assertEq(fiat.balanceOf(me), fiatMeInitialBalance + debtAmount);
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt + debtAmount);
    }

    function test_increaseCollateral_from_underlier_and_increaseDebt_send_fiat_to_user() public {
        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(address(kakaroto));

        uint256 tokenAmount = 1000 * ONE_USDC;
        uint256 debtAmount = 500 * WAD;
        uint256 previewOut = vaultActions.underlierToFYToken(tokenAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            address(kakaroto),
            tokenAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        assertEq(underlierUSDC.balanceOf(me), meInitialBalance - tokenAmount);
        assertTrue(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)) >= vaultInitialBalance + tokenAmount);
        assertTrue(
            _collateral(address(vaultFY_USDC06), address(userProxy)) >=
                initialCollateral + wdiv(tokenAmount, 10**IERC20Metadata(fyUSDC04).decimals())
        );

        assertEq(fiat.balanceOf(address(kakaroto)), fiatMeInitialBalance + debtAmount);
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt + debtAmount);
    }

    function test_decrease_debt_and_decrease_collateral_get_underlier() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            me,
            testAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        uint256 amount = 300 * ONE_USDC;
        uint256 expectedDelta = vaultActions.fyTokenToUnderlier(amount, fyUSDC04LP);

        VaultFYActions.SwapParams memory swapParams = _getSwapParams(
            fyUSDC04,
            address(underlierUSDC),
            expectedDelta / 2
        );

        _sellCollateralAndModifyDebt(address(vaultFY_USDC06), me, me, amount, -toInt256(100 * WAD), swapParams);

        assertTrue(underlierUSDC.balanceOf(me) >= meInitialBalance + swapParams.minAssetOut);
        assertEq(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)), vaultInitialBalance - amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(fyUSDC04).decimals());
        assertEq(_collateral(address(vaultFY_USDC06), address(userProxy)), initialCollateral - wadAmount);

        assertEq(fiat.balanceOf(me), fiatMeInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt - (100 * WAD));
    }

    function test_decrease_debt_and_decrease_collateral_get_underlier_to_user() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            me,
            testAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        uint256 amount = 300 * ONE_USDC;
        uint256 expectedDelta = vaultActions.fyTokenToUnderlier(amount, fyUSDC04LP);

        VaultFYActions.SwapParams memory swapParams = _getSwapParams(
            fyUSDC04,
            address(underlierUSDC),
            expectedDelta / 2
        );

        _sellCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            address(kakaroto),
            me,
            amount,
            -toInt256(100 * WAD),
            swapParams
        );

        assertTrue(underlierUSDC.balanceOf(address(kakaroto)) >= meInitialBalance + swapParams.minAssetOut);
        assertEq(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)), vaultInitialBalance - amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(fyUSDC04).decimals());
        assertEq(_collateral(address(vaultFY_USDC06), address(userProxy)), initialCollateral - wadAmount);

        assertEq(fiat.balanceOf(me), fiatMeInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt - (100 * WAD));
    }

    function test_decrease_debt_get_fiat_from_user_and_decrease_collateral_get_underlier() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            me,
            testAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));

        fiat.transfer(address(kakaroto), 500 * WAD);
        uint256 fiatKakarotoInitialBalance = fiat.balanceOf(address(kakaroto));

        uint256 amount = 300 * ONE_USDC;
        uint256 expectedDelta = vaultActions.fyTokenToUnderlier(amount, fyUSDC04LP);

        VaultFYActions.SwapParams memory swapParams = _getSwapParams(
            fyUSDC04,
            address(underlierUSDC),
            expectedDelta / 2
        );

        _sellCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            address(kakaroto),
            amount,
            -toInt256(100 * WAD),
            swapParams
        );

        assertTrue(underlierUSDC.balanceOf(me) >= meInitialBalance + swapParams.minAssetOut);
        assertEq(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)), vaultInitialBalance - amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(fyUSDC04).decimals());
        assertEq(_collateral(address(vaultFY_USDC06), address(userProxy)), initialCollateral - wadAmount);

        assertEq(fiat.balanceOf(address(kakaroto)), fiatKakarotoInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt - (100 * WAD));
    }

    function test_decrease_debt_get_fiat_from_proxy_zero_and_decrease_collateral_get_underlier() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            me,
            testAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));

        fiat.transfer(address(userProxy), 500 * WAD);
        uint256 fiatProxyInitialBalance = fiat.balanceOf(address(userProxy));

        uint256 amount = 300 * ONE_USDC;
        uint256 expectedDelta = vaultActions.fyTokenToUnderlier(amount, fyUSDC04LP);

        VaultFYActions.SwapParams memory swapParams = _getSwapParams(
            fyUSDC04,
            address(underlierUSDC),
            expectedDelta / 2
        );

        _sellCollateralAndModifyDebt(address(vaultFY_USDC06), me, address(0), amount, -toInt256(100 * WAD), swapParams);

        assertTrue(underlierUSDC.balanceOf(me) >= meInitialBalance + swapParams.minAssetOut);
        assertEq(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)), vaultInitialBalance - amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(fyUSDC04).decimals());
        assertEq(_collateral(address(vaultFY_USDC06), address(userProxy)), initialCollateral - wadAmount);

        assertEq(fiat.balanceOf(address(userProxy)), fiatProxyInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt - (100 * WAD));
    }

    function test_decrease_debt_get_fiat_from_proxy_and_decrease_collateral_get_underlier() public {
        uint256 testAmount = 1000 * ONE_USDC;
        uint256 previewOut = vaultActions.underlierToFYToken(testAmount, fyUSDC04LP);

        _buyCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            me,
            testAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), fyUSDC04, previewOut)
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06));
        uint256 initialCollateral = _collateral(address(vaultFY_USDC06), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vaultFY_USDC06), address(userProxy));

        fiat.transfer(address(userProxy), 500 * WAD);
        uint256 fiatProxyInitialBalance = fiat.balanceOf(address(userProxy));

        uint256 amount = 300 * ONE_USDC;
        uint256 expectedDelta = vaultActions.fyTokenToUnderlier(amount, fyUSDC04LP);

        VaultFYActions.SwapParams memory swapParams = _getSwapParams(
            fyUSDC04,
            address(underlierUSDC),
            expectedDelta / 2
        );

        _sellCollateralAndModifyDebt(
            address(vaultFY_USDC06),
            me,
            address(userProxy),
            amount,
            -toInt256(100 * WAD),
            swapParams
        );

        assertTrue(underlierUSDC.balanceOf(me) >= meInitialBalance + swapParams.minAssetOut);
        assertEq(ERC20(fyUSDC04).balanceOf(address(vaultFY_USDC06)), vaultInitialBalance - amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(fyUSDC04).decimals());
        assertEq(_collateral(address(vaultFY_USDC06), address(userProxy)), initialCollateral - wadAmount);

        assertEq(fiat.balanceOf(address(userProxy)), fiatProxyInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vaultFY_USDC06), address(userProxy)), initialDebt - (100 * WAD));
    }
}
