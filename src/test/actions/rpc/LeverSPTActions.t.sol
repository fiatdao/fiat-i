// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

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
import {toInt256, WAD, wdiv} from "../../../core/utils/Math.sol";

import {VaultSPT} from "../../../vaults/VaultSPT.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";
import {IVault} from "../../../interfaces/IVault.sol";

import {VaultSPTActions, IPeriphery} from "../../../actions/vault/VaultSPTActions.sol";
import {LeverSPTActions} from "../../../actions/lever/LeverSPTActions.sol";

import {IBalancerVault, IAsset} from "../../../actions/helper/ConvergentCurvePoolHelper.sol";
import {Caller} from "../../../test/utils/Caller.sol";

interface IDivider {
    function redeem(
        address adapter,
        uint256 maturity,
        uint256 uBal
    ) external returns (uint256 tBal);

    function series(address adapter, uint256 maturity) external returns (Series memory);

    function settleSeries(address adapter, uint256 maturity) external;

    struct Series {
        address pt;
        uint48 issuance;
        address yt;
        uint96 tilt;
        address sponsor;
        uint256 reward;
        uint256 iscale;
        uint256 mscale;
        uint256 maxscale;
    }
}

contract LeverSPTActions_RPC_tests is Test {
    Codex internal codex;
    Moneta internal moneta;
    FIAT internal fiat;
    Collybus internal collybus;
    Publican internal publican;
    Flash internal flash;

    PRBProxy internal userProxy;
    PRBProxyFactory internal prbProxyFactory;
    
    VaultFactory internal vaultFactory;
    VaultSPTActions internal vaultActions;
    LeverSPTActions internal leverActions;
    IVault internal sPmaDAIVault;

    Caller internal user;
    address internal me = address(this);

    // Underliers
    IERC20 internal usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 internal dai = IERC20(address(0x6B175474E89094C44Da98b954EedeAC495271d0F));
    address internal weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Sense Finance contracts
    IPeriphery internal periphery = IPeriphery(address(0xFff11417a58781D3C72083CB45EF54d79Cd02437));
    IDivider internal divider = IDivider(address(0x86bA3E96Be68563E41c2f5769F1AF9fAf758e6E0));
    // Morpho maDAI (target)
    IERC20 internal maDAI = IERC20(address(0x36F8d0D0573ae92326827C4a82Fe4CE4C244cAb6));
    // Sense Finance maDAI Principal Token 
    IERC20 internal sP_maDAI = IERC20(address(0x0427a3A0De8c4B3dB69Dd7FdD6A90689117C3589));
    // Sense Bal V2 pool for maDAI/sP_maDAI
    address internal sPmaDAISpace = address(0x67F8db40638D8e06Ac78E1D04a805F59d11aDf9b);
    // Sense Finance maDAI adapter
    address internal maDAIAdapter = address(0x9887e67AaB4388eA4cf173B010dF5c92B91f55B5);
    // sPmaDAI maturity - 1st July 2023
    uint256 internal maturity = 1688169600;

    // Balancer contracts
    bytes32 internal fiatPoolId = 0x178e029173417b1f9c8bc16dcec6f697bc32374600000000000000000000025d;
    bytes32 internal bbausdPoolId = 0x06df3b2bbb68adc8b0e302443692037ed9f91b42000000000000000000000063;
    bytes32 internal usdcWethPoolId = 0x96646936b91d6b9d7d0c47c496afbf3d6ec7b6f8000200000000000000000019;
    address internal fiatBalancerVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    address internal senseBalancerVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

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
        LeverSPTActions.SellFIATSwapParams memory fiatSwapParams,
        LeverSPTActions.CollateralSwapParams memory collateralSwapParams
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
        LeverSPTActions.BuyFIATSwapParams memory fiatSwapParams,
        LeverSPTActions.CollateralSwapParams memory collateralSwapParams
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
        LeverSPTActions.BuyFIATSwapParams memory fiatSwapParams,
        LeverSPTActions.PTokenRedeemParams memory redeemParams
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
                fiatSwapParams,
                redeemParams
            )
        );
    }

    function _buyCollateralAndModifyDebt(
        address vault,
        address collateralizer,
        address creditor,
        uint256 underlierAmount,
        int256 deltaNormalDebt,
        VaultSPTActions.SwapParams memory swapParams
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
        address adapter,
        address assetIn,
        address assetOut,
        uint256 minAccepted,
        uint256 _maturity,
        uint256 approve
    ) internal pure returns (VaultSPTActions.SwapParams memory) {
        return VaultSPTActions.SwapParams(adapter, minAccepted, _maturity, assetIn, assetOut, approve);
    }

    function _getCollateralSwapParams(
        address assetIn,
        address assetOut,
        address adapter,
        uint256 approve,
        uint256 minAccepted
    ) internal view returns (LeverSPTActions.CollateralSwapParams memory collateralSwapParams) {
        collateralSwapParams.adapter = adapter;
        collateralSwapParams.minAccepted = minAccepted;
        collateralSwapParams.maturity = maturity;
        collateralSwapParams.assetIn = assetIn;
        collateralSwapParams.assetOut = assetOut;
        collateralSwapParams.approve = approve;
    }

    function _getSellFIATSwapParams(
        IBalancerVault.BatchSwapStep[] memory swaps, IAsset[] memory assets, int[] memory limits
    )
        internal
        view
        returns (LeverSPTActions.SellFIATSwapParams memory fiatSwapParams)
    {   
        fiatSwapParams.swaps = swaps;
        fiatSwapParams.assets = assets;
        fiatSwapParams.limits = limits;
        fiatSwapParams.deadline = block.timestamp + 12 weeks;
    }

    function _getBuyFIATSwapParams(
        IBalancerVault.BatchSwapStep[] memory swaps, IAsset[] memory assets, int[] memory limits
    )
        internal
        view
        returns (LeverSPTActions.BuyFIATSwapParams memory fiatSwapParams)
    {
       fiatSwapParams.swaps = swaps;
       fiatSwapParams.assets = assets;
       fiatSwapParams.limits = limits;
       fiatSwapParams.deadline = block.timestamp + 12 weeks;
    }

    function _getRedeemParams(address adapter)
        internal
        view
        returns (LeverSPTActions.PTokenRedeemParams memory redeemParams)
    {
        redeemParams.adapter = adapter;
        redeemParams.maturity = maturity;
        redeemParams.target = address(maDAI);
        redeemParams.underlierToken = address(dai);
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 15855705); // 29 October 2022

        // setup the core contracts
        vaultFactory = new VaultFactory();
        fiat = FIAT(0x586Aa273F262909EEF8fA02d90Ab65F5015e0516); // use the deployed instance of FIAT on mainnet
        vm.startPrank(0xa55E0d3d697C4692e9C37bC3a7062b1bECeEF45B);
        fiat.allowCaller(fiat.ANY_SIG(), address(this));
        vm.stopPrank();
        codex = new Codex();
        publican = new Publican(address(codex));
        codex.allowCaller(codex.modifyRate.selector, address(publican));
        moneta = new Moneta(address(codex), address(fiat));
        fiat.allowCaller(fiat.mint.selector, address(moneta));
        collybus = new Collybus();
        prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));
        codex.setParam("globalDebtCeiling", uint256(10000000 ether));
        codex.allowCaller(keccak256("ANY_SIG"), address(publican));

        // deploy the sPmaDAI vault
        sPmaDAIVault = IVault(
            vaultFactory.createVault(
                address(new VaultSPT(address(codex), address(maDAI), address(dai))),
                abi.encode(block.timestamp + 8 weeks, address(sP_maDAI), address(collybus))
            )
        );

        // initialize the sPmaDAI vault
        codex.init(address(sPmaDAIVault));
        codex.allowCaller(codex.transferCredit.selector, address(moneta));
        codex.setParam("globalDebtCeiling", 10000000 ether);
        codex.setParam(address(sPmaDAIVault), "debtCeiling", 1000000 ether);
        collybus.setParam(address(sPmaDAIVault), "liquidationRatio", 1 ether);
        collybus.updateSpot(address(dai), 1 ether);
        publican.init(address(sPmaDAIVault));
        codex.allowCaller(codex.modifyBalance.selector, address(sPmaDAIVault));

        // get test DAI
        user = new Caller();
        deal(address(dai), address(user), 10000 ether);
        deal(address(dai), me, 10000 ether);

        // set up flashlending facility
        flash = new Flash(address(moneta));
        fiat.allowCaller(fiat.mint.selector, address(moneta));
        flash.setParam("max", 1000000 * WAD);
        codex.allowCaller(keccak256("ANY_SIG"), address(flash));

        // user proxy setup - allow UserProxy to spend tokens on behalf of address(this) and the user's EOA
        IERC20(address(dai)).approve(address(userProxy), type(uint256).max);
        IERC20(address(sP_maDAI)).approve(address(userProxy), type(uint256).max);
        IERC20(address(maDAI)).approve(address(userProxy), type(uint256).max);
        fiat.approve(address(userProxy), type(uint256).max);
        user.externalCall(
            address(dai), abi.encodeWithSelector(dai.approve.selector, address(userProxy), type(uint256).max)
        );

        vaultActions = new VaultSPTActions(
            address(codex),
            address(moneta),
            address(fiat),
            address(publican),
            address(periphery),
            periphery.divider()
        );

        // deploy LeverActions 
        leverActions = new LeverSPTActions(
            address(codex),
            address(fiat),
            address(flash),
            address(moneta),
            address(publican),
            fiatPoolId,
            fiatBalancerVault,
            address(periphery),
            address(divider)
        );
    }

    function test_buyCollateralAndIncreaseLever_buildSellFIATSwapParams() public {
        uint256 lendFIAT = 1000 * WAD;
        uint256 upfrontUnderlier = 1000 * WAD;
        uint256 totalUnderlier = 2000 * WAD;
        uint256 fee = 50 * WAD;

        // prepare sell FIAT params
        bytes32[] memory pathPoolIds = new bytes32[](4);
        pathPoolIds[0] = fiatPoolId; // FIAT : USDC pool
        pathPoolIds[1] = usdcWethPoolId; // USDC : WETH pool
        pathPoolIds[2] = usdcWethPoolId; // WETH : USDC pool
        pathPoolIds[3] = bbausdPoolId; // USDC : DAI pool
        
        address[] memory pathAssetsOut = new address[](4);
        pathAssetsOut[0] = address(usdc); // FIAT to USDC
        pathAssetsOut[1] = address(weth); // USDC to WETH
        pathAssetsOut[2] = address(usdc); // WETH to USDC
        pathAssetsOut[3] = address(dai); // USDC to DAI
      
        uint256 minUnderliersOut = totalUnderlier - upfrontUnderlier - fee;
        uint256 deadline = block.timestamp + 10 days;

        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline), 
            // swap all for pTokens
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertGe(_collateral(address(sPmaDAIVault), address(userProxy)), 2000 * WAD);
        assertGe(_normalDebt(address(sPmaDAIVault), address(userProxy)), 1000 * WAD);
    }

    function testFail_buyCollateralAndIncreaseLever_buildSellFIATSwapParams_notSafe() public {
        collybus.setParam(address(sPmaDAIVault), "liquidationRatio", 1.03 ether);
        uint256 lendFIAT = 1000 * WAD;
        uint256 upfrontUnderlier = 0 * WAD;
        uint256 totalUnderlier = 1000 * WAD;
        uint256 fee = 10 * WAD;

        // prepare sell FIAT params
        bytes32[] memory pathPoolIds = new bytes32[](4);
        pathPoolIds[0] = fiatPoolId;
        pathPoolIds[1] = fiatPoolId;
        pathPoolIds[2] = fiatPoolId;
        pathPoolIds[3] = fiatPoolId;

        address[] memory pathAssetsOut = new address[](4);
        pathAssetsOut[0] = address(usdc);
        pathAssetsOut[1] = address(dai);
        pathAssetsOut[2] = address(usdc);
        pathAssetsOut[3] = address(dai);
      
        uint256 minUnderliersOut = totalUnderlier - upfrontUnderlier - fee;
        uint256 deadline = block.timestamp + 10 days;

        assertEq(_collateral(address(sPmaDAIVault), address(userProxy)), 0);
        assertEq(_normalDebt(address(sPmaDAIVault), address(userProxy)), 0);

        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline), 
            // swap all underlier for pTokens
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertGe(_collateral(address(sPmaDAIVault), address(userProxy)), 1000 * WAD);
        assertGe(_normalDebt(address(sPmaDAIVault), address(userProxy)), 1000 * WAD);
    }

    function test_buyCollateralAndIncreaseLever_buildSellFIATSwapParams_no_upfrontUnderlier() public {
        collybus.setParam(address(sPmaDAIVault), "liquidationRatio", 1.03 ether);
        
        // First we need to open a position
        uint256 amount = 100 * WAD;
        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = sP_maDAI.balanceOf(address(sPmaDAIVault));
        assertEq(_collateral(address(sPmaDAIVault), address(userProxy)),0);
        uint256 previewOut = vaultActions.underlierToPToken(sPmaDAISpace, senseBalancerVault, amount);

        _buyCollateralAndModifyDebt(
            address(sPmaDAIVault),
            me,
            address(0),
            amount,
            0,
           _getSwapParams(
                maDAIAdapter,
                address(dai),
                address(sP_maDAI),
                0,
                maturity,
                amount
            )
        );

        assertEq(dai.balanceOf(me), meInitialBalance - amount);
        assertTrue(sP_maDAI.balanceOf(address(sPmaDAIVault)) >= previewOut + vaultInitialBalance);
        assertTrue(
            _collateral(address(sPmaDAIVault), address(userProxy)) >=
                 wdiv(previewOut, 10**IERC20Metadata(address(sP_maDAI)).decimals())
        );

        uint256 lendFIAT = 1000 * WAD;
        uint256 upfrontUnderlier = 0 * WAD;
        uint256 totalUnderlier = 1000 * WAD;
        uint256 fee = 10 * WAD;

        // prepare sell FIAT params
        bytes32[] memory pathPoolIds = new bytes32[](4);
        pathPoolIds[0] = fiatPoolId;
        pathPoolIds[1] = fiatPoolId;
        pathPoolIds[2] = fiatPoolId;
        pathPoolIds[3] = fiatPoolId;
        
        address[] memory pathAssetsOut = new address[](4);
        pathAssetsOut[0] = address(usdc);
        pathAssetsOut[1] = address(dai);
        pathAssetsOut[2] = address(usdc);
        pathAssetsOut[3] = address(dai);
      
        uint256 minUnderliersOut = totalUnderlier - upfrontUnderlier - fee;
        uint256 deadline = block.timestamp + 10 days;

        assertGt(_collateral(address(sPmaDAIVault), address(userProxy)), 0);
        assertEq(_normalDebt(address(sPmaDAIVault), address(userProxy)), 0);

        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline), 
            // swap all for pTokens
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertGe(_collateral(address(sPmaDAIVault), address(userProxy)), 1000 * WAD);
        assertGe(_normalDebt(address(sPmaDAIVault), address(userProxy)), 1000 * WAD);
    }

    function test_buyCollateralAndIncreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(address(sP_maDAI)).balanceOf(address(sPmaDAIVault));
        uint256 initialCollateral = _collateral(address(sPmaDAIVault), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(sPmaDAISpace),
            senseBalancerVault,
            totalUnderlier
        );

        // prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT);  // max FIAT amount in 
        limits[1] = -int256(totalUnderlier-upfrontUnderlier-fee); // min DAI out after fees

        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits), 
             // swap all underlier for pTokens
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertEq(dai.balanceOf(me), meInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(sP_maDAI)).balanceOf(address(sPmaDAIVault)),
            vaultInitialBalance + (estDeltaCollateral - 10 ether) // subtract fees
        );
        assertGe(
            _collateral(address(sPmaDAIVault), address(userProxy)),
            initialCollateral + wdiv(estDeltaCollateral, 10 ether) - WAD // subtract fees
        );
    }

    function test_buyCollateralAndIncreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = dai.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault));
        uint256 initialCollateral = _collateral(address(sPmaDAIVault), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(sPmaDAISpace),
            senseBalancerVault,
            totalUnderlier
        );

        // prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees

        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
             // swap all underlier for pTokens
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertEq(dai.balanceOf(address(user)), userInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(sP_maDAI)).balanceOf(address(sPmaDAIVault)),
            vaultInitialBalance + (estDeltaCollateral - 5 ether) // subtract fees
        );
        assertGe(
            _collateral(address(sPmaDAIVault), address(userProxy)),
            initialCollateral + wdiv(estDeltaCollateral, 5 ether) - WAD // subtract fees
        );
    }

    function test_buyCollateralAndIncreaseLever_for_address_zero() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault));
        uint256 initialCollateral = _collateral(address(sPmaDAIVault), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(sPmaDAISpace),
            senseBalancerVault,
            totalUnderlier
        );

        // prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees

        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            // swap all underlier for pTokens
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertEq(dai.balanceOf(address(userProxy)), userProxyInitialBalance - upfrontUnderlier);
        assertGe(
            IERC20(address(sP_maDAI)).balanceOf(address(sPmaDAIVault)),
            vaultInitialBalance + (estDeltaCollateral - 5 ether)
        );
        assertGe(
            _collateral(address(sPmaDAIVault), address(userProxy)), // subtract fees
            initialCollateral + wdiv(estDeltaCollateral, 5 ether) - WAD // subtract fees
        );
    }

    function test_buyCollateralAndIncreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault));
        uint256 initialCollateral = _collateral(address(sPmaDAIVault), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(sPmaDAISpace),
            senseBalancerVault,
            totalUnderlier
        );

        // prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees

        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            // swap all underlier for pTokens
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertEq(dai.balanceOf(address(userProxy)), userProxyInitialBalance - upfrontUnderlier);
        assertGe(
            IERC20(address(sP_maDAI)).balanceOf(address(sPmaDAIVault)),
            vaultInitialBalance + (estDeltaCollateral - 5 ether)
        );
        assertGe(
            _collateral(address(sPmaDAIVault), address(userProxy)), // subtract fees
            initialCollateral + wdiv(estDeltaCollateral, 5 ether) - WAD // subtract fees
        );
    }

    function test_sellCollateralAndDecreaseLever_buildBuyFIATSwapParams() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;

        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault));
        uint256 initialCollateral = _collateral(address(sPmaDAIVault), address(userProxy));

        // prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees
        
        assertEq(usdc.balanceOf(address(leverActions)), 0);

        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        uint256 pTokenAmount = _collateral(address(sPmaDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(sPmaDAIVault), address(userProxy));

        // prepare buy FIAT params
        bytes32[] memory pathPoolIds = new bytes32[](4);
        pathPoolIds[0] = bbausdPoolId; // DAI : USDC pool
        pathPoolIds[1] = usdcWethPoolId; // USDC : WETH pool
        pathPoolIds[2] = usdcWethPoolId; // WETH : USDC pool
        pathPoolIds[3] = fiatPoolId; // USDC : FIAT pool

        address[] memory pathAssetsIn = new address[](4);
        pathAssetsIn[0] = address(dai); // DAI to USDC
        pathAssetsIn[1] = address(usdc); // USDC to WETH
        pathAssetsIn[2] = address(weth); // WETH to USDC
        pathAssetsIn[3] = address(usdc); // USDC to FIAT
      
        uint maxUnderliersIn = totalUnderlier - upfrontUnderlier + fee; // max DAI In
        uint deadline = block.timestamp + 10 days;
        
        _sellCollateralAndDecreaseLever(
            address(sPmaDAIVault),
            me,
            pTokenAmount,
            normalDebt,
            leverActions.buildBuyFIATSwapParams(pathPoolIds, pathAssetsIn, maxUnderliersIn, deadline),
            _getCollateralSwapParams(address(sP_maDAI), address(dai), address(maDAIAdapter), type(uint256).max, 0)
        );
        assertEq(usdc.balanceOf(address(leverActions)), 0);
        assertGt(dai.balanceOf(me), meInitialBalance - 15 ether); // subtract fees / rounding errors
        assertEq(IERC20(address(sP_maDAI)).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = dai.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault));
        uint256 initialCollateral = _collateral(address(sPmaDAIVault), address(userProxy));
        
        // prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees

        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        uint256 pTokenAmount = _collateral(address(sPmaDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(sPmaDAIVault), address(userProxy));

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _sellCollateralAndDecreaseLever(
            address(sPmaDAIVault),
            address(user),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(sP_maDAI), address(dai), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertGt(dai.balanceOf(address(user)), userInitialBalance - 5 ether); // subtract fees / rounding errors
        assertEq(IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_collect_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = dai.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault));
        uint256 initialCollateral = _collateral(address(sPmaDAIVault), address(userProxy));
        
        // prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees

        // collect interest and update rate accumulator beforehand
        publican.setParam(address(sPmaDAIVault), "interestPerSecond", 1.000000000790000 ether);
        publican.collect(address(sPmaDAIVault));

        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        uint256 pTokenAmount = _collateral(address(sPmaDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(sPmaDAIVault), address(userProxy));

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        vm.warp(block.timestamp + 40 days);
        publican.collect(address(sPmaDAIVault));
        codex.createUnbackedDebt(address(moneta), address(moneta), 2 *WAD);

        _sellCollateralAndDecreaseLever(
            address(sPmaDAIVault),
            address(user),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(sP_maDAI), address(dai), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertGt(dai.balanceOf(address(user)), userInitialBalance - 5 ether); // subtract fees / rounding errors
        assertEq(IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_address_zero() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault));
        uint256 initialCollateral = _collateral(address(sPmaDAIVault), address(userProxy));

        // prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees
        
        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        uint256 pTokenAmount = _collateral(address(sPmaDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(sPmaDAIVault), address(userProxy));

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _sellCollateralAndDecreaseLever(
            address(sPmaDAIVault),
            address(0),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(sP_maDAI), address(dai), address(maDAIAdapter), type(uint256).max, 0)
        );

        // subtract fees / rounding errors
        assertGt(dai.balanceOf(address(userProxy)), userProxyInitialBalance - 5 ether);
        assertEq(IERC20(address(sP_maDAI)).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault));
        uint256 initialCollateral = _collateral(address(sPmaDAIVault), address(userProxy));
        
        // prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees
        
        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        uint256 pTokenAmount = _collateral(address(sPmaDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(sPmaDAIVault), address(userProxy));
        
        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _sellCollateralAndDecreaseLever(
            address(sPmaDAIVault),
            address(userProxy),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(sP_maDAI), address(dai), address(maDAIAdapter), type(uint256).max, 0)
        );

        // subtract fees / rounding errors
        assertGt(dai.balanceOf(address(userProxy)), userProxyInitialBalance - 5 ether);
        assertEq(IERC20(address(sP_maDAI)).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault));
        uint256 initialCollateral = _collateral(address(sPmaDAIVault), address(userProxy));
        
        // prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees
        
        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertLt(dai.balanceOf(me), meInitialBalance);
        assertGt(IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertGt(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = _collateral(address(sPmaDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(sPmaDAIVault), address(userProxy));

        // Move post maturity
        vm.warp(maturity + 1);

        // settle series from sponsor
        IDivider.Series memory series = divider.series(maDAIAdapter, maturity);
        vm.prank(series.sponsor);
        divider.settleSeries(maDAIAdapter, maturity);

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(sPmaDAIVault),
            address(sP_maDAI),
            me,
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getRedeemParams(address(maDAIAdapter))
        );

        assertGt(dai.balanceOf(me), meInitialBalance);
        assertEq(IERC20(address(sP_maDAI)).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = dai.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault));
        uint256 initialCollateral = _collateral(address(sPmaDAIVault), address(userProxy));
        
        // prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees
        
        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertLt(dai.balanceOf(address(user)), userInitialBalance);
        assertGt(IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertGt(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = _collateral(address(sPmaDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(sPmaDAIVault), address(userProxy));

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        IDivider.Series memory series = divider.series(maDAIAdapter, maturity);
        vm.prank(series.sponsor);
        divider.settleSeries(maDAIAdapter, maturity);
        
        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(sPmaDAIVault),
            address(sP_maDAI),
            address(user),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getRedeemParams(maDAIAdapter)
        );

        assertGt(dai.balanceOf(address(user)), userInitialBalance);
        assertEq(IERC20(address(sP_maDAI)).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_address_zero() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault));
        uint256 initialCollateral = _collateral(address(sPmaDAIVault), address(userProxy));
        
        // prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees
        
        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertLt(dai.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertGt(IERC20(address(sP_maDAI)).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertGt(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = _collateral(address(sPmaDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(sPmaDAIVault), address(userProxy));

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        IDivider.Series memory series = divider.series(maDAIAdapter, maturity);
        vm.prank(series.sponsor);
        divider.settleSeries(maDAIAdapter, maturity);

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(sPmaDAIVault),
            address(sP_maDAI),
            address(0),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getRedeemParams(maDAIAdapter)
        );

        assertGt(dai.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertEq(IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault));
        uint256 initialCollateral = _collateral(address(sPmaDAIVault), address(userProxy));
        
        // prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees
        
        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertLt(dai.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertGt(IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertGt(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = _collateral(address(sPmaDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(sPmaDAIVault), address(userProxy));

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        IDivider.Series memory series = divider.series(maDAIAdapter, maturity);
        vm.prank(series.sponsor);
        divider.settleSeries(maDAIAdapter, maturity);

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(sPmaDAIVault),
            sPmaDAIVault.token(),
            address(userProxy),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getRedeemParams(maDAIAdapter)
        );

        assertGt(dai.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertEq(IERC20(address(sP_maDAI)).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_collect() public {
        uint256 lendFIAT = 100 * WAD;
        uint256 upfrontUnderlier = 600 * WAD;
        uint256 totalUnderlier = 700 * WAD;
        uint256 fee = 5 * WAD;
        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault));
        uint256 initialCollateral = _collateral(address(sPmaDAIVault), address(userProxy));

        // prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees

        // collect interest and update rate accumulator beforehand 
        publican.setParam(address(sPmaDAIVault), "interestPerSecond", 1.000000000790000 ether);
        publican.collect(address(sPmaDAIVault));
        
        _buyCollateralAndIncreaseLever(
            address(sPmaDAIVault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertLt(dai.balanceOf(me), meInitialBalance);
        assertGt(IERC20(sP_maDAI).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertGt(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = _collateral(address(sPmaDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(sPmaDAIVault), address(userProxy));
 
        // Move post maturity
        vm.warp(maturity + 1);

        publican.collect(address(sPmaDAIVault));
        codex.createUnbackedDebt(address(moneta), address(moneta), 2 *WAD);

        // Settle serie from sponsor
        IDivider.Series memory series = divider.series(maDAIAdapter, maturity);
        vm.prank(series.sponsor);
        divider.settleSeries(maDAIAdapter, maturity);

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(sPmaDAIVault),
            address(sP_maDAI),
            me,
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getRedeemParams(address(maDAIAdapter))
        );

        assertGt(dai.balanceOf(me), meInitialBalance);
        assertEq(IERC20(address(sP_maDAI)).balanceOf(address(sPmaDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(sPmaDAIVault), address(userProxy)), initialCollateral);
    }

    function test_underlierToPToken() external {
        uint256 pTokenAmountNow = leverActions.underlierToPToken(address(sPmaDAISpace), senseBalancerVault, 100 ether);
        assertGt(pTokenAmountNow, 0);

        // advance in time
        vm.warp(block.timestamp + 180 days);
        uint256 pTokenAmountBeforeMaturity = leverActions.underlierToPToken(
            address(sPmaDAISpace), senseBalancerVault, 100 ether
        );
        // closest to the maturity we expect less pTokens for same underlier amount
        assertGt(pTokenAmountNow, pTokenAmountBeforeMaturity);

        // go to maturity
        vm.warp(maturity);
        uint256 pTokenAmountAtMaturity = leverActions.underlierToPToken(
            address(sPmaDAISpace), senseBalancerVault, 100 ether
        );
        // at maturity we expect even less pTokens
        assertGt(pTokenAmountBeforeMaturity, pTokenAmountAtMaturity);

        vm.warp(maturity + 24 days);
        uint256 pTokenAmountAfterMaturity = leverActions.underlierToPToken(
            address(sPmaDAISpace), senseBalancerVault, 100 ether
        );
        // same after maturity
        assertEq(pTokenAmountAtMaturity, pTokenAmountAfterMaturity);
        assertGt(pTokenAmountBeforeMaturity, pTokenAmountAfterMaturity);
    }

    function test_pTokenToUnderlier() external {
        uint256 underlierNow = leverActions.pTokenToUnderlier(
            address(sPmaDAISpace), senseBalancerVault, 100 ether
        );
        assertGt(underlierNow, 0);

        // advance in time
        vm.warp(block.timestamp + 90 days);
        uint256 underlierBeforeMaturity = leverActions.pTokenToUnderlier(
            address(sPmaDAISpace), senseBalancerVault, 100 ether
        );
        // closest to the maturity we expect more underlier for same pTokens
        assertGt(underlierBeforeMaturity, underlierNow);

        // go to maturity
        vm.warp(maturity);
        uint256 underlierAtMaturity = leverActions.pTokenToUnderlier(
            address(sPmaDAISpace), senseBalancerVault, 100 ether
        );
        // at maturity we expect even more underlier
        assertGt(underlierAtMaturity, underlierBeforeMaturity);

        // same after maturity
        vm.warp(maturity + 10 days);
        uint256 underlierAfterMaturity = leverActions.pTokenToUnderlier(
            address(sPmaDAISpace), senseBalancerVault, 100 ether
        );
        assertEq(underlierAtMaturity, underlierAfterMaturity);
    }

    function test_fiatToUnderlier() public {
        uint256 fiatIn = 500 * WAD;
        
        // prepare arguments for preview method, ordered from FIAT to underlier
        bytes32[] memory pathPoolIds = new bytes32[](2);
        pathPoolIds[0] = fiatPoolId; // FIAT : USDC pool
        pathPoolIds[1] = bbausdPoolId; // USDC : DAI pool

        address[] memory pathAssetsOut = new address[](2);
        pathAssetsOut[0] = address(usdc); // FIAT to USDC
        pathAssetsOut[1] = address(dai); // USDC to DAI

        uint256 underlierOut = leverActions.fiatToUnderlier(pathPoolIds, pathAssetsOut, fiatIn);
        assertApproxEqAbs(underlierOut, fiatIn, 5 * WAD);
        
        uint256 fiatOut = fiatIn;

        pathPoolIds[0] = bbausdPoolId; // DAI : USDC pool
        pathPoolIds[1] = fiatPoolId; // USDC : FIAT pool

        address[] memory pathAssetsIn = new address[](2);
        pathAssetsIn[0] = address(dai); // DAI to USDC
        pathAssetsIn[1] = address(usdc); // USDC to FIAT
        
        uint256 underlierIn = leverActions.fiatForUnderlier(pathPoolIds, pathAssetsIn, fiatOut);
        assertApproxEqAbs(underlierOut, underlierIn, 0.22 ether);
    }

    function test_fiatForUnderlier() public {
        uint256 fiatOut = 500 * WAD;

        // prepare arguments for preview method, ordered from underlier to FIAT
        bytes32[] memory pathPoolIds = new bytes32[](2);
        pathPoolIds[0] = bbausdPoolId; // DAI : USDC pool
        pathPoolIds[1] = fiatPoolId; // USDC : FIAT pool

        address[] memory pathAssetsIn = new address[](2);
        pathAssetsIn[0] = address(dai); // DAI to USDC
        pathAssetsIn[1] = address(usdc); // USDC to FIAT
        
        uint256 underlierIn = leverActions.fiatForUnderlier(pathPoolIds, pathAssetsIn, fiatOut);
        assertApproxEqAbs(underlierIn, fiatOut, 4 * WAD);

        // sanity check: FIAT amount should be the same for the same swap direction (account for precision errors)
        uint256 fiatOut_ = leverActions.underlierToFIAT(pathPoolIds, pathAssetsIn, underlierIn);
        assertApproxEqAbs(fiatOut, fiatOut_, 1 * 10 ** (18 - 5));
        
        // sanity check: underlier amount should be close to the same for the reverse swap
        uint256 fiatIn = fiatOut;
        
        pathPoolIds[0] = fiatPoolId; // FIAT : USDC pool
        pathPoolIds[1] = bbausdPoolId; //  USDC : DAI pool

        address[] memory pathAssetsOut = new address[](2);
        pathAssetsOut[0] = address(usdc); // FIAT to USDC
        pathAssetsOut[1] = address(dai); // USDC to DAI
        
        uint256 underlierOut = leverActions.fiatToUnderlier(pathPoolIds, pathAssetsOut, fiatIn);
        assertApproxEqAbs(underlierIn, underlierOut, 1 ether);
    }
}
