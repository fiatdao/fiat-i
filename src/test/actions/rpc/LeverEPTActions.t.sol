// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";
import {stdStorage,StdStorage} from "forge-std/StdStorage.sol";

import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Codex} from "../../../core/Codex.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {Publican} from "../../../core/Publican.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {Flash} from "../../../core/Flash.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {toInt256, WAD, wdiv, wmul} from "../../../core/utils/Math.sol";

import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {VaultEPT} from "../../../vaults/VaultEPT.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";

import {Caller} from "../../../test/utils/Caller.sol";

import {VaultEPTActions} from "../../../actions/vault/VaultEPTActions.sol";
import {LeverEPTActions} from "../../../actions/lever/LeverEPTActions.sol";
import {IBalancerVault, IAsset} from "../../../actions/helper/ConvergentCurvePoolHelper.sol";

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
    using stdStorage for StdStorage;

    Codex internal codex;
    Publican internal publican;
    Collybus internal collybus;
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
    bytes32 internal bbausdPoolId = 0x06df3b2bbb68adc8b0e302443692037ed9f91b42000000000000000000000063;
    address internal fiatBalancerVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    IERC20 internal dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address internal me = address(this);
    uint256 internal ONE_USDC = 1e6;

    // Batch swaps
    IBalancerVault.BatchSwapStep[] internal swaps;
    IAsset[] internal assets;
    int256[] internal limits;

    bytes32[] pathPoolIds;
    address[] pathAssetsIn;
    address[] pathAssetsOut;

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

    function _getSwapParams(
        address assetIn,
        address assetOut,
        uint256 minOutput,
        uint256 assetInAmount
    ) internal view returns (VaultEPTActions.SwapParams memory swapParams) {
        swapParams.balancerVault = ICCP(ccp_yvUSDC_16SEP22).getVault();
        swapParams.poolId = ICCP(ccp_yvUSDC_16SEP22).getPoolId();
        swapParams.assetIn = assetIn;
        swapParams.assetOut = assetOut;
        swapParams.minOutput = minOutput;
        swapParams.deadline = block.timestamp + 12 weeks;
        swapParams.approve = assetInAmount;
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

    function _getSellFIATSwapParams(
        IBalancerVault.BatchSwapStep[] memory _swaps,
        IAsset[] memory _assets,
        int256[] memory _limits
    ) internal view returns (LeverEPTActions.SellFIATSwapParams memory fiatSwapParams) {
        fiatSwapParams.swaps = _swaps;
        fiatSwapParams.assets = _assets;
        fiatSwapParams.limits = _limits;
        fiatSwapParams.deadline = block.timestamp + 12 weeks;
    }

    function _getBuyFIATSwapParams(
        IBalancerVault.BatchSwapStep[] memory _swaps,
        IAsset[] memory _assets,
        int256[] memory _limits
    ) internal view returns (LeverEPTActions.BuyFIATSwapParams memory fiatSwapParams) {
        fiatSwapParams.swaps = _swaps;
        fiatSwapParams.assets = _assets;
        fiatSwapParams.limits = _limits;
        fiatSwapParams.deadline = block.timestamp + 12 weeks;
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 15100000);

        user = new Caller();
        vaultFactory = new VaultFactory();
        codex = new Codex();
        collybus = new Collybus();
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

        collybus.setParam(instance_yvUSDC_16SEP22, "liquidationRatio",1 ether);
        collybus.updateSpot(address(underlierUSDC), WAD);

        // approve token and underlier for proxy
        underlierUSDC.approve(address(userProxy), type(uint256).max);
        IERC20(trancheUSDC_V4_yvUSDC_16SEP22).approve(address(userProxy), type(uint256).max);
    }

    function test_buyCollateralAndIncreaseLever_simple() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 500 * ONE_USDC;
        uint256 totalUnderlier = 1000 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;

        // Prepare sell FIAT params
        // steps: [FIAT -> DAI, DAI -> USDC]
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);
        IBalancerVault.BatchSwapStep memory step2 = IBalancerVault.BatchSwapStep(fiatPoolId, 1, 2, 0, new bytes(0));
        swaps.push(step2);

        // assets: [FIAT, DAI, USDC]
        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));
        assets.push(IAsset(address(underlierUSDC)));

        // limits: [lendFIAT, 0, -totalUnderlier + upfrontUnderlier + fee]
        limits.push(int256(lendFIAT));
        limits.push(0);
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee));

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0) // swap all for pTokens
        );

        assertGe(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), 1000 * WAD);
        assertGe(_normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy)), 500 * WAD);
    }

    function test_buyCollateralAndIncreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(vault_yvUSDC_16SEP22),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            totalUnderlier
        );

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(underlierUSDC)));

        limits.push(int256(lendFIAT)); // max FIAT in
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee)); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
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
        uint256 fee = 5 * ONE_USDC;
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

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(underlierUSDC)));

        limits.push(int256(lendFIAT)); // max FIAT in
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee)); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
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
        uint256 fee = 5 * ONE_USDC;

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

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(underlierUSDC)));

        limits.push(int256(lendFIAT)); // max FIAT in
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee)); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
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
        uint256 fee = 5 * ONE_USDC;

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

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(underlierUSDC)));

        limits.push(int256(lendFIAT)); // max FIAT in
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee)); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
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
        uint256 fee = 5 * ONE_USDC;

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(underlierUSDC)));

        limits.push(int256(lendFIAT)); // max FIAT in
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee)); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        delete swaps;
        delete assets;
        delete limits;

        // Prepare buy FIAT params
        pathAssetsIn.push(address(underlierUSDC));
        pathAssetsIn.push(address(dai));

        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);

        uint maxUnderliersIn = totalUnderlier - upfrontUnderlier + fee; // max USDC In
        uint deadline = block.timestamp + 10 days;

        _sellCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            me,
            pTokenAmount,
            normalDebt,
            leverActions.buildBuyFIATSwapParams(pathPoolIds, pathAssetsIn, maxUnderliersIn, deadline),
            _getCollateralSwapParams(trancheUSDC_V4_yvUSDC_16SEP22, address(underlierUSDC), 0)
        );

        assertGt(underlierUSDC.balanceOf(me), meInitialBalance - 2 * ONE_USDC); // subtract fees / rounding errors
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        underlierUSDC.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = underlierUSDC.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(underlierUSDC)));

        limits.push(int256(lendFIAT)); // max FIAT in
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee)); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        delete swaps;
        delete assets;
        delete limits;

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(underlierUSDC)));
        assets.push(IAsset(address(fiat)));

        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max USDC In
        limits.push(-int(lendFIAT)); // limit set as exact amount out in the contract actions

        _sellCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(user),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(trancheUSDC_V4_yvUSDC_16SEP22, address(underlierUSDC), 0)
        );

        // subtract fees / rounding errors
        assertGt(underlierUSDC.balanceOf(address(user)), userInitialBalance - ONE_USDC);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_update_rate_and_sellCollateralAndDecreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        underlierUSDC.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = underlierUSDC.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(underlierUSDC)));

        limits.push(int256(lendFIAT)); // max FIAT in
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee)); // min USDC out after fees

        publican.setParam(address(vault_yvUSDC_16SEP22), "interestPerSecond", 1.000000000700000 ether);
        publican.collect(address(vault_yvUSDC_16SEP22));

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        delete swaps;
        delete assets;
        delete limits;

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(underlierUSDC)));
        assets.push(IAsset(address(fiat)));

        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max USDC In
        limits.push(-int(lendFIAT)); // limit set as exact amount out in the contract actions
         
        // Move some time
        vm.warp(block.timestamp + 50 days);

        publican.collect(address(vault_yvUSDC_16SEP22));
        codex.createUnbackedDebt(address(moneta), address(moneta), 2 *WAD);

        _sellCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(user),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(trancheUSDC_V4_yvUSDC_16SEP22, address(underlierUSDC), 0)
        );

        // subtract fees / rounding errors
        assertGt(underlierUSDC.balanceOf(address(user)), userInitialBalance - ONE_USDC);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_zero_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        underlierUSDC.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(underlierUSDC)));

        limits.push(int256(lendFIAT)); // max FIAT in
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee)); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        delete swaps;
        delete assets;
        delete limits;
        
        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(underlierUSDC)));
        assets.push(IAsset(address(fiat)));

        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max USDC In
        limits.push(-int(lendFIAT)); // limit set as exact amount out in the contract actions

        _sellCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(0),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(trancheUSDC_V4_yvUSDC_16SEP22, address(underlierUSDC), 0)
        );

        // subtract fees / rounding errors
        assertGt(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance - ONE_USDC);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        underlierUSDC.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(underlierUSDC)));

        limits.push(int256(lendFIAT)); // max FIAT in
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee)); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        delete swaps;
        delete assets;
        delete limits;

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(underlierUSDC)));
        assets.push(IAsset(address(fiat)));

        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max USDC In
        limits.push(-int(lendFIAT)); // limit set as exact amount out in the contract actions

        _sellCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(userProxy),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(trancheUSDC_V4_yvUSDC_16SEP22, address(underlierUSDC), 0)
        );

        // subtract fees / rounding errors
        assertGt(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance - ONE_USDC);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(underlierUSDC)));

        limits.push(int256(lendFIAT)); // max FIAT in
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee)); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertLt(underlierUSDC.balanceOf(me), meInitialBalance);
        assertGt(IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertGt(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        vm.warp(vault_yvUSDC_16SEP22.maturity(0));
        
        delete swaps;
        delete assets;
        delete limits;

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(underlierUSDC)));
        assets.push(IAsset(address(fiat)));

        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max USDC In
        limits.push(-int(lendFIAT)); // limit set as exact amount out in the contract actions

        _redeemCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            vault_yvUSDC_16SEP22.token(),
            me,
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(underlierUSDC.balanceOf(me), meInitialBalance);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        underlierUSDC.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = underlierUSDC.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(underlierUSDC)));

        limits.push(int256(lendFIAT)); // max FIAT in
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee)); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertLt(underlierUSDC.balanceOf(address(user)), userInitialBalance);
        assertGt(IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertGt(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        vm.warp(vault_yvUSDC_16SEP22.maturity(0));

        delete swaps;
        delete assets;
        delete limits;

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(underlierUSDC)));
        assets.push(IAsset(address(fiat)));

        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max USDC In
        limits.push(-int(lendFIAT)); // limit set as exact amount out in the contract actions

        _redeemCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            vault_yvUSDC_16SEP22.token(),
            address(user),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(underlierUSDC.balanceOf(address(user)), userInitialBalance);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_zero_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        underlierUSDC.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(underlierUSDC)));

        limits.push(int256(lendFIAT)); // max FIAT in
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee)); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertLt(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertGt(IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertGt(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        vm.warp(vault_yvUSDC_16SEP22.maturity(0));

        delete swaps;
        delete assets;
        delete limits;

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(underlierUSDC)));
        assets.push(IAsset(address(fiat)));

        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max USDC In
        limits.push(-int(lendFIAT)); // limit set as exact amount out in the contract actions

        _redeemCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            vault_yvUSDC_16SEP22.token(),
            address(0),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5* ONE_USDC;
        underlierUSDC.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = underlierUSDC.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(underlierUSDC)));

        limits.push(int256(lendFIAT)); // max FIAT in
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee)); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertLt(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertGt(IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertGt(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        vm.warp(vault_yvUSDC_16SEP22.maturity(0));

        delete swaps;
        delete assets;
        delete limits;

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(underlierUSDC)));
        assets.push(IAsset(address(fiat)));

        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max USDC In
        limits.push(-int(lendFIAT)); // limit set as exact amount out in the contract actions

        _redeemCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            vault_yvUSDC_16SEP22.token(),
            address(userProxy),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(underlierUSDC.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_update_rate_and_redeemCollateralAndDecreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;

        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(underlierUSDC)));

        limits.push(int256(lendFIAT)); // max FIAT in
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee)); // min USDC out after fees
        
        publican.setParam(address(vault_yvUSDC_16SEP22), "interestPerSecond", 1.000000000700000 ether);
        publican.collect(address(vault_yvUSDC_16SEP22));
        
        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertLt(underlierUSDC.balanceOf(me), meInitialBalance);
        assertGt(IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertGt(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = (_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy));

        vm.warp(vault_yvUSDC_16SEP22.maturity(0));

        publican.collect(address(vault_yvUSDC_16SEP22));
        codex.createUnbackedDebt(address(moneta), address(moneta), 3 *WAD);
        
        delete swaps;
        delete assets;
        delete limits;

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(underlierUSDC)));
        assets.push(IAsset(address(fiat)));

        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max USDC In
        limits.push(-int(lendFIAT)); // limit set as exact amount out in the contract actions

        _redeemCollateralAndDecreaseLever(
            address(vault_yvUSDC_16SEP22),
            vault_yvUSDC_16SEP22.token(),
            me,
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(underlierUSDC.balanceOf(me), meInitialBalance);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)), vaultInitialBalance);
        assertEq(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), initialCollateral);
    }

    function test_underlierToFIAT_18decimals_underlier() public {
        uint256 underlierIn = 500 * WAD;

        // Prepare arguments for preview method
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);

        pathAssetsIn.push(address(dai));
        pathAssetsIn.push(address(underlierUSDC));
        
        uint fiatOut = leverActions.underlierToFIAT(pathPoolIds, pathAssetsIn, underlierIn);
    
        assertApproxEqAbs(underlierIn, fiatOut, 1 ether); 
    }

    function test_underlierToFIAT_6_decimals_underlier() public {
        uint256 underlierIn = 500 * ONE_USDC;

        // Prepare arguments for preview method
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);

        pathAssetsIn.push(address(underlierUSDC));
        pathAssetsIn.push(address(dai));
        
        uint fiatOut = leverActions.underlierToFIAT(pathPoolIds, pathAssetsIn, underlierIn);

        assertApproxEqAbs(underlierIn, wmul(fiatOut,vault_yvUSDC_16SEP22.underlierScale()), 1 * ONE_USDC); 
        assertApproxEqAbs(fiatOut, wdiv(underlierIn,vault_yvUSDC_16SEP22.underlierScale()), 1 ether); 
    }

    function testFail_buyCollateralAndIncreaseLever_with_ZERO_upfrontUnderlier_without_a_position() public {
        stdstore
            .target(address(collybus))
            .sig("vaults(address)")
            .with_key(address(vault_yvUSDC_16SEP22))
            .depth(0)
            .checked_write(1.01 ether);

        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 0 * ONE_USDC;
        uint256 totalUnderlier = 500 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;

        // Prepare sell FIAT params
        // steps: [FIAT -> DAI, DAI -> USDC]
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);
        IBalancerVault.BatchSwapStep memory step2 = IBalancerVault.BatchSwapStep(fiatPoolId, 1, 2, 0, new bytes(0));
        swaps.push(step2);

        // assets: [FIAT, DAI, USDC]
        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));
        assets.push(IAsset(address(underlierUSDC)));

        // limits: [lendFIAT, 0, -totalUnderlier + upfrontUnderlier + fee]
        limits.push(int256(lendFIAT));
        limits.push(0);
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee));

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0) // swap all for pTokens
        );

        assertGe(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), 500 * WAD);
        assertGe(_normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy)), 500 * WAD);
    }

    function test_buyCollateralAndIncreaseLever_with_ZERO_upfrontUnderlier_with_a_position() public {
        uint256 amount = 100 * ONE_USDC;
        uint256 meInitialBalance = underlierUSDC.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22));
        uint256 initialCollateral = _collateral(address(vault_yvUSDC_16SEP22), address(userProxy));

        uint256 price = vaultActions.underlierToPToken(
            address(vault_yvUSDC_16SEP22),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            vault_yvUSDC_16SEP22.underlierScale()
        );

        // Open position
        _buyCollateralAndModifyDebt(
            address(vault_yvUSDC_16SEP22),
            me,
            address(0),
            amount,
            0,
            _getSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0, amount)
        );

        assertEq(underlierUSDC.balanceOf(me), meInitialBalance - amount);
        assertTrue(
            ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(vault_yvUSDC_16SEP22)) >=
                vaultInitialBalance + ((amount * price) / ONE_USDC)
        );
        assertTrue(
            _collateral(address(vault_yvUSDC_16SEP22), address(userProxy)) >=
                initialCollateral + wdiv(amount, 10**IERC20Metadata(trancheUSDC_V4_yvUSDC_16SEP22).decimals())
        );

        // Update liquidationRatio from 1 ether (WAD) to 1.01 ether
        stdstore
            .target(address(collybus))
            .sig("vaults(address)")
            .with_key(address(vault_yvUSDC_16SEP22))
            .depth(0)
            .checked_write(1.01 ether);

        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 0 * ONE_USDC;
        uint256 totalUnderlier = 500 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;

        // Prepare sell FIAT params
        // steps: [FIAT -> DAI, DAI -> USDC]
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);
        IBalancerVault.BatchSwapStep memory step2 = IBalancerVault.BatchSwapStep(fiatPoolId, 1, 2, 0, new bytes(0));
        swaps.push(step2);

        // assets: [FIAT, DAI, USDC]
        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));
        assets.push(IAsset(address(underlierUSDC)));

        // limits: [lendFIAT, 0, -totalUnderlier + upfrontUnderlier + fee]
        limits.push(int256(lendFIAT));
        limits.push(0);
        limits.push(-int256(totalUnderlier - upfrontUnderlier - fee));

        _buyCollateralAndIncreaseLever(
            address(vault_yvUSDC_16SEP22),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(underlierUSDC), trancheUSDC_V4_yvUSDC_16SEP22, 0) // swap all for pTokens
        );

        assertGe(_collateral(address(vault_yvUSDC_16SEP22), address(userProxy)), 500 * WAD);
        assertGe(_normalDebt(address(vault_yvUSDC_16SEP22), address(userProxy)), 500 * WAD);
    }

    function test_fiatForUnderlier() public {
        uint256 fiatOut = 500 * WAD;

        // prepare arguments for preview method, ordered from underlier to FIAT
        pathPoolIds.push(bbausdPoolId);
        pathPoolIds.push(fiatPoolId);
        
        pathAssetsIn.push(address(underlierUSDC));
        pathAssetsIn.push(address(dai));
        
        uint underlierIn = leverActions.fiatForUnderlier(pathPoolIds, pathAssetsIn, fiatOut);
        assertApproxEqAbs(underlierIn, wmul(fiatOut,vault_yvUSDC_16SEP22.tokenScale()), 2 * ONE_USDC);     

        uint fiatIn = fiatOut;

        // prepare arguments for preview method, ordered from FIAT to underlier
        delete pathPoolIds;
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(bbausdPoolId);

        pathAssetsOut.push(address(dai));
        pathAssetsOut.push(address(underlierUSDC));
        
        assertApproxEqAbs(underlierIn, leverActions.fiatToUnderlier(pathPoolIds, pathAssetsOut, fiatIn), 2 * ONE_USDC);
    }

    function test_fiatToUnderlier() public {
        uint256 fiatIn = 500 * WAD;
        
        // prepare arguments for preview method, ordered from FIAT to underlier
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(bbausdPoolId);

        pathAssetsOut.push(address(dai));
        pathAssetsOut.push(address(underlierUSDC));

        uint underlierOut = leverActions.fiatToUnderlier(pathPoolIds, pathAssetsOut, fiatIn);
        assertApproxEqAbs(underlierOut, wmul(fiatIn,vault_yvUSDC_16SEP22.tokenScale()), 2 * ONE_USDC);

        uint256 fiatOut = fiatIn;

        // prepare arguments for preview method, ordered from underlier to FIAT
        delete pathPoolIds;
        pathPoolIds.push(bbausdPoolId);
        pathPoolIds.push(fiatPoolId);
        
        pathAssetsIn.push(address(underlierUSDC));
        pathAssetsIn.push(address(dai));
        
        assertApproxEqAbs(underlierOut, leverActions.fiatForUnderlier(pathPoolIds, pathAssetsIn, fiatOut), 2 * ONE_USDC);
    }
}
