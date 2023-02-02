// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";
import {stdStorage,StdStorage} from "forge-std/StdStorage.sol";

import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {Codex} from "../../../core/Codex.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {Publican} from "../../../core/Publican.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {Flash} from "../../../core/Flash.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {toInt256, WAD, wdiv, wmul} from "../../../core/utils/Math.sol";


import {VaultEPT} from "../../../vaults/VaultEPT.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";
import {IVault} from "../../../interfaces/IVault.sol";

import {VaultEPTActions} from "../../../actions/vault/VaultEPTActions.sol";
import {LeverEPTActions} from "../../../actions/lever/LeverEPTActions.sol";

import {Caller} from "../../../test/utils/Caller.sol";
import {IBalancerVault, IAsset} from "../../../actions/helper/ConvergentCurvePoolHelper.sol";

interface ITranche {
    function balanceOf(address owner) external view returns (uint256);
    function deposit(uint256 shares, address destination) external returns (uint256, uint256);
}

interface ITrancheFactory {
    function deployTranche(uint256 expiration, address wpAddress) external returns (address);
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
    
    VaultFactory internal vaultFactory;
    LeverEPTActions internal leverActions;
    VaultEPTActions internal vaultActions;

    IVault internal yvUSDCVault_3Months;
    IVault internal yvUSDCVault_16SEP;

    Caller internal user;
    address internal me = address(this);

    // Underliers
    IERC20 internal usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 internal dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address internal weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Element Finance contracts
    ITrancheFactory internal trancheFactory = ITrancheFactory(0x62F161BF3692E4015BefB05A03a94A40f520d1c0);
    address internal wrappedPositionYUSDC = address(0x57A170cEC0c9Daa701d918d60809080C4Ba3C570);
    address internal trancheUSDC_V4_yvUSDC_16SEP22 = address(0xCFe60a1535ecc5B0bc628dC97111C8bb01637911);
    address internal ccp_yvUSDC_16SEP22 = address(0x56df5ef1A0A86c2A5Dd9cC001Aa8152545BDbdeC);

    // Tranche deployed and used in the tests
    address internal trancheUSDC_V4_3Months;

    // Balancer contracts
    bytes32 internal fiatPoolId = 0x178e029173417b1f9c8bc16dcec6f697bc32374600000000000000000000025d;
    bytes32 internal bbausdPoolId = 0x06df3b2bbb68adc8b0e302443692037ed9f91b42000000000000000000000063;
    bytes32 internal usdcWethPoolId = 0x96646936b91d6b9d7d0c47c496afbf3d6ec7b6f8000200000000000000000019;
    address internal fiatBalancerVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    
    uint256 internal ONE_USDC = 1e6;

    function _collateral(address vault, address user_) internal view returns (uint256) {
        (uint256 collateral, ) = codex.positions(vault, 0, user_);
        return collateral;
    }

    function _normalDebt(address vault, address user_) internal view returns (uint256) {
        (, uint256 normalDebt) = codex.positions(vault, 0, user_);
        return normalDebt;
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
        IBalancerVault.BatchSwapStep[] memory swaps, IAsset[] memory assets, int256[] memory limits
    ) 
        internal 
        view 
        returns (LeverEPTActions.SellFIATSwapParams memory fiatSwapParams) 
    {
        fiatSwapParams.swaps = swaps;
        fiatSwapParams.assets = assets;
        fiatSwapParams.limits = limits;
        fiatSwapParams.deadline = block.timestamp + 12 weeks;
    }

    function _getBuyFIATSwapParams(
        IBalancerVault.BatchSwapStep[] memory swaps, IAsset[] memory assets, int256[] memory limits
    ) 
        internal 
        view 
        returns (LeverEPTActions.BuyFIATSwapParams memory fiatSwapParams) 
    {
        fiatSwapParams.swaps = swaps;
        fiatSwapParams.assets = assets;
        fiatSwapParams.limits = limits;
        fiatSwapParams.deadline = block.timestamp + 12 weeks;
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 15100000);

        user = new Caller();
        vaultFactory = new VaultFactory();
        fiat = FIAT(0x586Aa273F262909EEF8fA02d90Ab65F5015e0516); // use the deployed instance of FIAT on mainnet
        vm.startPrank(0xa55E0d3d697C4692e9C37bC3a7062b1bECeEF45B);
        fiat.allowCaller(fiat.ANY_SIG(), address(this));
        vm.stopPrank();
        codex = new Codex();
        publican = new Publican(address(codex));
        moneta = new Moneta(address(codex), address(fiat));
        prbProxyFactory = new PRBProxyFactory();
        collybus = new Collybus();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));
        codex.setParam("globalDebtCeiling", uint256(10000 ether));
        codex.allowCaller(keccak256("ANY_SIG"), address(publican));

        // get test USDC
        deal(address(usdc), address(user), 10000 * ONE_USDC);
        deal(address(usdc), me, 10000 * ONE_USDC);

        // setup the 3 month tranche
        trancheUSDC_V4_3Months = trancheFactory.deployTranche(block.timestamp + 12 weeks, wrappedPositionYUSDC);
        usdc.approve(trancheUSDC_V4_3Months, type(uint256).max);
        ITranche(trancheUSDC_V4_3Months).deposit(1000 * ONE_USDC, me);

        // setup 16 SEP tranche 
        usdc.approve(trancheUSDC_V4_yvUSDC_16SEP22, type(uint256).max);
        ITranche(trancheUSDC_V4_yvUSDC_16SEP22).deposit(1000 * ONE_USDC, me);
        
        // deploy the yvUSDC 3Months vault
        yvUSDCVault_3Months = IVault(
            vaultFactory.createVault(
                address(new VaultEPT(address(codex), wrappedPositionYUSDC, address(0x62F161BF3692E4015BefB05A03a94A40f520d1c0))),
                abi.encode(trancheUSDC_V4_3Months, address(collybus))
            )
        );

        // initialize the yvUSDC 3Months vault
        codex.allowCaller(codex.modifyBalance.selector, address(yvUSDCVault_3Months));
        codex.init(address(yvUSDCVault_3Months));
        codex.setParam(address(yvUSDCVault_3Months), "debtCeiling", uint256(10000 ether));
        publican.init(address(yvUSDCVault_3Months));
        publican.setParam(address(yvUSDCVault_3Months), "interestPerSecond", WAD);

        // deploy the yvUSDC 16SEP22 vault
        yvUSDCVault_16SEP = IVault(
            vaultFactory.createVault(
                address(new VaultEPT(address(codex), wrappedPositionYUSDC, address(0x62F161BF3692E4015BefB05A03a94A40f520d1c0))),
                abi.encode(address(trancheUSDC_V4_yvUSDC_16SEP22), address(collybus), ccp_yvUSDC_16SEP22)
            )
        );

        // initialize the yvUSDC 16SEPT vault
        codex.allowCaller(codex.modifyBalance.selector, address(yvUSDCVault_16SEP));
        codex.init(address(yvUSDCVault_16SEP));
        codex.setParam(address(yvUSDCVault_16SEP), "debtCeiling", uint256(1000 ether));
        publican.init(address(yvUSDCVault_16SEP));
        publican.setParam(address(yvUSDCVault_16SEP), "interestPerSecond", WAD);
        collybus.setParam(address(yvUSDCVault_16SEP), "liquidationRatio", 1 ether);
        collybus.updateSpot(address(usdc), WAD);

        // set up flashlending facility
        flash = new Flash(address(moneta));
        fiat.allowCaller(fiat.mint.selector, address(moneta));
        flash.setParam("max", 1000000 * WAD);
        codex.allowCaller(keccak256("ANY_SIG"), address(flash));

        // user proxy setup - allow UserProxy to spend tokens on behalf of address(this) and the user's EOA
        fiat.approve(address(userProxy), type(uint256).max);
        usdc.approve(address(userProxy), type(uint256).max);
        IERC20(trancheUSDC_V4_3Months).approve(address(userProxy), type(uint256).max);
        IERC20(trancheUSDC_V4_yvUSDC_16SEP22).approve(address(userProxy), type(uint256).max);
        user.externalCall(
            trancheUSDC_V4_3Months,
            abi.encodeWithSelector(IERC20.approve.selector, address(userProxy), type(uint256).max)
        );
        user.externalCall(
            address(fiat),
            abi.encodeWithSelector(fiat.approve.selector, address(userProxy), type(uint256).max)
        );
        user.externalCall(
            address(usdc),
            abi.encodeWithSelector(usdc.approve.selector, address(userProxy), type(uint256).max)
        );

        // vault and lever actions setup        
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
        userProxy.execute(
            address(leverActions),
            abi.encodeWithSelector(leverActions.approveFIAT.selector, address(moneta), type(uint256).max)
        );
    }

    function test_buyCollateralAndIncreaseLever_buildSellFIATSwapParams() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 500 * ONE_USDC;
        uint256 totalUnderlier = 1000 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;

        // Prepare sell FIAT params
        bytes32[] memory pathPoolIds = new bytes32[](3);
        pathPoolIds[0] = fiatPoolId; // FIAT : USDC pool
        pathPoolIds[1] = usdcWethPoolId; // USDC : WETH pool
        pathPoolIds[2] = usdcWethPoolId; // WETH : USDC pool
        
        address[] memory pathAssetsOut = new address[](3);
        pathAssetsOut[0] = address(usdc); // FIAT to USDC
        pathAssetsOut[1] = address(weth); // USDC to WETH
        pathAssetsOut[2] = address(usdc); // WETH to USDC

        uint256 minUnderliersOut = totalUnderlier - upfrontUnderlier - fee;
        uint256 deadline = block.timestamp + 10 days;

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline),
            // swap all for pTokens
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertGe(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), 1000 * WAD);
        assertGe(_normalDebt(address(yvUSDCVault_16SEP), address(userProxy)), 500 * WAD);
    }

    function test_buyCollateralAndIncreaseLever_buildSellFIATSwapParams_notSafe() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;

        // prepare sell FIAT params
        bytes32[] memory pathPoolIds = new bytes32[](3);
        pathPoolIds[0] = fiatPoolId;
        pathPoolIds[1] = fiatPoolId;
        pathPoolIds[2] = fiatPoolId;

        address[] memory pathAssetsOut = new address[](3);
        pathAssetsOut[0] = address(usdc);
        pathAssetsOut[1] = address(dai);
        pathAssetsOut[2] = address(usdc);
      
        uint256 minUnderliersOut = totalUnderlier - upfrontUnderlier - fee;
        uint256 deadline = block.timestamp + 10 days;

        assertEq(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), 0);
        assertEq(_normalDebt(address(yvUSDCVault_16SEP), address(userProxy)), 0);

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline), 
            // swap all for pTokens
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertGe(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), 500 * WAD);
        assertGe(_normalDebt(address(yvUSDCVault_16SEP), address(userProxy)), 500 * WAD);
    }

    function test_buyCollateralAndIncreaseLever_buildSellFIATSwapParams_no_upfrontUnderlier() public {
        collybus.setParam(address(yvUSDCVault_16SEP), "liquidationRatio", 1.03 ether);
        
        // First we need to open a position
        uint256 amount = 100 * ONE_USDC;
        uint256 meInitialBalance = usdc.balanceOf(address(me));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        assertEq(_collateral(address(yvUSDCVault_16SEP), address(userProxy)),0);
        uint256 previewOut = vaultActions.underlierToPToken(
            address(yvUSDCVault_16SEP),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            yvUSDCVault_16SEP.underlierScale()
        );
        
        _buyCollateralAndModifyDebt(
            address(yvUSDCVault_16SEP),
            me,
            address(0),
            amount,
            0,
            _getSwapParams(
                address(usdc), 
                trancheUSDC_V4_yvUSDC_16SEP22, 
                0, 
                amount
            )
        );

        assertEq(usdc.balanceOf(me), meInitialBalance - amount);
        assertTrue(
            ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)) >= 
            previewOut + vaultInitialBalance
        );
        assertTrue(
            _collateral(address(yvUSDCVault_16SEP), address(userProxy)) >=
                 wdiv(previewOut, 10**IERC20Metadata(address(trancheUSDC_V4_yvUSDC_16SEP22)).decimals())
        );

        uint256 lendFIAT = 1000 * WAD;
        uint256 upfrontUnderlier = 0 * ONE_USDC;
        uint256 totalUnderlier = 1000 * ONE_USDC;
        uint256 fee = 10 * ONE_USDC;

        // prepare sell FIAT params
        bytes32[] memory pathPoolIds = new bytes32[](3);
        pathPoolIds[0] = fiatPoolId;
        pathPoolIds[1] = fiatPoolId;
        pathPoolIds[2] = fiatPoolId;
        
        address[] memory pathAssetsOut = new address[](3);
        pathAssetsOut[0] = address(usdc);
        pathAssetsOut[1] = address(dai);
        pathAssetsOut[2] = address(usdc);

        uint256 minUnderliersOut = totalUnderlier - upfrontUnderlier - fee;
        uint256 deadline = block.timestamp + 10 days;

        assertGt(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), 0);
        assertEq(_normalDebt(address(yvUSDCVault_16SEP), address(userProxy)), 0);

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline), 
            // swap all for pTokens
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertGe(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), 1000 * WAD);
        assertGe(_normalDebt(address(yvUSDCVault_16SEP), address(userProxy)), 1000 * WAD);
    }

    function test_buyCollateralAndIncreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;

        uint256 meInitialBalance = usdc.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        uint256 initialCollateral = _collateral(address(yvUSDCVault_16SEP), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(yvUSDCVault_16SEP),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            totalUnderlier
        );

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // max FIAT in
        limits[1] = -int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            // swap all for pTokens
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertEq(usdc.balanceOf(address(me)), meInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)),
            vaultInitialBalance + (estDeltaCollateral - ONE_USDC)
        );
        assertGe(
            _collateral(address(yvUSDCVault_16SEP), address(userProxy)), // subtract fees
            initialCollateral + wdiv(estDeltaCollateral, ONE_USDC) - WAD // subtract fees
        );
    }

    function test_buyCollateralAndIncreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = usdc.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        uint256 initialCollateral = _collateral(address(yvUSDCVault_16SEP), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(yvUSDCVault_16SEP),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            totalUnderlier
        );

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // max FIAT in
        limits[1] = -int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0) // swap all for pTokens
        );

        assertEq(usdc.balanceOf(address(user)), userInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)),
            vaultInitialBalance + (estDeltaCollateral - ONE_USDC)
        );
        assertGe(
            _collateral(address(yvUSDCVault_16SEP), address(userProxy)), // subtract fees
            initialCollateral + wdiv(estDeltaCollateral, ONE_USDC) - WAD // subtract fees
        );
    }

    function test_buyCollateralAndIncreaseLever_for_address_zero() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        uint256 initialCollateral = _collateral(address(yvUSDCVault_16SEP), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(yvUSDCVault_16SEP),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            totalUnderlier
        );

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // max FIAT in
        limits[1] = -int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            // swap all for pTokens
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertEq(usdc.balanceOf(address(userProxy)), userProxyInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)),
            vaultInitialBalance + (estDeltaCollateral - ONE_USDC)
        );
        assertGe(
            _collateral(address(yvUSDCVault_16SEP), address(userProxy)), // subtract fees
            initialCollateral + wdiv(estDeltaCollateral, ONE_USDC) - WAD // subtract fees
        );
    }

    function test_buyCollateralAndIncreaseLever_for_address_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        uint256 initialCollateral = _collateral(address(yvUSDCVault_16SEP), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(yvUSDCVault_16SEP),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            totalUnderlier
        );

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // max FIAT in
        limits[1] = -int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            // swap all for pTokens
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertEq(usdc.balanceOf(address(userProxy)), userProxyInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)),
            vaultInitialBalance + (estDeltaCollateral - ONE_USDC)
        );
        assertGe(
            _collateral(address(yvUSDCVault_16SEP), address(userProxy)), // subtract fees
            initialCollateral + wdiv(estDeltaCollateral, ONE_USDC) - WAD // subtract fees
        );
    }

    function test_sellCollateralAndDecreaseLever_buildBuyFIATSwapParams() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;

        uint256 meInitialBalance = usdc.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        uint256 initialCollateral = _collateral(address(yvUSDCVault_16SEP), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // max FIAT in
        limits[1] = -int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        assertEq(usdc.balanceOf(address(leverActions)), 0);

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        uint256 pTokenAmount = (_collateral(address(yvUSDCVault_16SEP), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(yvUSDCVault_16SEP), address(userProxy));

        // prepare buy FIAT params
        bytes32[] memory pathPoolIds = new bytes32[](3);
        pathPoolIds[0] = usdcWethPoolId; // USDC : WETH pool
        pathPoolIds[1] = usdcWethPoolId; // WETH : USDC pool
        pathPoolIds[2] = fiatPoolId; // USDC : FIAT pool

        address[] memory pathAssetsIn = new address[](3);
        pathAssetsIn[0] = address(usdc); // USDC to WETH
        pathAssetsIn[1] = address(weth); // WETH to USDC
        pathAssetsIn[2] = address(usdc); // USDC to FIAT

        uint maxUnderliersIn = totalUnderlier - upfrontUnderlier + fee; // max USDC In
        uint deadline = block.timestamp + 10 days;

        _sellCollateralAndDecreaseLever(
            address(yvUSDCVault_16SEP),
            me,
            pTokenAmount,
            normalDebt,
            leverActions.buildBuyFIATSwapParams(pathPoolIds, pathAssetsIn, maxUnderliersIn, deadline),
            _getCollateralSwapParams(trancheUSDC_V4_yvUSDC_16SEP22, address(usdc), 0)
        );

        assertGt(usdc.balanceOf(me), meInitialBalance - 2 * ONE_USDC); // subtract fees / rounding errors
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertEq(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = usdc.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        uint256 initialCollateral = _collateral(address(yvUSDCVault_16SEP), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // max FIAT in
        limits[1] = -int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        uint256 pTokenAmount = (_collateral(address(yvUSDCVault_16SEP), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(yvUSDCVault_16SEP), address(userProxy));

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max usdc In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _sellCollateralAndDecreaseLever(
            address(yvUSDCVault_16SEP),
            address(user),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(trancheUSDC_V4_yvUSDC_16SEP22, address(usdc), 0)
        );

        // subtract fees / rounding errors
        assertGt(usdc.balanceOf(address(user)), userInitialBalance - ONE_USDC);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertEq(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_collect_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = usdc.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        uint256 initialCollateral = _collateral(address(yvUSDCVault_16SEP), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // max FIAT in
        limits[1] = -int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        publican.setParam(address(yvUSDCVault_16SEP), "interestPerSecond", 1.000000000700000 ether);
        publican.collect(address(yvUSDCVault_16SEP));

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        uint256 pTokenAmount = (_collateral(address(yvUSDCVault_16SEP), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(yvUSDCVault_16SEP), address(userProxy));

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out
         
        // Move some time
        vm.warp(block.timestamp + 50 days);

        publican.collect(address(yvUSDCVault_16SEP));
        codex.createUnbackedDebt(address(moneta), address(moneta), 2 *WAD);

        _sellCollateralAndDecreaseLever(
            address(yvUSDCVault_16SEP),
            address(user),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(trancheUSDC_V4_yvUSDC_16SEP22, address(usdc), 0)
        );

        // subtract fees / rounding errors
        assertGt(usdc.balanceOf(address(user)), userInitialBalance - ONE_USDC);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertEq(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_address_zero() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        uint256 initialCollateral = _collateral(address(yvUSDCVault_16SEP), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // max FIAT in
        limits[1] = -int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        uint256 pTokenAmount = (_collateral(address(yvUSDCVault_16SEP), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(yvUSDCVault_16SEP), address(userProxy));

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _sellCollateralAndDecreaseLever(
            address(yvUSDCVault_16SEP),
            address(0),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(trancheUSDC_V4_yvUSDC_16SEP22, address(usdc), 0)
        );

        // subtract fees / rounding errors
        assertGt(usdc.balanceOf(address(userProxy)), userProxyInitialBalance - ONE_USDC);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertEq(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        uint256 initialCollateral = _collateral(address(yvUSDCVault_16SEP), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // max FIAT in
        limits[1] = -int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        uint256 pTokenAmount = (_collateral(address(yvUSDCVault_16SEP), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(yvUSDCVault_16SEP), address(userProxy));

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _sellCollateralAndDecreaseLever(
            address(yvUSDCVault_16SEP),
            address(userProxy),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(trancheUSDC_V4_yvUSDC_16SEP22, address(usdc), 0)
        );

        // subtract fees / rounding errors
        assertGt(usdc.balanceOf(address(userProxy)), userProxyInitialBalance - ONE_USDC);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertEq(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        uint256 meInitialBalance = usdc.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        uint256 initialCollateral = _collateral(address(yvUSDCVault_16SEP), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // max FIAT in
        limits[1] = -int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertLt(usdc.balanceOf(me), meInitialBalance);
        assertGt(IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertGt(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = (_collateral(address(yvUSDCVault_16SEP), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(yvUSDCVault_16SEP), address(userProxy));

        vm.warp(yvUSDCVault_16SEP.maturity(0));
        
        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(yvUSDCVault_16SEP),
            yvUSDCVault_16SEP.token(),
            me,
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(usdc.balanceOf(me), meInitialBalance);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertEq(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = usdc.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        uint256 initialCollateral = _collateral(address(yvUSDCVault_16SEP), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertLt(usdc.balanceOf(address(user)), userInitialBalance);
        assertGt(IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertGt(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = (_collateral(address(yvUSDCVault_16SEP), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(yvUSDCVault_16SEP), address(userProxy));

        vm.warp(yvUSDCVault_16SEP.maturity(0));

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(yvUSDCVault_16SEP),
            yvUSDCVault_16SEP.token(),
            address(user),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(usdc.balanceOf(address(user)), userInitialBalance);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertEq(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_address_zero() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        uint256 initialCollateral = _collateral(address(yvUSDCVault_16SEP), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertLt(usdc.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertGt(IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertGt(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = (_collateral(address(yvUSDCVault_16SEP), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(yvUSDCVault_16SEP), address(userProxy));

        vm.warp(yvUSDCVault_16SEP.maturity(0));

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(yvUSDCVault_16SEP),
            yvUSDCVault_16SEP.token(),
            address(0),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(usdc.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertEq(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5* ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        uint256 initialCollateral = _collateral(address(yvUSDCVault_16SEP), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertLt(usdc.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertGt(IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertGt(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = (_collateral(address(yvUSDCVault_16SEP), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(yvUSDCVault_16SEP), address(userProxy));

        vm.warp(yvUSDCVault_16SEP.maturity(0));

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(yvUSDCVault_16SEP),
            yvUSDCVault_16SEP.token(),
            address(userProxy),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(usdc.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertEq(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_collect() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;

        uint256 meInitialBalance = usdc.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP));
        uint256 initialCollateral = _collateral(address(yvUSDCVault_16SEP), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees
        
        publican.setParam(address(yvUSDCVault_16SEP), "interestPerSecond", 1.000000000700000 ether);
        publican.collect(address(yvUSDCVault_16SEP));
        
        _buyCollateralAndIncreaseLever(
            address(yvUSDCVault_16SEP),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), trancheUSDC_V4_yvUSDC_16SEP22, 0)
        );

        assertLt(usdc.balanceOf(me), meInitialBalance);
        assertGt(IERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertGt(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = (_collateral(address(yvUSDCVault_16SEP), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(yvUSDCVault_16SEP), address(userProxy));

        vm.warp(yvUSDCVault_16SEP.maturity(0));

        publican.collect(address(yvUSDCVault_16SEP));
        codex.createUnbackedDebt(address(moneta), address(moneta), 3 *WAD);
        
        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(yvUSDCVault_16SEP),
            yvUSDCVault_16SEP.token(),
            me,
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(usdc.balanceOf(me), meInitialBalance);
        assertEq(ERC20(trancheUSDC_V4_yvUSDC_16SEP22).balanceOf(address(yvUSDCVault_16SEP)), vaultInitialBalance);
        assertEq(_collateral(address(yvUSDCVault_16SEP), address(userProxy)), initialCollateral);
    }

    function test_underlierToPToken() external {
        uint256 pTokenAmountNow = leverActions.underlierToPToken(
            address(yvUSDCVault_16SEP),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            100 * ONE_USDC
        );
        assertGt(pTokenAmountNow, 0);

        // advance in time
        vm.warp(block.timestamp + 50 days);
        uint256 pTokenAmountBeforeMaturity = leverActions.underlierToPToken(
            address(yvUSDCVault_16SEP),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            100 * ONE_USDC
        );

        // closest to the maturity we expect less pTokens for same underlier amount
        assertGt(pTokenAmountNow, pTokenAmountBeforeMaturity);

        // go to maturity
        uint256 maturity = yvUSDCVault_16SEP.maturity(0);
        vm.warp(maturity);
        uint256 pTokenAmountAtMaturity = leverActions.underlierToPToken(
            address(yvUSDCVault_16SEP),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            100 * ONE_USDC
        );
        // at maturity we expect even less pTokens
        assertGt(pTokenAmountBeforeMaturity, pTokenAmountAtMaturity);

        vm.warp(maturity + 24 days);
        uint256 pTokenAmountAfterMaturity = leverActions.underlierToPToken(
            address(yvUSDCVault_16SEP),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            100 * ONE_USDC
        );
        // same after maturity
        assertEq(pTokenAmountAtMaturity, pTokenAmountAfterMaturity);
        assertGt(pTokenAmountBeforeMaturity, pTokenAmountAfterMaturity);
    }

    function test_pTokenToUnderlier() external {
        uint256 underlierNow = leverActions.pTokenToUnderlier(
            address(yvUSDCVault_16SEP),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            100 * ONE_USDC
        );
        assertGt(underlierNow, 0);

        // advance in time
        vm.warp(block.timestamp + 50 days);
        uint256 underlierBeforeMaturity = leverActions.pTokenToUnderlier(
            address(yvUSDCVault_16SEP),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            100 * ONE_USDC
        );
        // closest to the maturity we expect more underlier for same pTokens
        assertGt(underlierBeforeMaturity, underlierNow);

        // go to maturity
        uint256 maturity = yvUSDCVault_16SEP.maturity(0);
        vm.warp(maturity);

        uint256 underlierAtMaturity = leverActions.pTokenToUnderlier(
            address(yvUSDCVault_16SEP),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            100 * ONE_USDC
        );
        // at maturity we expect even more underlier
        assertGt(underlierAtMaturity, underlierBeforeMaturity);

        // same after maturity
        vm.warp(maturity + 10 days);
        uint256 underlierAfterMaturity = leverActions.pTokenToUnderlier(
            address(yvUSDCVault_16SEP),
            ICCP(ccp_yvUSDC_16SEP22).getVault(),
            ICCP(ccp_yvUSDC_16SEP22).getPoolId(),
            100 * ONE_USDC
        );
        assertEq(underlierAtMaturity, underlierAfterMaturity);
    }

    function test_fiatToUnderlier() public {
        uint256 fiatIn = 500 * WAD;
        
        // prepare arguments for preview method, ordered from FIAT to underlier
        bytes32[] memory pathPoolIds = new bytes32[](3);
        pathPoolIds[0] = fiatPoolId; // FIAT : USDC pool
        pathPoolIds[1] = bbausdPoolId; // USDC : DAI pool
        pathPoolIds[2] = bbausdPoolId; // DAI : USDC pool

        address[] memory pathAssetsOut = new address[](3);
        pathAssetsOut[0] = address(usdc); // FIAT to USDC
        pathAssetsOut[1] = address(dai); // USDC to DAI
        pathAssetsOut[2] = address(usdc); // DAI to USDC

        // scale to WAD precision
        uint256 underlierOut = wdiv(
            leverActions.fiatToUnderlier(pathPoolIds, pathAssetsOut, fiatIn),
            10**IERC20Metadata(address(usdc)).decimals()
        );
        assertApproxEqAbs(underlierOut, fiatIn, 5 * WAD);
        
        // sanity check: underlier amount should be close to the same for the reverse swap
        uint256 fiatOut = fiatIn;

        pathPoolIds[0] = bbausdPoolId; // USDC : USDC pool
        pathPoolIds[1] = bbausdPoolId; // DAI : USDC pool
        pathPoolIds[2] = fiatPoolId; // USDC : FIAT pool

        address[] memory pathAssetsIn = new address[](3);
        pathAssetsIn[0] = address(usdc); // USDC to DAI
        pathAssetsIn[1] = address(dai); // DAI to USDC
        pathAssetsIn[2] = address(usdc); // USDC to FIAT
        
        // scale to WAD precision
        uint256 underlierIn = wdiv(
            leverActions.fiatForUnderlier(pathPoolIds, pathAssetsIn, fiatOut),
            10**IERC20Metadata(address(usdc)).decimals()
        );
        
        assertApproxEqAbs(underlierOut, underlierIn, 0.22 ether);
    }

    function test_fiatForUnderlier() public {
        uint256 fiatOut = 500 * WAD;

        // prepare arguments for preview method, ordered from underlier to FIAT
        bytes32[] memory pathPoolIds = new bytes32[](3);
        pathPoolIds[0] = bbausdPoolId; // USDC : USDC pool
        pathPoolIds[1] = bbausdPoolId; // DAI : USDC pool
        pathPoolIds[2] = fiatPoolId; // USDC : FIAT pool

        address[] memory pathAssetsIn = new address[](3);
        pathAssetsIn[0] = address(usdc); // USDC to DAI
        pathAssetsIn[1] = address(dai); // DAI to USDC
        pathAssetsIn[2] = address(usdc); // USDC to FIAT
        
        uint256 underlierIn = leverActions.fiatForUnderlier(pathPoolIds, pathAssetsIn, fiatOut);
        assertApproxEqAbs(
            wdiv(underlierIn,10**IERC20Metadata(address(usdc)).decimals()), 
            fiatOut, 4 * WAD
        );

        // sanity check: FIAT amount should be the same for the same swap direction (account for precision errors)
        uint256 fiatOut_ = leverActions.underlierToFIAT(pathPoolIds, pathAssetsIn, underlierIn);
        assertApproxEqAbs(fiatOut, fiatOut_, 1 * 10 ** (18 - 5));
        
        // sanity check: underlier amount should be close to the same for the reverse swap
        uint256 fiatIn = fiatOut;
        
        pathPoolIds[0] = fiatPoolId; // FIAT : USDC pool
        pathPoolIds[1] = bbausdPoolId; // USDC : DAI pool
        pathPoolIds[2] = bbausdPoolId; // DAI : USDC pool

        address[] memory pathAssetsOut = new address[](3);
        pathAssetsOut[0] = address(usdc); // FIAT to USDC
        pathAssetsOut[1] = address(dai); // USDC to DAI
        pathAssetsOut[2] = address(usdc); // DAI to USDC
        
        uint256 underlierOut = leverActions.fiatToUnderlier(pathPoolIds, pathAssetsOut, fiatIn);
        assertApproxEqAbs(underlierIn, underlierOut, ONE_USDC);
    }
}
