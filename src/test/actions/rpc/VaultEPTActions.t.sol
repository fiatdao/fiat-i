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

import {VaultEPT} from "../../../vaults/VaultEPT.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";

import {Caller} from "../../../test/utils/Caller.sol";

import {VaultEPTActions} from "../../../actions/vault/VaultEPTActions.sol";
import {IBalancerVault} from "../../../actions/helper/ConvergentCurvePoolHelper.sol";

interface ITrancheFactory {
    function deployTranche(uint256 expiration, address wpAddress) external returns (address);
}

interface ITranche {
    function balanceOf(address owner) external view returns (uint256);

    function deposit(uint256 shares, address destination) external returns (uint256, uint256);
}

interface ICCP {
    function getPoolId() external view returns (bytes32);

    function getVault() external view returns (address);

    function solveTradeInvariant(
        uint256 amountX,
        uint256 reserveX,
        uint256 reserveY,
        bool out
    ) external view returns (uint256);

    function percentFee() external view returns (uint256);
}

contract VaultEPTActions_RPC_tests is Test {
    Codex internal codex;
    Publican internal publican;
    address internal collybus = address(0xc0111b115);
    Moneta internal moneta;
    FIAT internal fiat;
    PRBProxy internal userProxy;
    PRBProxyFactory internal prbProxyFactory;
    Caller internal kakaroto;
    VaultEPTActions internal vaultActions;

    VaultFactory internal vaultFactory;
    VaultEPT internal vaultYUSDC_V4_impl;
    VaultEPT internal vaultYUSDC_V4_3Months;
    VaultEPT internal vault_yvUSDC_17DEC21;

    ITrancheFactory internal trancheFactory = ITrancheFactory(0x62F161BF3692E4015BefB05A03a94A40f520d1c0);
    IERC20 internal underlierUSDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    address internal wrappedPositionYUSDC = address(0xdEa04Ffc66ECD7bf35782C70255852B34102C3b0);
    address internal trancheUSDC_V4_yvUSDC_17DEC21 = address(0x76a34D72b9CF97d972fB0e390eB053A37F211c74);
    address internal ccp_yvUSDC_17DEC21 = address(0x90CA5cEf5B29342b229Fb8AE2DB5d8f4F894D652);
    address internal trancheUSDC_V4_3Months;

    uint256 internal ONE_USDC = 1e6;
    uint256 internal tokenId = 0;
    address internal me = address(this);

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
        VaultEPTActions.SwapParams memory swapParams
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
        VaultEPTActions.SwapParams memory swapParams
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
                VaultEPT(vault).token(),
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
        uint256 minOutput,
        uint256 assetInAmount
    ) internal view returns (VaultEPTActions.SwapParams memory swapParams) {
        swapParams.balancerVault = ICCP(ccp_yvUSDC_17DEC21).getVault();
        swapParams.poolId = ICCP(ccp_yvUSDC_17DEC21).getPoolId();
        swapParams.assetIn = assetIn;
        swapParams.assetOut = assetOut;
        swapParams.minOutput = minOutput;
        swapParams.deadline = block.timestamp + 12 weeks;
        swapParams.approve = assetInAmount;
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
        vaultActions = new VaultEPTActions(address(codex), address(moneta), address(fiat), address(publican));

        prbProxyFactory = new PRBProxyFactory();

        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        vaultYUSDC_V4_impl = new VaultEPT(
            address(codex),
            wrappedPositionYUSDC,
            address(0x62F161BF3692E4015BefB05A03a94A40f520d1c0)
        );

        codex.setParam("globalDebtCeiling", uint256(1000 ether));
        codex.allowCaller(keccak256("ANY_SIG"), address(publican));

        _mintUSDC(me, 2000000 * ONE_USDC);
        trancheUSDC_V4_3Months = trancheFactory.deployTranche(block.timestamp + 12 weeks, wrappedPositionYUSDC);
        underlierUSDC.approve(trancheUSDC_V4_3Months, type(uint256).max);

        ITranche(trancheUSDC_V4_3Months).deposit(1000 * ONE_USDC, me);

        underlierUSDC.approve(trancheUSDC_V4_yvUSDC_17DEC21, type(uint256).max);
        ITranche(trancheUSDC_V4_yvUSDC_17DEC21).deposit(1000 * ONE_USDC, me);

        address instance = vaultFactory.createVault(
            address(vaultYUSDC_V4_impl),
            abi.encode(trancheUSDC_V4_3Months, collybus)
        );
        vaultYUSDC_V4_3Months = VaultEPT(instance);
        codex.setParam(instance, "debtCeiling", uint256(1000 ether));
        codex.allowCaller(codex.modifyBalance.selector, instance);
        codex.init(instance);

        publican.init(instance);
        publican.setParam(instance, "interestPerSecond", WAD);

        IERC20(trancheUSDC_V4_3Months).approve(address(userProxy), type(uint256).max);
        kakaroto.externalCall(
            trancheUSDC_V4_3Months,
            abi.encodeWithSelector(IERC20.approve.selector, address(userProxy), type(uint256).max)
        );

        fiat.approve(address(userProxy), type(uint256).max);
        kakaroto.externalCall(
            address(fiat),
            abi.encodeWithSelector(fiat.approve.selector, address(userProxy), type(uint256).max)
        );
        kakaroto.externalCall(
            address(underlierUSDC),
            abi.encodeWithSelector(underlierUSDC.approve.selector, address(userProxy), type(uint256).max)
        );

        vm.mockCall(collybus, abi.encodeWithSelector(Collybus.read.selector), abi.encode(uint256(WAD)));
        
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), type(uint256).max)
        );

        //--------------------------------------

        VaultEPT impl2 = new VaultEPT(
            address(codex),
            wrappedPositionYUSDC,
            address(0x62F161BF3692E4015BefB05A03a94A40f520d1c0)
        );

        underlierUSDC.approve(trancheUSDC_V4_yvUSDC_17DEC21, type(uint256).max);
        ITranche(trancheUSDC_V4_yvUSDC_17DEC21).deposit(1000 * ONE_USDC, me);

        address instance_yvUSDC_17DEC21 = vaultFactory.createVault(
            address(impl2),
            abi.encode(address(trancheUSDC_V4_yvUSDC_17DEC21), address(collybus), ccp_yvUSDC_17DEC21)
        );
        vault_yvUSDC_17DEC21 = VaultEPT(instance_yvUSDC_17DEC21);
        codex.setParam(instance_yvUSDC_17DEC21, "debtCeiling", uint256(1000 ether));
        codex.allowCaller(codex.modifyBalance.selector, instance_yvUSDC_17DEC21);
        codex.init(instance_yvUSDC_17DEC21);

        publican.init(instance_yvUSDC_17DEC21);
        publican.setParam(instance_yvUSDC_17DEC21, "interestPerSecond", WAD);

        // need this for the swapAndEnter
        underlierUSDC.approve(address(userProxy), type(uint256).max);
        IERC20(trancheUSDC_V4_yvUSDC_17DEC21).approve(address(userProxy), type(uint256).max);
    }

    function test_increaseCollateral_from_underlier() public {
        uint256 amount = 100 * ONE_USDC;
        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));

        uint256 price = vaultActions.underlierToPToken(
            address(vault_yvUSDC_17DEC21),
            ICCP(ccp_yvUSDC_17DEC21).getVault(),
            ICCP(ccp_yvUSDC_17DEC21).getPoolId(),
            vault_yvUSDC_17DEC21.underlierScale()
        );

        _buyCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            me,
            address(0),
            amount,
            0,
            _getSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_17DEC21, 0, amount)
        );

        // emit log_named_uint("vaultInitialBalance", vaultInitialBalance);
        // emit log_named_uint("expected delta", ((amount * price) / ONE_USDC));
        // emit log_named_uint("balance", ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)));

        assertEq(underlierUSDC.balanceOf(me), meInitialBalance - amount);
        assertTrue(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)) >=
                vaultInitialBalance + ((amount * price) / ONE_USDC)
        );
        assertTrue(
            _collateral(address(vault_yvUSDC_17DEC21), address(userProxy)) >=
                initialCollateral + wdiv(amount, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())
        );
    }

    function test_increaseCollateral_from_user_underlier() public {
        uint256 amount = 100 * ONE_USDC;
        underlierUSDC.transfer(address(kakaroto), amount);

        uint256 kakarotoInitialBalance = underlierUSDC.balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));

        _buyCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            address(kakaroto),
            address(0),
            amount,
            0,
            _getSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_17DEC21, 0, amount)
        );

        assertEq(underlierUSDC.balanceOf(address(kakaroto)), kakarotoInitialBalance - amount);
        assertTrue(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)) >=
                vaultInitialBalance + amount
        );
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals());
        assertTrue(_collateral(address(vault_yvUSDC_17DEC21), address(userProxy)) >= initialCollateral + wadAmount);
    }

    function test_increaseCollateral_from_proxy_zero_underlier() public {
        uint256 amount = 100 * ONE_USDC;
        underlierUSDC.transfer(address(userProxy), amount);

        uint256 userProxyInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));

        _buyCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            address(0),
            address(0),
            amount,
            0,
            _getSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_17DEC21, 0, amount)
        );

        assertEq(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance - amount);
        assertTrue(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)) >=
                vaultInitialBalance + amount
        );
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals());
        assertTrue(_collateral(address(vault_yvUSDC_17DEC21), address(userProxy)) >= initialCollateral + wadAmount);
    }

    function test_increaseCollateral_from_proxy_address_underlier() public {
        uint256 amount = 100 * ONE_USDC;
        underlierUSDC.transfer(address(userProxy), amount);

        uint256 userProxyInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));

        _buyCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            address(userProxy),
            address(0),
            amount,
            0,
            _getSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_17DEC21, 0, amount)
        );

        assertEq(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance - amount);
        assertTrue(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)) >=
                vaultInitialBalance + amount
        );
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals());
        assertTrue(_collateral(address(vault_yvUSDC_17DEC21), address(userProxy)) >= initialCollateral + wadAmount);
    }

    function test_decreaseCollateral_get_underlier() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            address(0),
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            0
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));

        uint256 price = vaultActions.pTokenToUnderlier(
            address(vault_yvUSDC_17DEC21),
            ICCP(ccp_yvUSDC_17DEC21).getVault(),
            ICCP(ccp_yvUSDC_17DEC21).getPoolId(),
            vault_yvUSDC_17DEC21.tokenScale()
        );

        uint256 amount = 500 * ONE_USDC;

        VaultEPTActions.SwapParams memory swapParams = _getSwapParams(
            trancheUSDC_V4_yvUSDC_17DEC21,
            address(underlierUSDC),
            amount / 2,
            amount
        );

        _sellCollateralAndModifyDebt(address(vault_yvUSDC_17DEC21), me, address(0), amount, 0, swapParams);

        uint256 expectedDelta = ((amount * price) / ONE_USDC);

        // emit log_named_uint("meInitialBalance", meInitialBalance);
        // emit log_named_uint("expectedDelta", expectedDelta);
        // emit log_named_uint("balance", underlierUSDC.balanceOf(me));

        assertTrue(underlierUSDC.balanceOf(me) >= meInitialBalance + expectedDelta);
        assertEq(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)),
            vaultInitialBalance - amount
        );
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals());
        assertEq(_collateral(address(vault_yvUSDC_17DEC21), address(userProxy)), initialCollateral - wadAmount);
    }

    function test_decreaseCollateral_send_underlier_to_user() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            address(0),
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            0
        );

        uint256 kakarotoInitialBalance = underlierUSDC.balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));

        uint256 amount = 500 * ONE_USDC;

        VaultEPTActions.SwapParams memory swapParams = _getSwapParams(
            trancheUSDC_V4_yvUSDC_17DEC21,
            address(underlierUSDC),
            amount / 2,
            amount
        );

        _sellCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            address(kakaroto),
            address(0),
            amount,
            0,
            swapParams
        );

        assertTrue(underlierUSDC.balanceOf(address(kakaroto)) >= kakarotoInitialBalance + swapParams.minOutput);
        assertEq(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)),
            vaultInitialBalance - amount
        );
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals());
        assertEq(_collateral(address(vault_yvUSDC_17DEC21), address(userProxy)), initialCollateral - wadAmount);
    }

    function test_decreaseCollateral_redeem_underlier() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            address(0),
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            0
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));

        uint256 amount = 500 * ONE_USDC;

        vm.roll(block.number + ((vault_yvUSDC_17DEC21.maturity(0) - block.timestamp) / 12));
        vm.warp(vault_yvUSDC_17DEC21.maturity(0));

        // VaultEPTActions.SwapParams memory swapParams = _getSwapParams(
        //     trancheUSDC_V4_yvUSDC_17DEC21,
        //     address(underlierUSDC),
        //     amount / 2,
        //     amount
        // );

        _redeemCollateralAndModifyDebt(address(vault_yvUSDC_17DEC21), me, address(0), amount, 0);

        assertTrue(underlierUSDC.balanceOf(me) >= meInitialBalance);
        assertEq(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)),
            vaultInitialBalance - amount
        );
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals());
        assertEq(_collateral(address(vault_yvUSDC_17DEC21), address(userProxy)), initialCollateral - wadAmount);
    }

    function test_decreaseCollateral_redeem_underlier_to_user() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            address(0),
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            0
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));

        uint256 amount = 500 * ONE_USDC;

        vm.roll(block.number + ((vault_yvUSDC_17DEC21.maturity(0) - block.timestamp) / 12));
        vm.warp(vault_yvUSDC_17DEC21.maturity(0));

        _redeemCollateralAndModifyDebt(address(vault_yvUSDC_17DEC21), address(kakaroto), address(0), amount, 0);

        assertTrue(underlierUSDC.balanceOf(address(kakaroto)) >= meInitialBalance);
        assertEq(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)),
            vaultInitialBalance - amount
        );
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals());
        assertEq(_collateral(address(vault_yvUSDC_17DEC21), address(userProxy)), initialCollateral - wadAmount);
    }

    function test_increaseDebt() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            address(0),
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            0
        );

        uint256 meInitialBalance = fiat.balanceOf(me);
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));

        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            address(0),
            me,
            0,
            toInt256(500 * WAD)
        );

        assertEq(fiat.balanceOf(me), meInitialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_increaseDebt_send_to_user() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            address(0),
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            0
        );

        uint256 kakarotoInitialBalance = fiat.balanceOf(address(kakaroto));
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));

        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            address(0),
            address(kakaroto),
            0,
            toInt256(500 * WAD)
        );

        assertEq(fiat.balanceOf(address(kakaroto)), kakarotoInitialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_decreaseDebt() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            me,
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            toInt256(500 * WAD)
        );

        uint256 meInitialBalance = fiat.balanceOf(me);
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));

        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            address(0),
            me,
            0,
            -toInt256(200 * WAD)
        );

        assertEq(fiat.balanceOf(me), meInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decreaseDebt_get_fiat_from_user() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            me,
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            toInt256(500 * WAD)
        );

        fiat.transfer(address(kakaroto), 500 * WAD);

        uint256 kakarotoInitialBalance = fiat.balanceOf(address(kakaroto));
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));

        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            address(0),
            address(kakaroto),
            0,
            -toInt256(200 * WAD)
        );

        assertEq(fiat.balanceOf(address(kakaroto)), kakarotoInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decreaseDebt_get_fiat_from_proxy_zero() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            me,
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            toInt256(500 * WAD)
        );

        fiat.transfer(address(userProxy), 500 * WAD);

        uint256 userProxyInitialBalance = fiat.balanceOf(address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));

        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            address(0),
            address(0),
            0,
            -toInt256(200 * WAD)
        );

        assertEq(fiat.balanceOf(address(userProxy)), userProxyInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decreaseDebt_get_fiat_from_proxy_address() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            me,
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            toInt256(500 * WAD)
        );

        fiat.transfer(address(userProxy), 500 * WAD);

        uint256 userProxyInitialBalance = fiat.balanceOf(address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));

        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            address(0),
            address(userProxy),
            0,
            -toInt256(200 * WAD)
        );

        assertEq(fiat.balanceOf(address(userProxy)), userProxyInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_increaseCollateral_from_underlier_and_increaseDebt() public {
        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        uint256 tokenAmount = 1000 * ONE_USDC;
        uint256 debtAmount = 500 * WAD;

        _buyCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            me,
            me,
            tokenAmount,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_17DEC21, 0, tokenAmount)
        );

        assertEq(underlierUSDC.balanceOf(me), meInitialBalance - tokenAmount);
        assertTrue(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)) >=
                vaultInitialBalance + tokenAmount
        );
        assertTrue(
            _collateral(address(vault_yvUSDC_17DEC21), address(userProxy)) >=
                initialCollateral + wdiv(tokenAmount, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())
        );

        assertEq(fiat.balanceOf(me), fiatMeInitialBalance + debtAmount);
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt + debtAmount);
    }

    function test_increaseCollateral_from_user_underlier_and_increaseDebt() public {
        underlierUSDC.transfer(address(kakaroto), 1000 * ONE_USDC);

        uint256 meInitialBalance = underlierUSDC.balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        _buyCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            address(kakaroto),
            me,
            1000 * ONE_USDC,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_17DEC21, 0, 1000 * ONE_USDC)
        );

        assertEq(underlierUSDC.balanceOf(address(kakaroto)), meInitialBalance - 1000 * ONE_USDC);
        assertTrue(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)) >=
                vaultInitialBalance + 1000 * ONE_USDC
        );
        assertTrue(
            _collateral(address(vault_yvUSDC_17DEC21), address(userProxy)) >=
                initialCollateral + wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())
        );

        assertEq(fiat.balanceOf(me), fiatMeInitialBalance + 500 * WAD);
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt + 500 * WAD);
    }

    function test_increaseCollateral_from_zeroAddress_proxy_underlier_and_increaseDebt() public {
        underlierUSDC.transfer(address(userProxy), 1000 * ONE_USDC);

        uint256 meInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        _buyCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            address(0),
            me,
            1000 * ONE_USDC,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_17DEC21, 0, 1000 * ONE_USDC)
        );

        assertEq(underlierUSDC.balanceOf(address(userProxy)), meInitialBalance - 1000 * ONE_USDC);
        assertTrue(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)) >=
                vaultInitialBalance + 1000 * ONE_USDC
        );
        assertTrue(
            _collateral(address(vault_yvUSDC_17DEC21), address(userProxy)) >=
                initialCollateral + wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())
        );

        assertEq(fiat.balanceOf(me), fiatMeInitialBalance + 500 * WAD);
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt + 500 * WAD);
    }

    function test_increaseCollateral_from_proxy_underlier_and_increaseDebt() public {
        underlierUSDC.transfer(address(userProxy), 1000 * ONE_USDC);

        uint256 meInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        _buyCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            address(userProxy),
            me,
            1000 * ONE_USDC,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_17DEC21, 0, 1000 * ONE_USDC)
        );

        assertEq(underlierUSDC.balanceOf(address(userProxy)), meInitialBalance - 1000 * ONE_USDC);
        assertTrue(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)) >=
                vaultInitialBalance + 1000 * ONE_USDC
        );
        assertTrue(
            _collateral(address(vault_yvUSDC_17DEC21), address(userProxy)) >=
                initialCollateral + wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())
        );

        assertEq(fiat.balanceOf(me), fiatMeInitialBalance + 500 * WAD);
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt + 500 * WAD);
    }

    function test_increaseCollateral_from_underlier_and_increaseDebt_send_fiat_to_user() public {
        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(address(kakaroto));

        _buyCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            me,
            address(kakaroto),
            1000 * ONE_USDC,
            toInt256(500 * WAD),
            _getSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_17DEC21, 0, 1000 * ONE_USDC)
        );

        assertEq(underlierUSDC.balanceOf(me), meInitialBalance - 1000 * ONE_USDC);
        assertTrue(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)) >=
                vaultInitialBalance + 1000 * ONE_USDC
        );
        assertTrue(
            _collateral(address(vault_yvUSDC_17DEC21), address(userProxy)) >=
                initialCollateral + wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())
        );

        assertEq(fiat.balanceOf(address(kakaroto)), fiatMeInitialBalance + 500 * WAD);
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt + 500 * WAD);
    }

    function test_decrease_debt_and_decrease_collateral_get_underlier() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            me,
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            toInt256(500 * WAD)
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        VaultEPTActions.SwapParams memory swapParams = _getSwapParams(
            trancheUSDC_V4_yvUSDC_17DEC21,
            address(underlierUSDC),
            250 * ONE_USDC,
            300 * ONE_USDC
        );

        _sellCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            me,
            me,
            300 * ONE_USDC,
            -toInt256(100 * WAD),
            swapParams
        );

        assertTrue(underlierUSDC.balanceOf(me) >= meInitialBalance + swapParams.minOutput);
        assertEq(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)),
            vaultInitialBalance - (300 * ONE_USDC)
        );
        uint256 wadAmount = wdiv((300 * ONE_USDC), 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals());
        assertEq(_collateral(address(vault_yvUSDC_17DEC21), address(userProxy)), initialCollateral - wadAmount);

        assertEq(fiat.balanceOf(me), fiatMeInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt - (100 * WAD));
    }

    function test_decrease_debt_and_decrease_collateral_get_underlier_to_user() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            me,
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            toInt256(500 * WAD)
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        VaultEPTActions.SwapParams memory swapParams = _getSwapParams(
            trancheUSDC_V4_yvUSDC_17DEC21,
            address(underlierUSDC),
            250 * ONE_USDC, // this actually needs to be calculated base on the current ratio minus some acceptable
            300 * ONE_USDC
        );
        _sellCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            address(kakaroto),
            me,
            300 * ONE_USDC,
            -toInt256(100 * WAD),
            swapParams
        );

        assertTrue(underlierUSDC.balanceOf(address(kakaroto)) >= meInitialBalance + swapParams.minOutput);
        assertEq(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)),
            vaultInitialBalance - (300 * ONE_USDC)
        );
        uint256 wadAmount = wdiv((300 * ONE_USDC), 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals());
        assertEq(_collateral(address(vault_yvUSDC_17DEC21), address(userProxy)), initialCollateral - wadAmount);

        assertEq(fiat.balanceOf(me), fiatMeInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt - (100 * WAD));
    }

    function test_decrease_debt_get_fiat_from_user_and_decrease_collateral_get_underlier() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            me,
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            toInt256(500 * WAD)
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));

        fiat.transfer(address(kakaroto), 500 * WAD);
        uint256 fiatKakarotoInitialBalance = fiat.balanceOf(address(kakaroto));

        VaultEPTActions.SwapParams memory swapParams = _getSwapParams(
            trancheUSDC_V4_yvUSDC_17DEC21,
            address(underlierUSDC),
            250 * ONE_USDC, // this actually needs to be calculated base on the current ratio minus some acceptable
            300 * ONE_USDC
        );

        _sellCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            me,
            address(kakaroto),
            300 * ONE_USDC,
            -toInt256(100 * WAD),
            swapParams
        );

        assertTrue(underlierUSDC.balanceOf(me) >= meInitialBalance + swapParams.minOutput);
        assertEq(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)),
            vaultInitialBalance - (300 * ONE_USDC)
        );
        uint256 wadAmount = wdiv((300 * ONE_USDC), 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals());
        assertEq(_collateral(address(vault_yvUSDC_17DEC21), address(userProxy)), initialCollateral - wadAmount);

        assertEq(fiat.balanceOf(address(kakaroto)), fiatKakarotoInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt - (100 * WAD));
    }

    function test_decrease_debt_get_fiat_from_proxy_zero_and_decrease_collateral_get_underlier() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            me,
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            toInt256(500 * WAD)
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));

        fiat.transfer(address(userProxy), 500 * WAD);
        uint256 fiatProxyInitialBalance = fiat.balanceOf(address(userProxy));

        VaultEPTActions.SwapParams memory swapParams = _getSwapParams(
            trancheUSDC_V4_yvUSDC_17DEC21,
            address(underlierUSDC),
            250 * ONE_USDC,
            300 * ONE_USDC
        );

        _sellCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            me,
            address(0),
            300 * ONE_USDC,
            -toInt256(100 * WAD),
            swapParams
        );

        assertTrue(underlierUSDC.balanceOf(me) >= meInitialBalance + swapParams.minOutput);
        assertEq(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)),
            vaultInitialBalance - (300 * ONE_USDC)
        );
        uint256 wadAmount = wdiv((300 * ONE_USDC), 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals());
        assertEq(_collateral(address(vault_yvUSDC_17DEC21), address(userProxy)), initialCollateral - wadAmount);

        assertEq(fiat.balanceOf(address(userProxy)), fiatProxyInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt - (100 * WAD));
    }

    function test_decrease_debt_get_fiat_from_proxy_and_decrease_collateral_get_underlier() public {
        _modifyCollateralAndDebt(
            address(vault_yvUSDC_17DEC21),
            trancheUSDC_V4_yvUSDC_17DEC21,
            me,
            me,
            toInt256(wdiv(1000 * ONE_USDC, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals())),
            toInt256(500 * WAD)
        );

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_17DEC21), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy));

        fiat.transfer(address(userProxy), 500 * WAD);
        uint256 fiatProxyInitialBalance = fiat.balanceOf(address(userProxy));

        VaultEPTActions.SwapParams memory swapParams = _getSwapParams(
            trancheUSDC_V4_yvUSDC_17DEC21,
            address(underlierUSDC),
            250 * ONE_USDC,
            300 * ONE_USDC
        );

        _sellCollateralAndModifyDebt(
            address(vault_yvUSDC_17DEC21),
            me,
            address(userProxy),
            300 * ONE_USDC,
            -toInt256(100 * WAD),
            swapParams
        );

        assertTrue(underlierUSDC.balanceOf(me) >= meInitialBalance + swapParams.minOutput);
        assertEq(
            ERC20(trancheUSDC_V4_yvUSDC_17DEC21).balanceOf(address(vault_yvUSDC_17DEC21)),
            vaultInitialBalance - (300 * ONE_USDC)
        );
        uint256 wadAmount = wdiv((300 * ONE_USDC), 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_17DEC21).decimals());
        assertEq(_collateral(address(vault_yvUSDC_17DEC21), address(userProxy)), initialCollateral - wadAmount);

        assertEq(fiat.balanceOf(address(userProxy)), fiatProxyInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vault_yvUSDC_17DEC21), address(userProxy)), initialDebt - (100 * WAD));
    }
}
