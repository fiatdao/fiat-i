// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Codex} from "../../../Codex.sol";
import {Collybus} from "../../../Collybus.sol";
import {Publican} from "../../../Publican.sol";
import {FIAT} from "../../../FIAT.sol";
import {Flash} from "../../../Flash.sol";
import {Moneta} from "../../../Moneta.sol";
import {toInt256, WAD, wdiv} from "../../../utils/Math.sol";

import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {VaultEPT} from "../../../vaults/VaultEPT.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";

import {Caller} from "../../../test/utils/Caller.sol";

import {VaultEPTActions} from "../../vault/VaultEPTActions.sol";
import {LeverEPTActions} from "../../lever/LeverEPTActions.sol";
import {IBalancerVault} from "../../helper/ConvergentCurvePoolHelper.sol";

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

contract LeverEPTActions_RPC_tests is Test {
    Codex internal codex;
    Publican internal publican;
    address internal collybus = address(0xc0111b115);
    Moneta internal moneta;
    FIAT internal fiat;
    Flash internal flash;
    PRBProxy internal userProxy;
    PRBProxyFactory internal prbProxyFactory;
    Caller internal user;
    LeverEPTActions internal leverActions;
    VaultEPTActions internal vaultActions;

    VaultEPT internal vaultYUSDC_V4_impl;
    VaultEPT internal vaultYUSDC_V4_3Months;
    VaultEPT internal vault_yvUSDC_16SEP22;
    VaultFactory internal vaultFactory;

    ITrancheFactory internal trancheFactory = ITrancheFactory(0x62F161BF3692E4015BefB05A03a94A40f520d1c0);
    IERC20 internal underlierUSDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    address internal wrappedPositionYUSDC = address(0x57A170cEC0c9Daa701d918d60809080C4Ba3C570);
    address internal trancheUSDC_V4_yvUSDC_16SEP22 = address(0xCFe60a1535ecc5B0bc628dC97111C8bb01637911);
    address internal ccp_yvUSDC_16SEP22 = address(0x56df5ef1A0A86c2A5Dd9cC001Aa8152545BDbdeC);
    address internal trancheUSDC_V4_3Months;

    bytes32 internal fiatPoolId = 0x178e029173417b1f9c8bc16dcec6f697bc32374600000000000000000000025d;
    address internal fiatBalancerVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    uint256 internal tokenId = 0;
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

    function _collateral(address vault, address user_) internal view returns (uint256) {
        (uint256 collateral, ) = codex.positions(vault, 0, user_);
        return collateral;
    }

    function _normalDebt(address vault, address user_) internal view returns (uint256) {
        (, uint256 normalDebt) = codex.positions(vault, 0, user_);
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

    function _buyCollateralAndIncreaseLever(
        address vault,
        address collateralizer,
        uint256 underlierAmount,
        uint256 deltaNormalDebt,
        LeverEPTActions.SellFIATSwapParams memory fiatSwapParams,
        LeverEPTActions.CollateralSwapParams memory collateralSwapParams
    ) internal {
        userProxy.execute(
            address(leverActions),
            abi.encodeWithSelector(
                leverActions.buyCollateralAndIncreaseLever.selector,
                vault,
                address(userProxy),
                collateralizer,
                underlierAmount,
                deltaNormalDebt,
                fiatSwapParams,
                collateralSwapParams
            )
        );
    }

    function _sellCollateralAndDecreaseLever(
        address vault,
        address collateralizer,
        uint256 pTokenAmount,
        uint256 deltaNormalDebt,
        LeverEPTActions.BuyFIATSwapParams memory fiatSwapParams,
        LeverEPTActions.CollateralSwapParams memory collateralSwapParams
    ) internal {
        userProxy.execute(
            address(leverActions),
            abi.encodeWithSelector(
                leverActions.sellCollateralAndDecreaseLever.selector,
                vault,
                address(userProxy),
                collateralizer,
                pTokenAmount,
                deltaNormalDebt,
                fiatSwapParams,
                collateralSwapParams
            )
        );
    }

    function _redeemCollateralAndDecreaseLever(
        address vault,
        address token,
        address collateralizer,
        uint256 pTokenAmount,
        uint256 deltaNormalDebt,
        LeverEPTActions.BuyFIATSwapParams memory fiatSwapParams
    ) internal {
        userProxy.execute(
            address(leverActions),
            abi.encodeWithSelector(
                leverActions.redeemCollateralAndDecreaseLever.selector,
                vault,
                token,
                address(userProxy),
                collateralizer,
                pTokenAmount,
                deltaNormalDebt,
                fiatSwapParams
            )
        );
    }

    function _getCollateralSwapParams(
        address assetIn,
        address assetOut,
        uint256 minAmountOut
    ) internal view returns (LeverEPTActions.CollateralSwapParams memory collateralSwapParams) {
        collateralSwapParams.balancerVault = ICCP(ccp_yvUSDC_16SEP22).getVault();
        collateralSwapParams.poolId = ICCP(ccp_yvUSDC_16SEP22).getPoolId();
        collateralSwapParams.assetIn = assetIn;
        collateralSwapParams.assetOut = assetOut;
        collateralSwapParams.minAmountOut = minAmountOut;
        collateralSwapParams.deadline = block.timestamp + 12 weeks;
    }

    function _getSellFIATSwapParams(address assetOut, uint256 minAmountOut)
        internal
        view
        returns (LeverEPTActions.SellFIATSwapParams memory fiatSwapParams)
    {
        fiatSwapParams.assetOut = assetOut;
        fiatSwapParams.minAmountOut = minAmountOut;
        fiatSwapParams.deadline = block.timestamp + 12 weeks;
    }

    function _getBuyFIATSwapParams(address assetIn, uint256 maxAmountIn)
        internal
        view
        returns (LeverEPTActions.BuyFIATSwapParams memory fiatSwapParams)
    {
        fiatSwapParams.assetIn = assetIn;
        fiatSwapParams.maxAmountIn = maxAmountIn;
        fiatSwapParams.deadline = block.timestamp + 12 weeks;
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 15100000);

        user = new Caller();
        vaultFactory = new VaultFactory();
        codex = new Codex();
        publican = new Publican(address(codex));
        fiat = FIAT(0x586Aa273F262909EEF8fA02d90Ab65F5015e0516);
        vm.startPrank(0xa55E0d3d697C4692e9C37bC3a7062b1bECeEF45B);
        fiat.allowCaller(fiat.ANY_SIG(), address(this));
        vm.stopPrank();

        moneta = new Moneta(address(codex), address(fiat));
        flash = new Flash(address(moneta));
        fiat.allowCaller(fiat.mint.selector, address(moneta));

        vaultActions = new VaultEPTActions(address(codex), address(moneta), address(fiat), address(publican));
        leverActions = new LeverEPTActions(
            address(codex),
            address(fiat),
            address(flash),
            address(moneta),
            address(publican),
            fiatPoolId,
            fiatBalancerVault
        );

        prbProxyFactory = new PRBProxyFactory();

        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        vaultYUSDC_V4_impl = new VaultEPT(
            address(codex),
            wrappedPositionYUSDC,
            address(0x62F161BF3692E4015BefB05A03a94A40f520d1c0)
        );

        codex.setParam("globalDebtCeiling", uint256(10000 ether));
        codex.allowCaller(keccak256("ANY_SIG"), address(publican));
        codex.allowCaller(keccak256("ANY_SIG"), address(flash));

        _mintUSDC(me, 10000 * ONE_USDC);
        trancheUSDC_V4_3Months = trancheFactory.deployTranche(block.timestamp + 12 weeks, wrappedPositionYUSDC);
        underlierUSDC.approve(trancheUSDC_V4_3Months, type(uint256).max);

        ITranche(trancheUSDC_V4_3Months).deposit(1000 * ONE_USDC, me);

        underlierUSDC.approve(trancheUSDC_V4_yvUSDC_16SEP22, type(uint256).max);
        ITranche(trancheUSDC_V4_yvUSDC_16SEP22).deposit(1000 * ONE_USDC, me);

        address instance = vaultFactory.createVault(
            address(vaultYUSDC_V4_impl),
            abi.encode(trancheUSDC_V4_3Months, address(collybus))
        );
        vaultYUSDC_V4_3Months = VaultEPT(instance);
        codex.setParam(instance, "debtCeiling", uint256(10000 ether));
        codex.allowCaller(codex.modifyBalance.selector, instance);
        codex.init(instance);

        publican.init(instance);
        publican.setParam(instance, "interestPerSecond", WAD);

        IERC20(trancheUSDC_V4_3Months).approve(address(userProxy), type(uint256).max);
        user.externalCall(
            trancheUSDC_V4_3Months,
            abi.encodeWithSelector(IERC20.approve.selector, address(userProxy), type(uint256).max)
        );

        fiat.approve(address(userProxy), type(uint256).max);
        user.externalCall(
            address(fiat),
            abi.encodeWithSelector(fiat.approve.selector, address(userProxy), type(uint256).max)
        );
        user.externalCall(
            address(underlierUSDC),
            abi.encodeWithSelector(underlierUSDC.approve.selector, address(userProxy), type(uint256).max)
        );

        vm.mockCall(collybus, abi.encodeWithSelector(Collybus.read.selector), abi.encode(uint256(WAD)));
        
        userProxy.execute(
            address(leverActions),
            abi.encodeWithSelector(leverActions.approveFIAT.selector, address(moneta), type(uint256).max)
        );

        //--------------------------------------

        VaultEPT impl2 = new VaultEPT(
            address(codex),
            wrappedPositionYUSDC,
            address(0x62F161BF3692E4015BefB05A03a94A40f520d1c0)
        );

        underlierUSDC.approve(trancheUSDC_V4_yvUSDC_16SEP22, type(uint256).max);
        ITranche(trancheUSDC_V4_yvUSDC_16SEP22).deposit(1000 * ONE_USDC, me);

        address instance_yvUSDC_16SEP22 = vaultFactory.createVault(
            address(impl2),
            abi.encode(address(trancheUSDC_V4_yvUSDC_16SEP22), address(collybus), ccp_yvUSDC_16SEP22)
        );
        vault_yvUSDC_16SEP22 = VaultEPT(instance_yvUSDC_16SEP22);
        codex.setParam(instance_yvUSDC_16SEP22, "debtCeiling", uint256(1000 ether));
        codex.allowCaller(codex.modifyBalance.selector, instance_yvUSDC_16SEP22);
        codex.init(instance_yvUSDC_16SEP22);

        publican.init(instance_yvUSDC_16SEP22);
        publican.setParam(instance_yvUSDC_16SEP22, "interestPerSecond", WAD);
        flash.setParam("max", 1000000 * WAD);

        // approve token and underlier for proxy
        underlierUSDC.approve(address(userProxy), type(uint256).max);
        IERC20(trancheUSDC_V4_yvUSDC_16SEP22).approve(address(userProxy), type(uint256).max);
    }

    function test_buyCollateralAndIncreaseLever_simple() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 500 * ONE_USDC;
        uint256 totalUnderlier = 1000 * ONE_USDC;

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(underlierUSDC), totalUnderlier - upfrontUnderlier - ONE_USDC), // borrowed underliers - fees
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0) // swap all for pTokens
        );

        assertGe(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), 1000 * WAD);
        assertGe(_normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy)), 500 * WAD);
    }

    function test_buyCollateralAndIncreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(vault_yvUSDC_16SEP22),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            totalUnderlier
        );

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(underlierUSDC), totalUnderlier - upfrontUnderlier - ONE_USDC), // borrowed underliers - fees
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0) // swap all for pTokens
        );

        assertEq(underlierUSDC.balanceOf(me), meInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)),
            vaultInitialBalance + (estDeltaCollateral - ONE_USDC) // subtract fees
        );
        assertGe(
            _collateral(address(vault_yvUSDC_16SEP22), address(userProxy)),
            initialCollateral + wdiv(estDeltaCollateral, ONE_USDC) - WAD // subtract fees
        );
    }

    function test_buyCollateralAndIncreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        underlierUSDC.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = underlierUSDC.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(vault_yvUSDC_16SEP22),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            totalUnderlier
        );

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(underlierUSDC), totalUnderlier - upfrontUnderlier - ONE_USDC), // borrowed underliers - fees
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0) // swap all for pTokens
        );

        assertEq(underlierUSDC.balanceOf(address(user)), userInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)),
            vaultInitialBalance + (estDeltaCollateral - ONE_USDC) // subtract fees
        );
        assertGe(
            _collateral(address(vault_yvUSDC_16SEP22), address(userProxy)),
            initialCollateral + wdiv(estDeltaCollateral, ONE_USDC) - WAD // subtract fees
        );
    }

    function test_buyCollateralAndIncreaseLever_for_zero_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        underlierUSDC.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(vault_yvUSDC_16SEP22),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            totalUnderlier
        );

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(underlierUSDC), totalUnderlier - upfrontUnderlier - ONE_USDC), // borrowed underliers - fees
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0) // swap all for pTokens
        );

        assertEq(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)),
            vaultInitialBalance + (estDeltaCollateral - ONE_USDC)
        );
        assertGe(
            _collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), // subtract fees
            initialCollateral + wdiv(estDeltaCollateral, ONE_USDC) - WAD // subtract fees
        );
    }

    function test_buyCollateralAndIncreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        underlierUSDC.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(vault_yvUSDC_16SEP22),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            totalUnderlier
        );

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(underlierUSDC), totalUnderlier - upfrontUnderlier - ONE_USDC), // borrowed underliers - fees
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0) // swap all for pTokens
        );

        assertEq(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)),
            vaultInitialBalance + (estDeltaCollateral - ONE_USDC)
        );
        assertGe(
            _collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), // subtract fees
            initialCollateral + wdiv(estDeltaCollateral, ONE_USDC) - WAD // subtract fees
        );
    }

    function test_sellCollateralAndDecreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(underlierUSDC), totalUnderlier - upfrontUnderlier - ONE_USDC),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        _sellCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            me,
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(underlierUSDC), ((normalDebt * ONE_USDC) / WAD) + ONE_USDC),
            _getCollateralSwapParams(trancheUSDC_V4_yvUSDC_16SEP22, address(underlierUSDC), 0)
        );

        assertGt(underlierUSDC.balanceOf(me), meInitialBalance - ONE_USDC); // subtract fees / rounding errors
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        underlierUSDC.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = underlierUSDC.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(underlierUSDC), totalUnderlier - upfrontUnderlier - ONE_USDC),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        _sellCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(user),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(underlierUSDC), ((normalDebt * ONE_USDC) / WAD) + ONE_USDC),
            _getCollateralSwapParams(trancheUSDC_V4_yvUSDC_16SEP22, address(underlierUSDC), 0)
        );

        assertGt(underlierUSDC.balanceOf(address(user)), userInitialBalance - ONE_USDC); // subtract fees / rounding errors
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_zero_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        underlierUSDC.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(underlierUSDC), totalUnderlier - upfrontUnderlier - ONE_USDC),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        _sellCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(0),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(underlierUSDC), ((normalDebt * ONE_USDC) / WAD) + ONE_USDC),
            _getCollateralSwapParams(trancheUSDC_V4_yvUSDC_16SEP22, address(underlierUSDC), 0)
        );

        assertGt(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance - ONE_USDC); // subtract fees / rounding errors
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        underlierUSDC.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(underlierUSDC), totalUnderlier - upfrontUnderlier - ONE_USDC),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        _sellCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(userProxy),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(underlierUSDC), ((normalDebt * ONE_USDC) / WAD) + ONE_USDC),
            _getCollateralSwapParams(trancheUSDC_V4_yvUSDC_16SEP22, address(underlierUSDC), 0)
        );

        assertGt(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance - ONE_USDC); // subtract fees / rounding errors
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(underlierUSDC), totalUnderlier - upfrontUnderlier - ONE_USDC),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertLt(underlierUSDC.balanceOf(me), meInitialBalance);
        assertGt(IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertGt(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        vm.warp(vault_yvUSDC_16SEP22.maturity(0));

        _redeemCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            vault_yvUSDC_16SEP22.token(),
            me,
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(underlierUSDC), ((normalDebt * ONE_USDC) / WAD) + ONE_USDC)
        );

        assertGt(underlierUSDC.balanceOf(me), meInitialBalance);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        underlierUSDC.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = underlierUSDC.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(underlierUSDC), totalUnderlier - upfrontUnderlier - ONE_USDC),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertLt(underlierUSDC.balanceOf(address(user)), userInitialBalance);
        assertGt(IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertGt(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        vm.warp(vault_yvUSDC_16SEP22.maturity(0));

        _redeemCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            vault_yvUSDC_16SEP22.token(),
            address(user),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(underlierUSDC), ((normalDebt * ONE_USDC) / WAD) + ONE_USDC)
        );

        assertGt(underlierUSDC.balanceOf(address(user)), userInitialBalance);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_zero_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        underlierUSDC.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(underlierUSDC), totalUnderlier - upfrontUnderlier - ONE_USDC),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertLt(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertGt(IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertGt(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        vm.warp(vault_yvUSDC_16SEP22.maturity(0));

        _redeemCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            vault_yvUSDC_16SEP22.token(),
            address(0),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(underlierUSDC), ((normalDebt * ONE_USDC) / WAD) + ONE_USDC)
        );

        assertGt(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        underlierUSDC.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(underlierUSDC), totalUnderlier - upfrontUnderlier - ONE_USDC),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertLt(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertGt(IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertGt(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        vm.warp(vault_yvUSDC_16SEP22.maturity(0));

        _redeemCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            vault_yvUSDC_16SEP22.token(),
            address(userProxy),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(underlierUSDC), ((normalDebt * ONE_USDC) / WAD) + ONE_USDC)
        );

        assertGt(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }
}
