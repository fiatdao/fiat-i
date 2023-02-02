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
import {toInt256, WAD, wdiv, wmul} from "../../../core/utils/Math.sol";


import {IVault} from "../../../interfaces/IVault.sol";
import {VaultFY} from "../../../vaults/VaultFY.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";


import {VaultFYActions} from "../../../actions/vault/VaultFYActions.sol";
import {LeverFYActions} from "../../../actions/lever/LeverFYActions.sol";

import {IBalancerVault, IAsset} from "../../../actions/helper/ConvergentCurvePoolHelper.sol";
import {Caller} from "../../../test/utils/Caller.sol";

contract LeverFYActions_RPC_tests is Test {
    Codex internal codex;
    Moneta internal moneta;
    FIAT internal fiat;
    Collybus internal collybus;
    Publican internal publican;
    Flash internal flash;

    PRBProxy internal userProxy;
    PRBProxyFactory internal prbProxyFactory;

    VaultFYActions internal vaultActions;
    VaultFactory internal vaultFactory;
    LeverFYActions internal leverActions;
    IVault internal fyUSDC2212Vault;
    IVault internal fyDAI2212Vault;

    Caller internal user;
    address internal me = address(this);

    // Underliers
    IERC20 internal usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 internal dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address internal weth = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // Yield contracts
    address internal fyUSDC2212 = address(0x38b8BF13c94082001f784A642165517F8760988f);
    address internal fyUSDC2212LP = address(0xB2fff7FEA1D455F0BCdd38DA7DeE98af0872a13a);
    address internal fyDAI2212 = address(0xcDfBf28Db3B1B7fC8efE08f988D955270A5c4752);
    address internal fyDAI2212LP = address(0x52956Fb3DC3361fd24713981917f2B6ef493DCcC);

    uint256 internal ONE_USDC = 1e6;
    uint256 internal maturity = 1672412400;

    // Balancer contracts
    bytes32 internal fiatPoolId = 0x178e029173417b1f9c8bc16dcec6f697bc32374600000000000000000000025d;
    bytes32 internal usdcWethPoolId = 0x96646936b91d6b9d7d0c47c496afbf3d6ec7b6f8000200000000000000000019;
    bytes32 internal bbausdPoolId = 0x06df3b2bbb68adc8b0e302443692037ed9f91b42000000000000000000000063;
    address internal fiatBalancerVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

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
        LeverFYActions.SellFIATSwapParams memory fiatSwapParams,
        LeverFYActions.CollateralSwapParams memory collateralSwapParams
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
        uint256 fyTokenAmount,
        uint256 deltaNormalDebt,
        LeverFYActions.BuyFIATSwapParams memory fiatSwapParams,
        LeverFYActions.CollateralSwapParams memory collateralSwapParams
    ) internal {
        userProxy.execute(
            address(leverActions),
            abi.encodeWithSelector(
                leverActions.sellCollateralAndDecreaseLever.selector,
                vault,
                address(userProxy),
                collateralizer,
                fyTokenAmount,
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
        uint256 fyTokenAmount,
        uint256 deltaNormalDebt,
        LeverFYActions.BuyFIATSwapParams memory fiatSwapParams
    ) internal {
        userProxy.execute(
            address(leverActions),
            abi.encodeWithSelector(
                leverActions.redeemCollateralAndDecreaseLever.selector,
                vault,
                token,
                address(userProxy),
                collateralizer,
                fyTokenAmount,
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

    function _getSwapParams(
        address yieldSpacePool,
        address assetIn,
        address assetOut,
        uint256 minOutput
    ) internal pure returns (VaultFYActions.SwapParams memory swapParams) {
        swapParams.yieldSpacePool = yieldSpacePool;
        swapParams.assetIn = assetIn;
        swapParams.assetOut = assetOut;
        swapParams.minAssetOut = minOutput;
    }

    function _getCollateralSwapParams(
        address assetIn,
        address assetOut,
        uint256 minAssetOut,
        address yieldSpacePool
    ) internal pure returns (LeverFYActions.CollateralSwapParams memory collateralSwapParams) {
        collateralSwapParams.minAssetOut = minAssetOut;
        collateralSwapParams.yieldSpacePool = yieldSpacePool;
        collateralSwapParams.assetIn = assetIn;
        collateralSwapParams.assetOut = assetOut;
    }

    function _getSellFIATSwapParams(
        IBalancerVault.BatchSwapStep[] memory _swaps, IAsset[] memory _assets, int[] memory _limits
    )
        internal
        view
        returns (LeverFYActions.SellFIATSwapParams memory fiatSwapParams)
    {   
        fiatSwapParams.swaps = _swaps;
        fiatSwapParams.assets = _assets;
        fiatSwapParams.limits = _limits;
        fiatSwapParams.deadline = block.timestamp + 12 weeks;
    }

    function _getBuyFIATSwapParams(
        IBalancerVault.BatchSwapStep[] memory _swaps, IAsset[] memory _assets, int[] memory _limits
    )
        internal
        view
        returns (LeverFYActions.BuyFIATSwapParams memory fiatSwapParams)
    {
       fiatSwapParams.swaps = _swaps;
       fiatSwapParams.assets = _assets;
       fiatSwapParams.limits = _limits;
       fiatSwapParams.deadline = block.timestamp + 12 weeks;
    }

    function setUp() public {
        // Fork
        vm.createSelectFork(vm.rpcUrl("mainnet"), 16000000 ); 

        vaultFactory = new VaultFactory();
        fiat = FIAT(0x586Aa273F262909EEF8fA02d90Ab65F5015e0516);
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
        codex.setParam("globalDebtCeiling", 10000000 ether);
        codex.allowCaller(codex.transferCredit.selector, address(moneta));
        codex.allowCaller(keccak256("ANY_SIG"), address(publican));

        // deploy the fyUSDC vault
        fyUSDC2212Vault = IVault(
            vaultFactory.createVault(
                address(new VaultFY(address(codex), address(usdc))),
                abi.encode(address(fyUSDC2212), address(collybus))
            )
        );

        // initialize the fyUSDC vault
        codex.init(address(fyUSDC2212Vault));
        codex.setParam(address(fyUSDC2212Vault), "debtCeiling", uint256(1000 ether));
        collybus.setParam(address(fyUSDC2212Vault), "liquidationRatio", 1 ether);
        codex.allowCaller(codex.modifyBalance.selector, address(fyUSDC2212Vault));
        publican.init(address(fyUSDC2212Vault));
        publican.setParam(address(fyUSDC2212Vault), "interestPerSecond", WAD);
        collybus.updateSpot(address(usdc), WAD);
        
        // deploy the fyDAI vault
        fyDAI2212Vault = IVault(
            vaultFactory.createVault(
                address(new VaultFY(address(codex), address(dai))),
                abi.encode(address(fyDAI2212), address(collybus))
            )
        );

        // initialize the fyDAI vault
        codex.init(address(fyDAI2212Vault));   
        codex.setParam(address(fyDAI2212Vault), "debtCeiling", uint256(1000 ether));
        collybus.setParam(address(fyDAI2212Vault), "liquidationRatio", 1 ether);
        codex.allowCaller(codex.modifyBalance.selector, address(fyDAI2212Vault));
        publican.init(address(fyDAI2212Vault));
        publican.setParam(address(fyDAI2212Vault), "interestPerSecond", WAD);
        collybus.updateSpot(address(dai), WAD);

        // get USDC and DAI
        user = new Caller();
        deal(address(usdc), address(user), 10000 * ONE_USDC);
        deal(address(usdc), me, 10000 * ONE_USDC);
        deal(address(dai), address(user), 10000 ether);
        deal(address(dai), me, 10000 ether);

        // set up flashlending facility
        flash = new Flash(address(moneta));
        fiat.allowCaller(fiat.mint.selector, address(moneta));
        flash.setParam("max", 1000000 * WAD);
        codex.allowCaller(keccak256("ANY_SIG"), address(flash));

        // user proxy setup - allow UserProxy to spend tokens on behalf of address(this) and the user's EOA
        IERC20(address(usdc)).approve(address(userProxy), type(uint256).max);
        IERC20(address(fyUSDC2212)).approve(address(userProxy), type(uint256).max);
        IERC20(address(fyUSDC2212LP)).approve(address(userProxy), type(uint256).max);
        IERC20(address(dai)).approve(address(userProxy), type(uint256).max);
        IERC20(address(fyDAI2212)).approve(address(userProxy), type(uint256).max);
        IERC20(address(fyDAI2212LP)).approve(address(userProxy), type(uint256).max);
        fiat.approve(address(userProxy), type(uint256).max);
        user.externalCall(
            address(usdc),
            abi.encodeWithSelector(usdc.approve.selector, address(userProxy), type(uint256).max)
        );
        user.externalCall(
            address(dai),
            abi.encodeWithSelector(dai.approve.selector, address(userProxy), type(uint256).max)
        );

        vaultActions = new VaultFYActions(address(codex), address(moneta), address(fiat), address(publican));
        leverActions = new LeverFYActions(
            address(codex),
            address(fiat),
            address(flash),
            address(moneta),
            address(publican),
            fiatPoolId,
            fiatBalancerVault
        );
    }

    function test_buyCollateralAndIncreaseLever_buildSellFIATSwapParams_usdc() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 500 * ONE_USDC;
        uint256 totalUnderlier = 1000 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        
        // Prepare sell FIAT params
        bytes32[] memory pathPoolIds = new bytes32[](3);
        pathPoolIds[0] = fiatPoolId; // FIAT : USDC pool
        pathPoolIds[1] = bbausdPoolId; // USDC : DAI pool
        pathPoolIds[2] = bbausdPoolId; // DAI : USDC pool

        address[] memory pathAssetsOut = new address[](3);
        pathAssetsOut[0] = address(usdc); // FIAT to USDC
        pathAssetsOut[1] = address(dai); // USDC to DAI
        pathAssetsOut[2] = address(usdc); // DAI to USDC
              
        uint256 minUnderliersOut = totalUnderlier - upfrontUnderlier - fee;
        uint256 deadline = block.timestamp + 10 days;

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline), 
             // swap all for fyTokens
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );
        
        assertGe(_collateral(address(fyUSDC2212Vault), address(userProxy)), 1000 * WAD);
        assertGe(_normalDebt(address(fyUSDC2212Vault), address(userProxy)), 500 * WAD);
    }

    function test_buyCollateralAndIncreaseLever_buildSellFIATSwapParams_dai() public {
        uint256 lendFIAT = 1000 * WAD;
        uint256 upfrontUnderlier = 1000 * WAD;
        uint256 totalUnderlier = 2000 * WAD;
        uint256 fee = 10 * WAD;
        
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
            address(fyDAI2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline), 
             // swap all for fyTokens
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP))
        );
        
        assertGe(_collateral(address(fyDAI2212Vault), address(userProxy)), 2000 * WAD - fee);
        assertGe(_normalDebt(address(fyDAI2212Vault), address(userProxy)), 1000 * WAD);
    }

    function testFail_buyCollateralAndIncreaseLever_buildSellFIATSwapParams_notSafe_usdc() public {
        collybus.setParam(address(fyUSDC2212Vault), "liquidationRatio", 1.03 ether);
        
        uint256 lendFIAT = 1000 * WAD;
        uint256 upfrontUnderlier = 0 * ONE_USDC;
        uint256 totalUnderlier = 1000 * ONE_USDC;
        uint256 fee = 10 * ONE_USDC;

        // Prepare sell FIAT params
        bytes32[] memory pathPoolIds = new bytes32[](3);
        pathPoolIds[0] = fiatPoolId; // FIAT : USDC pool
        pathPoolIds[1] = bbausdPoolId; // USDC : DAI pool
        pathPoolIds[2] = bbausdPoolId; // DAI : USDC pool

        address[] memory pathAssetsOut = new address[](3);
        pathAssetsOut[0] = address(usdc); // FIAT to USDC
        pathAssetsOut[1] = address(dai); // USDC to DAI
        pathAssetsOut[2] = address(usdc); // DAI to USDC
      
        uint256 minUnderliersOut = totalUnderlier - upfrontUnderlier - fee;
        uint256 deadline = block.timestamp + 10 days;

        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), 0);
        assertEq(_normalDebt(address(fyUSDC2212Vault), address(userProxy)), 0);

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline), 
             // swap all for fyTokens
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        assertGe(_collateral(address(fyUSDC2212Vault), address(userProxy)), 1000 * WAD);
        assertGe(_normalDebt(address(fyUSDC2212Vault), address(userProxy)), 500 * WAD);
    }

    function testFail_buyCollateralAndIncreaseLever_buildSellFIATSwapParams_notSafe_dai() public {
        collybus.setParam(address(fyDAI2212Vault), "liquidationRatio", 1.03 ether);

        uint256 lendFIAT = 2000 * WAD;
        uint256 upfrontUnderlier = 0 * WAD;
        uint256 totalUnderlier = 2000 * WAD;
        uint256 fee = 20 * WAD;
        
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
            address(fyDAI2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline), 
             // swap all for fyTokens
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP))
        );
        
        assertGe(_collateral(address(fyDAI2212Vault), address(userProxy)), 2000 * WAD - fee);
        assertGe(_normalDebt(address(fyDAI2212Vault), address(userProxy)), 1000 * WAD);
    }

    function test_buyCollateralAndIncreaseLever_buildSellFIATSwapParams_no_upfrontUnderlier_usdc() public {
        collybus.setParam(address(fyUSDC2212Vault), "liquidationRatio", 1.03 ether);
        
        // First we need to open a position
        uint256 amount = 100 * ONE_USDC;
        uint256 meInitialBalance = usdc.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault));
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)),0);
        uint256 previewOut = leverActions.underlierToFYToken(amount, address(fyUSDC2212LP));

        _buyCollateralAndModifyDebt(
            address(fyUSDC2212Vault),
            me,
            address(0),
            amount,
            0,
           _getSwapParams(address(fyUSDC2212LP),address(usdc), fyUSDC2212, previewOut)
        );

        assertEq(usdc.balanceOf(me), meInitialBalance - amount);
        assertTrue(
            IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)) >= 
            previewOut + vaultInitialBalance
        );

        assertTrue(
            _collateral(address(fyUSDC2212Vault), address(userProxy)) >=
                 wdiv(previewOut, 10**IERC20Metadata(address(fyUSDC2212)).decimals())
        );

        uint256 lendFIAT = 1000 * WAD;
        uint256 upfrontUnderlier = 0 * ONE_USDC;
        uint256 totalUnderlier = 1000 * ONE_USDC;
        uint256 fee = 10 * ONE_USDC;

        // prepare sell FIAT params
        bytes32[] memory pathPoolIds = new bytes32[](4);
        pathPoolIds[0] = fiatPoolId;
        pathPoolIds[1] = fiatPoolId;
        pathPoolIds[2] = fiatPoolId;
        pathPoolIds[3] = fiatPoolId;
        
        address[] memory pathAssetsOut = new address[](4);
        pathAssetsOut[0] = address(dai);
        pathAssetsOut[1] = address(usdc);
        pathAssetsOut[2] = address(dai);
        pathAssetsOut[3] = address(usdc);
      
        uint256 minUnderliersOut = totalUnderlier - upfrontUnderlier - fee;
        uint256 deadline = block.timestamp + 10 days;

        assertGt(_collateral(address(fyUSDC2212Vault), address(userProxy)), 0);
        assertEq(_normalDebt(address(fyUSDC2212Vault), address(userProxy)), 0);

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline), 
             // swap all for fyTokens
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        assertGe(_collateral(address(fyUSDC2212Vault), address(userProxy)), 1000 * WAD);
        assertGe(_normalDebt(address(fyUSDC2212Vault), address(userProxy)), 1000 * WAD);
    }

    function test_buyCollateralAndIncreaseLever_buildSellFIATSwapParams_no_upfrontUnderlier_dai() public {
        collybus.setParam(address(fyDAI2212Vault), "liquidationRatio", 1.03 ether);
        
        // First we need to open a position
        uint256 amount = 100 * WAD;
        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault));
        assertEq(_collateral(address(fyDAI2212Vault), address(userProxy)),0);
        uint256 previewOut = leverActions.underlierToFYToken(amount, address(fyDAI2212LP));

        _buyCollateralAndModifyDebt(
            address(fyDAI2212Vault),
            me,
            address(0),
            amount,
            0,
           _getSwapParams(address(fyDAI2212LP),address(dai), fyDAI2212, previewOut)
        );

        assertEq(dai.balanceOf(me), meInitialBalance - amount);
        assertTrue(
            IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)) >= 
            previewOut + vaultInitialBalance
        );

        assertTrue(
            _collateral(address(fyDAI2212Vault), address(userProxy)) >=
                 wdiv(previewOut, 10**IERC20Metadata(address(fyDAI2212)).decimals())
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

        assertGt(_collateral(address(fyDAI2212Vault), address(userProxy)), 0);
        assertEq(_normalDebt(address(fyDAI2212Vault), address(userProxy)), 0);

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline), 
             // swap all for fyTokens
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP))
        );

        assertGe(_collateral(address(fyDAI2212Vault), address(userProxy)), 1000 * WAD);
        assertGe(_normalDebt(address(fyDAI2212Vault), address(userProxy)), 1000 * WAD);
    }

    function test_buyCollateralAndIncreaseLever_usdc() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        uint256 meInitialBalance = usdc.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));
        assertEq(initialCollateral, 0);
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyUSDC2212LP));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT);  // max FIAT amount in 
        limits[1] = -int256(totalUnderlier-upfrontUnderlier-fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits), 
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP)) // swap all for fyTokens
        );

        assertEq(usdc.balanceOf(me), meInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)),
            vaultInitialBalance + (estDeltaCollateral - fee) // subtract fees
        );
        assertGe(
            _collateral(address(fyUSDC2212Vault), address(userProxy)),
            wdiv(estDeltaCollateral, 10 * fyUSDC2212Vault.tokenScale()) - WAD // subtract fees
        );
        assertApproxEqAbs(
            estDeltaCollateral, IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), 5 * WAD
        );
    }

    function test_buyCollateralAndIncreaseLever_dai() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;

        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));
        assertEq(initialCollateral, 0);
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyDAI2212LP));

        // Prepare sell FIAT params
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
            address(fyDAI2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits), 
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP)) // swap all for fyTokens
        );

        assertEq(dai.balanceOf(me), meInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)),
            vaultInitialBalance + (estDeltaCollateral - fee) // subtract fees
        );
        assertGe(
            _collateral(address(fyDAI2212Vault), address(userProxy)),
            wdiv(estDeltaCollateral, 10 * fyDAI2212Vault.tokenScale()) - WAD // subtract fees
        );
        assertApproxEqAbs(
            estDeltaCollateral, IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)), 5 * WAD
        );
    }

    function test_buyCollateralAndIncreaseLever_for_user_usdc() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = usdc.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));
        assertEq(initialCollateral, 0);
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyUSDC2212LP));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT);  // max FIAT amount in 
        limits[1] = -int256(totalUnderlier-upfrontUnderlier-fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits), 
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP)) // swap all for fyTokens
        );

        assertEq(usdc.balanceOf(address(user)), userInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)),
            vaultInitialBalance + (estDeltaCollateral - fee) // subtract fees
        );
        assertGe(
            _collateral(address(fyUSDC2212Vault), address(userProxy)),
            wdiv(estDeltaCollateral, 10 * fyUSDC2212Vault.tokenScale()) - WAD // subtract fees
        );
        assertApproxEqAbs(
            estDeltaCollateral, IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), 5 * WAD
        );
    }

    function test_buyCollateralAndIncreaseLever_for_user_dai() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = dai.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));
        assertEq(initialCollateral, 0);
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyDAI2212LP));

        // Prepare sell FIAT params
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
            address(fyDAI2212Vault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits), 
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP)) // swap all for fyTokens
        );

        assertEq(dai.balanceOf(address(user)), userInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)),
            vaultInitialBalance + (estDeltaCollateral - fee) // subtract fees
        );
        assertGe(
            _collateral(address(fyDAI2212Vault), address(userProxy)),
            wdiv(estDeltaCollateral, 10 * fyDAI2212Vault.tokenScale()) - WAD // subtract fees
        );
        assertApproxEqAbs(
            estDeltaCollateral, IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)), 5 * WAD
        );
    }

    function test_buyCollateralAndIncreaseLever_for_address_zero_usdc() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 proxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));
        assertEq(initialCollateral, 0);
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyUSDC2212LP));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT);  // max FIAT amount in 
        limits[1] = -int256(totalUnderlier-upfrontUnderlier-fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits), 
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP)) // swap all for fyTokens
        );

        assertEq(usdc.balanceOf(address(userProxy)), proxyInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)),
            vaultInitialBalance + (estDeltaCollateral - fee) // subtract fees
        );
        assertGe(
            _collateral(address(fyUSDC2212Vault), address(userProxy)),
            wdiv(estDeltaCollateral, 10 * fyUSDC2212Vault.tokenScale()) - WAD // subtract fees
        );
        assertApproxEqAbs(
            estDeltaCollateral, IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), 5 * WAD
        );
    }

    function test_buyCollateralAndIncreaseLever_for_address_zero_dai() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 proxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));
        assertEq(initialCollateral, 0);
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyDAI2212LP));

        // Prepare sell FIAT params
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
            address(fyDAI2212Vault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits), 
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP)) // swap all for fyTokens
        );

        assertEq(dai.balanceOf(address(userProxy)), proxyInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)),
            vaultInitialBalance + (estDeltaCollateral - fee) // subtract fees
        );
        assertGe(
            _collateral(address(fyDAI2212Vault), address(userProxy)),
            wdiv(estDeltaCollateral, 10 * fyDAI2212Vault.tokenScale()) - WAD // subtract fees
        );
        assertApproxEqAbs(
            estDeltaCollateral, IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)), 5 * WAD
        );
    }

    function test_buyCollateralAndIncreaseLever_for_proxy_usdc() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 proxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));
        assertEq(initialCollateral, 0);
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyUSDC2212LP));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(usdc));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT);  // max FIAT amount in 
        limits[1] = -int256(totalUnderlier-upfrontUnderlier-fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits), 
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP)) // swap all for fyTokens
        );

        assertEq(usdc.balanceOf(address(userProxy)), proxyInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)),
            vaultInitialBalance + (estDeltaCollateral - fee) // subtract fees
        );
        assertGe(
            _collateral(address(fyUSDC2212Vault), address(userProxy)),
            wdiv(estDeltaCollateral, 10 * fyUSDC2212Vault.tokenScale()) - WAD // subtract fees
        );
        assertApproxEqAbs(
            estDeltaCollateral, IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), 5 * WAD
        );
    }

    function test_buyCollateralAndIncreaseLever_for_proxy_dai() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 proxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));
        assertEq(initialCollateral, 0);
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyDAI2212LP));

        // Prepare sell FIAT params
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
            address(fyDAI2212Vault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits), 
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP)) // swap all for fyTokens
        );

        assertEq(dai.balanceOf(address(userProxy)), proxyInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)),
            vaultInitialBalance + (estDeltaCollateral - fee) // subtract fees
        );
        assertGe(
            _collateral(address(fyDAI2212Vault), address(userProxy)),
            wdiv(estDeltaCollateral, 10 * fyDAI2212Vault.tokenScale()) - WAD // subtract fees
        );
        assertApproxEqAbs(
            estDeltaCollateral, IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)), 5 * WAD
        );
    }

    function test_sellCollateralAndDecreaseLever_buildBuyFIATSwapParams_usdc() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;

        uint256 meInitialBalance = usdc.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

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
            address(fyUSDC2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        uint256 fyTokenAmount = (_collateral(address(fyUSDC2212Vault), address(userProxy)) * ONE_USDC) / WAD;

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
            address(fyUSDC2212Vault),
            me,
            fyTokenAmount,
            _normalDebt(address(fyUSDC2212Vault), address(userProxy)),
            leverActions.buildBuyFIATSwapParams(pathPoolIds, pathAssetsIn, maxUnderliersIn, deadline),
            _getCollateralSwapParams(address(fyUSDC2212), address(usdc), 0, address(fyUSDC2212LP))
        );

        assertGt(usdc.balanceOf(me), meInitialBalance - fee); // subtract fees / rounding errors
        assertEq(IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_buildBuyFIATSwapParams_dai() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;

        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // max FIAT in
        limits[1] = -int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees

        assertEq(dai.balanceOf(address(leverActions)), 0);

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP))
        );

        uint256 fyTokenAmount = _collateral(address(fyDAI2212Vault), address(userProxy));

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

        uint maxUnderliersIn = totalUnderlier - upfrontUnderlier + fee; // max USDC In
        uint deadline = block.timestamp + 10 days;

        _sellCollateralAndDecreaseLever(
            address(fyDAI2212Vault),
            me,
            fyTokenAmount,
            _normalDebt(address(fyDAI2212Vault), address(userProxy)),
            leverActions.buildBuyFIATSwapParams(pathPoolIds, pathAssetsIn, maxUnderliersIn, deadline),
            _getCollateralSwapParams(address(fyDAI2212), address(usdc), 0, address(fyDAI2212LP))
        );

        assertGt(dai.balanceOf(me), meInitialBalance - fee); // subtract fees / rounding errors
        assertEq(IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_user_usdc() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(user), upfrontUnderlier);

        uint256 meInitialBalance = usdc.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

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
            address(fyUSDC2212Vault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        uint256 fyTokenAmount = (_collateral(address(fyUSDC2212Vault), address(userProxy)) * ONE_USDC) / WAD;

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _sellCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            address(user),
            fyTokenAmount,
            _normalDebt(address(fyUSDC2212Vault), address(userProxy)),
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(fyUSDC2212), address(usdc), 0, address(fyUSDC2212LP))
        );

        assertGt(usdc.balanceOf(me), meInitialBalance - fee); // subtract fees / rounding errors
        assertEq(IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_user_dai() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = dai.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));
        
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
            address(fyDAI2212Vault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits), 
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP)) // swap all for fyTokens
        );

        uint256 fyTokenAmount = _collateral(address(fyDAI2212Vault), address(userProxy));

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _sellCollateralAndDecreaseLever(
            address(fyDAI2212Vault),
            address(user),
            fyTokenAmount,
            _normalDebt(address(fyDAI2212Vault), address(userProxy)),
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(fyDAI2212), address(dai), 0, address(fyDAI2212LP))
        );

        assertGt(dai.balanceOf(address(user)), userInitialBalance - fee); // subtract fees / rounding errors
        assertEq(IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_address_zero_usdc() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 proxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

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
            address(fyUSDC2212Vault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        uint256 fyTokenAmount = (_collateral(address(fyUSDC2212Vault), address(userProxy)) * ONE_USDC) / WAD;

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _sellCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            address(0),
            fyTokenAmount,
            _normalDebt(address(fyUSDC2212Vault), address(userProxy)),
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(fyUSDC2212), address(usdc), 0, address(fyUSDC2212LP))
        );

        assertGt(usdc.balanceOf(address(userProxy)), proxyInitialBalance - fee); // subtract fees / rounding errors
        assertEq(IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_zero_address_dai() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 proxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));
        
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
            address(fyDAI2212Vault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits), 
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP)) // swap all for fyTokens
        );

        uint256 fyTokenAmount = _collateral(address(fyDAI2212Vault), address(userProxy));

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _sellCollateralAndDecreaseLever(
            address(fyDAI2212Vault),
            address(0),
            fyTokenAmount,
            _normalDebt(address(fyDAI2212Vault), address(userProxy)),
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(fyDAI2212), address(dai), 0, address(fyDAI2212LP))
        );

        assertGt(dai.balanceOf(address(userProxy)), proxyInitialBalance - fee); // subtract fees / rounding errors
        assertEq(IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_proxy_usdc() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 *ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

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
            address(fyUSDC2212Vault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        uint256 fyTokenAmount = (_collateral(address(fyUSDC2212Vault), address(userProxy)) * ONE_USDC) / WAD;
        uint256 normalDebt = _normalDebt(address(fyUSDC2212Vault), address(userProxy));

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _sellCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            address(userProxy),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(fyUSDC2212), address(usdc), 0, address(fyUSDC2212LP))
        );

        // subtract fees / rounding errors
        assertGt(usdc.balanceOf(address(userProxy)), userProxyInitialBalance - 5 * ONE_USDC);
        assertEq(IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_usdc() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;

        uint256 meInitialBalance = usdc.balanceOf(address(me));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

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
            address(fyUSDC2212Vault),
            address(me),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        assertLt(usdc.balanceOf(address(me)), meInitialBalance);
        assertGt(IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(
            _collateral(address(fyUSDC2212Vault), address(userProxy)), fyUSDC2212Vault.tokenScale()
        );
        uint256 normalDebt = _normalDebt(address(fyUSDC2212Vault), address(userProxy));

        vm.warp(maturity);

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            fyUSDC2212Vault.token(),
            me,
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(usdc.balanceOf(me), meInitialBalance);
        assertEq(ERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_dai() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;

        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP))
        );

        assertLt(dai.balanceOf(me), meInitialBalance);
        assertGt(IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(
            _collateral(address(fyDAI2212Vault), address(userProxy)), fyDAI2212Vault.tokenScale()
        );
        uint256 normalDebt = _normalDebt(address(fyDAI2212Vault), address(userProxy));

        vm.warp(maturity);

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(fyDAI2212Vault),
            fyDAI2212Vault.token(),
            me,
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(dai.balanceOf(me), meInitialBalance);
        assertEq(ERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_user_usdc() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = usdc.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

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
            address(fyUSDC2212Vault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        assertLt(usdc.balanceOf(address(user)), userInitialBalance);
        assertGt(IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(
            _collateral(address(fyUSDC2212Vault), address(userProxy)), fyUSDC2212Vault.tokenScale()
        );
        uint256 normalDebt = _normalDebt(address(fyUSDC2212Vault), address(userProxy));

        vm.warp(maturity);

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            fyUSDC2212Vault.token(),
            address(user),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(usdc.balanceOf(address(user)), userInitialBalance);
        assertEq(ERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_user_dai() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = dai.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP))
        );

        assertLt(dai.balanceOf(address(user)), userInitialBalance);
        assertGt(IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(
            _collateral(address(fyDAI2212Vault), address(userProxy)), fyDAI2212Vault.tokenScale()
        );
        uint256 normalDebt = _normalDebt(address(fyDAI2212Vault), address(userProxy));

        vm.warp(maturity);

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(fyDAI2212Vault),
            fyDAI2212Vault.token(),
            address(user),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(dai.balanceOf(address(user)), userInitialBalance);
        assertEq(ERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);
    }
    
    function test_redeemCollateralAndDecreaseLever_for_address_zero_usdc() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 proxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

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
            address(fyUSDC2212Vault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        assertLt(usdc.balanceOf(address(userProxy)), proxyInitialBalance);
        assertGt(IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(
            _collateral(address(fyUSDC2212Vault), address(userProxy)), fyUSDC2212Vault.tokenScale()
        );
        uint256 normalDebt = _normalDebt(address(fyUSDC2212Vault), address(userProxy));

        vm.warp(maturity);

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            fyUSDC2212Vault.token(),
            address(0),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(usdc.balanceOf(address(userProxy)), proxyInitialBalance);
        assertEq(ERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_address_zero_dai() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 proxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP))
        );

        assertLt(dai.balanceOf(address(userProxy)), proxyInitialBalance);
        assertGt(IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(
            _collateral(address(fyDAI2212Vault), address(userProxy)), fyDAI2212Vault.tokenScale()
        );
        uint256 normalDebt = _normalDebt(address(fyDAI2212Vault), address(userProxy));

        vm.warp(maturity);

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(fyDAI2212Vault),
            fyDAI2212Vault.token(),
            address(0),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(dai.balanceOf(address(userProxy)), proxyInitialBalance);
        assertEq(ERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_proxy_usdc() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 proxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

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
            address(fyUSDC2212Vault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        assertLt(usdc.balanceOf(address(userProxy)), proxyInitialBalance);
        assertGt(IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(
            _collateral(address(fyUSDC2212Vault), address(userProxy)), fyUSDC2212Vault.tokenScale()
        );
        uint256 normalDebt = _normalDebt(address(fyUSDC2212Vault), address(userProxy));

        vm.warp(maturity);

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            fyUSDC2212Vault.token(),
            address(userProxy),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(usdc.balanceOf(address(userProxy)), proxyInitialBalance);
        assertEq(ERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_proxy_dai() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 proxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min USDC out after fees

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP))
        );

        assertLt(dai.balanceOf(address(userProxy)), proxyInitialBalance);
        assertGt(IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(
            _collateral(address(fyDAI2212Vault), address(userProxy)), fyDAI2212Vault.tokenScale()
        );
        uint256 normalDebt = _normalDebt(address(fyDAI2212Vault), address(userProxy));

        vm.warp(maturity);

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(fyDAI2212Vault),
            fyDAI2212Vault.token(),
            address(userProxy),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(dai.balanceOf(address(userProxy)), proxyInitialBalance);
        assertEq(ERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_collect_usdc() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        uint256 fee = 5 * ONE_USDC;
        usdc.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = usdc.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

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

        publican.setParam(address(fyUSDC2212Vault), "interestPerSecond", 1.000000000700000 ether);
        publican.collect(address(fyUSDC2212Vault));

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        assertLt(usdc.balanceOf(address(user)), userInitialBalance);
        assertGt(IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(
            _collateral(address(fyUSDC2212Vault), address(userProxy)), fyUSDC2212Vault.tokenScale()
        );
        uint256 normalDebt = _normalDebt(address(fyUSDC2212Vault), address(userProxy));

        vm.warp(maturity);
        publican.collect(address(fyUSDC2212Vault));
        codex.createUnbackedDebt(address(moneta), address(moneta), 2 *WAD);

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(usdc));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max USDC In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            fyUSDC2212Vault.token(),
            address(user),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(usdc.balanceOf(address(user)), userInitialBalance);
        assertEq(ERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_collect_dai() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = dai.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](1);
        swaps[0] = step;

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(fiat));
        assets[1] = IAsset(address(dai));

        int256[] memory limits = new int256[](2);
        limits[0] = int256(lendFIAT); // limit In set in the contracts as exactAmountIn
        limits[1] = int256(totalUnderlier - upfrontUnderlier - fee); // min DAI out after fees

        publican.setParam(address(fyDAI2212Vault), "interestPerSecond", 1.000000000700000 ether);
        publican.collect(address(fyDAI2212Vault));

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP))
        );

        assertLt(dai.balanceOf(address(user)), userInitialBalance);
        assertGt(IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = _collateral(address(fyDAI2212Vault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(fyDAI2212Vault), address(userProxy));

        vm.warp(maturity);
        publican.collect(address(fyDAI2212Vault));
        codex.createUnbackedDebt(address(moneta), address(moneta), 2 *WAD);

        // prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buyStep = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps[0] = buyStep;

        assets[0] = IAsset(address(dai));
        assets[1] = IAsset(address(fiat));
        
        limits[0] = int256(totalUnderlier - upfrontUnderlier + fee); // max DAI In
        limits[1] = -int256(lendFIAT); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(fyDAI2212Vault),
            fyDAI2212Vault.token(),
            address(user),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits)
        );

        assertGt(dai.balanceOf(address(user)), userInitialBalance - fee);
        assertEq(ERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);
    }

    function test_underlierToFYToken() external {
        uint256 fyTokenAmountNow = leverActions.underlierToFYToken(100 * ONE_USDC, address(fyUSDC2212LP));
        assertGt(fyTokenAmountNow, 0);
        // advance some months
        vm.warp(block.timestamp + 10 days);
        uint256 fyTokenAmountBeforeMaturity = leverActions.underlierToFYToken(100 * ONE_USDC, address(fyUSDC2212LP));
        // closest to the maturity we get less sPT for same underlier amount
        assertGt(fyTokenAmountNow, fyTokenAmountBeforeMaturity);

    }

    function test_fyTokenToUnderlier() external {
        uint256 underlierNow = leverActions.fyTokenToUnderlier(100 * ONE_USDC, address(fyUSDC2212LP));
        assertGt(underlierNow, 0);

        // advance some months
        vm.warp(block.timestamp + 10 days);
        uint256 underlierBeforeMaturity = leverActions.fyTokenToUnderlier(100 * ONE_USDC, address(fyUSDC2212LP));
        // closest to the maturity we get more underlier for same sPT
        assertGt(underlierBeforeMaturity, underlierNow);
    }

    function test_fiatForUnderlier() public {
        uint256 fiatOut = 500 * WAD;

        // prepare arguments for preview method, ordered from underlier to FIAT
        bytes32[] memory pathPoolIds = new bytes32[](2);
        
        pathPoolIds[0] = bbausdPoolId;
        pathPoolIds[1] = fiatPoolId;

        address[] memory pathAssetsIn = new address[](2);
        pathAssetsIn[0] = address(usdc); // USDC to DAI
        pathAssetsIn[1] = address(dai); // DAI to FIAT
        
        uint underlierIn = leverActions.fiatForUnderlier(pathPoolIds, pathAssetsIn, fiatOut);
        assertApproxEqAbs(underlierIn, wmul(fiatOut,fyUSDC2212Vault.tokenScale()), 2 * ONE_USDC);

        uint fiatIn = fiatOut;
        
        pathPoolIds[0] = fiatPoolId; // FIAT : USDC pool
        pathPoolIds[1] = bbausdPoolId; // USDC : DAI pool
        
        address[] memory pathAssetsOut = new address[](2);
        pathAssetsOut[0] = address(dai); // FIAT to DAI
        pathAssetsOut[1] = address(usdc); // DAI to USDC
        
        assertApproxEqAbs(underlierIn, leverActions.fiatToUnderlier(pathPoolIds, pathAssetsOut, fiatIn), 2 * ONE_USDC);
    }

    function test_fiatToUnderlier() public {
        uint256 fiatIn = 500 * WAD;
        
        // prepare arguments for preview method, ordered from FIAT to underlier
        bytes32[] memory pathPoolIds = new bytes32[](2);
        pathPoolIds[0] = fiatPoolId; // FIAT : USDC pool
        pathPoolIds[1] = bbausdPoolId; // USDC : DAI pool
        
        address[] memory pathAssetsOut = new address[](2);
        pathAssetsOut[0] = address(dai); // FIAT to DAI
        pathAssetsOut[1] = address(usdc); // DAI to USDC

        uint underlierOut = leverActions.fiatToUnderlier(pathPoolIds, pathAssetsOut, fiatIn);
        assertApproxEqAbs(underlierOut, wmul(fiatIn,fyUSDC2212Vault.tokenScale()), 2 * ONE_USDC);
        
        uint256 fiatOut = fiatIn;

        pathPoolIds[0] = bbausdPoolId; // DAI : USDC pool
        pathPoolIds[1] = fiatPoolId; // USDC : FIAT pool

        address[] memory pathAssetsIn = new address[](2);
        pathAssetsIn[0] = address(usdc); // USDC TO DAI
        pathAssetsIn[1] = address(dai); // DAI TO FIAT
        

        assertApproxEqAbs(underlierOut, leverActions.fiatForUnderlier(pathPoolIds, pathAssetsIn, fiatOut), 2 * ONE_USDC);
    }
}
