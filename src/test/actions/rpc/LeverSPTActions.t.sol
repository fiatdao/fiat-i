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
import {Flash} from "../../../core/Flash.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {toInt256, WAD, wdiv} from "../../../core/utils/Math.sol";

import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {VaultEPT} from "../../../vaults/VaultEPT.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";

import {Caller} from "../../../test/utils/Caller.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";
import {VaultSPT} from "../../../vaults/VaultSPT.sol";
import {VaultSPTActions} from "../../../actions/vault/VaultSPTActions.sol";
import {LeverSPTActions} from "../../../actions/lever/LeverSPTActions.sol";
import {IBalancerVault, IAsset} from "../../../actions/helper/ConvergentCurvePoolHelper.sol";

import {IVault} from "../../../interfaces/IVault.sol";

interface IPeriphery {
    function swapUnderlyingForPTs(
        address adapter,
        uint256 maturity,
        uint256 uBal,
        uint256 minAccepted
    ) external returns (uint256 ptBal);

    function swapPTsForUnderlying(
        address adapter,
        uint256 maturity,
        uint256 ptBal,
        uint256 minAccepted
    ) external returns (uint256 uBal);

    function divider() external view returns (address divider);
}

interface IAdapter {
    function unwrapTarget(uint256 amount) external returns (uint256);
}

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

    PRBProxy internal userProxy;
    PRBProxyFactory internal prbProxyFactory;
    
    VaultSPTActions internal vaultActions;
    VaultFactory internal vaultFactory;
    VaultSPT internal impl;
    
    FIAT internal fiat;
    Collybus internal collybus;
    Publican internal publican;

    Caller internal user;
    address internal me = address(this);

    IPeriphery internal periphery;
    IDivider internal divider;

    address internal balancerVault;

    IERC20 internal usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 internal dai;
    IERC20 internal maDAI;
    IERC20 internal sP_maDAI;
    IVault internal maDAIVault;
    address internal maDAISpace;
    address internal maDAIAdapter;

    uint256 internal maturity = 1688169600; // morpho maturity 1st July 2023

    Flash internal flash;

    LeverSPTActions internal leverActions;

    bytes32 internal fiatPoolId = 0x178e029173417b1f9c8bc16dcec6f697bc32374600000000000000000000025d;
    address internal fiatBalancerVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);
    
    // Batch swaps
    IBalancerVault.BatchSwapStep[] internal swaps;
    IAsset[] internal assets;
    int[] internal limits;

    bytes32[] internal pathPoolIds; 
    address[] internal pathAssetsOut; 
    address[] internal pathAssetsIn;

    function _mintDAI(address to, uint256 amount) internal {
        vm.store(address(dai), keccak256(abi.encode(address(address(this)), uint256(0))), bytes32(uint256(1)));
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(dai).call(abi.encodeWithSignature(sig, to, amount));
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
        IBalancerVault.BatchSwapStep[] memory _swaps, IAsset[] memory _assets, int[] memory _limits
    )
        internal
        view
        returns (LeverSPTActions.SellFIATSwapParams memory fiatSwapParams)
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
        returns (LeverSPTActions.BuyFIATSwapParams memory fiatSwapParams)
    {
       fiatSwapParams.swaps = _swaps;
       fiatSwapParams.assets = _assets;
       fiatSwapParams.limits = _limits;
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
        redeemParams.approveTarget = type(uint256).max;
    }

    function setUp() public {
        // Fork
        vm.createSelectFork(vm.rpcUrl("mainnet"), 15855705); // 29 October 2022

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

        periphery = IPeriphery(address(0xFff11417a58781D3C72083CB45EF54d79Cd02437)); //  Sense Finance Periphery
        assertEq(periphery.divider(), address(0x86bA3E96Be68563E41c2f5769F1AF9fAf758e6E0)); // sanity check
        divider = IDivider(periphery.divider()); // Sense Finance Divider


        dai = IERC20(address(0x6B175474E89094C44Da98b954EedeAC495271d0F)); // dai
        maDAI = IERC20(address(0x36F8d0D0573ae92326827C4a82Fe4CE4C244cAb6)); // Morpho maDAI (target)
        sP_maDAI = IERC20(address(0x0427a3A0De8c4B3dB69Dd7FdD6A90689117C3589)); // Sense Finance maDAI Principal Token
        maDAIAdapter = address(0x9887e67AaB4388eA4cf173B010dF5c92B91f55B5); // Sense Finance maDAI adapter
        maDAISpace = address(0x67F8db40638D8e06Ac78E1D04a805F59d11aDf9b); // Sense Bal V2 pool for maDAI/sP_maDAI

        balancerVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

        impl = new VaultSPT(address(codex), address(maDAI), address(dai));
        maDAIVault = IVault(
            vaultFactory.createVault(
                address(impl),
                abi.encode(block.timestamp + 8 weeks, address(sP_maDAI), address(collybus))
            )
        );

        vaultActions = new VaultSPTActions(
            address(codex),
            address(moneta),
            address(fiat),
            address(publican),
            address(periphery),
            periphery.divider()
        );

        // set Vault
        codex.init(address(maDAIVault));
        codex.allowCaller(codex.transferCredit.selector, address(moneta));
        codex.setParam("globalDebtCeiling", 10000000 ether);
        codex.setParam(address(maDAIVault), "debtCeiling", 1000000 ether);
        collybus.setParam(address(maDAIVault), "liquidationRatio",1 ether);
        collybus.updateSpot(address(dai), 1 ether);
        publican.init(address(maDAIVault));
        codex.allowCaller(codex.modifyBalance.selector, address(maDAIVault));

        // get test USDC
        user = new Caller();
        _mintDAI(address(user), 10000 ether);
        _mintDAI(me, 10000 ether);

        flash = new Flash(address(moneta));
        fiat.allowCaller(fiat.mint.selector, address(moneta));
        flash.setParam("max", 1000000 * WAD);

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

        codex.setParam("globalDebtCeiling", uint256(10000000 ether));
        codex.allowCaller(keccak256("ANY_SIG"), address(publican));
        codex.allowCaller(keccak256("ANY_SIG"), address(flash));

        IERC20(address(dai)).approve(address(userProxy), type(uint256).max);
        IERC20(address(sP_maDAI)).approve(address(userProxy), type(uint256).max);
        IERC20(address(maDAI)).approve(address(userProxy), type(uint256).max);

        fiat.approve(address(userProxy), type(uint256).max);

        user.externalCall(
            address(dai),
            abi.encodeWithSelector(dai.approve.selector, address(userProxy), type(uint256).max)
        );
    }

    function test_buyCollateralAndIncreaseLever_simple() public {
        uint256 lendFIAT = 1000 * WAD;
        uint256 upfrontUnderlier = 1000 * WAD;
        uint256 totalUnderlier = 2000 * WAD;
        uint256 fee = 50 * WAD;

        // Prepare sell FIAT params
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);
        
        pathAssetsOut.push(address(usdc));
        pathAssetsOut.push(address(dai));
        pathAssetsOut.push(address(usdc));
        pathAssetsOut.push(address(dai));
      
        uint256 minUnderliersOut = totalUnderlier-upfrontUnderlier-fee;
        uint256 deadline = block.timestamp + 10 days;

        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline), 
            // swap all for pTokens
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertGe(_collateral(address(maDAIVault), address(userProxy)), 2000 * WAD);
        assertGe(_normalDebt(address(maDAIVault), address(userProxy)), 1000 * WAD);
    }

    function test_buyCollateralAndIncreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(address(sP_maDAI)).balanceOf(address(maDAIVault));
        uint256 initialCollateral = _collateral(address(maDAIVault), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(maDAISpace),
            balancerVault,
            totalUnderlier
        );

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));

        limits.push(int(lendFIAT));  // max FIAT amount in 
        limits.push(-int(totalUnderlier-upfrontUnderlier-fee)); // min DAI out after fees

        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits), 
             // swap all for pTokens
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertEq(dai.balanceOf(me), meInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(sP_maDAI)).balanceOf(address(maDAIVault)),
            vaultInitialBalance + (estDeltaCollateral - 10 ether) // subtract fees
        );
        assertGe(
            _collateral(address(maDAIVault), address(userProxy)),
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
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(maDAIVault));
        uint256 initialCollateral = _collateral(address(maDAIVault), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(maDAISpace),
            balancerVault,
            totalUnderlier
        );

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));

        limits.push(int(lendFIAT)); // Limit In set in the contracts as exactAmountIn
        limits.push(int(totalUnderlier-upfrontUnderlier-fee)); // min DAI out after fees

        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
             // swap all for pTokens
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertEq(dai.balanceOf(address(user)), userInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(sP_maDAI)).balanceOf(address(maDAIVault)),
            vaultInitialBalance + (estDeltaCollateral - 5 ether) // subtract fees
        );
        assertGe(
            _collateral(address(maDAIVault), address(userProxy)),
            initialCollateral + wdiv(estDeltaCollateral, 5 ether) - WAD // subtract fees
        );
    }

    function test_buyCollateralAndIncreaseLever_for_zero_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(maDAIVault));
        uint256 initialCollateral = _collateral(address(maDAIVault), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(maDAISpace),
            balancerVault,
            totalUnderlier
        );

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));

        limits.push(int(lendFIAT)); // Limit In set in the contracts as exactAmountIn
        limits.push(int(totalUnderlier-upfrontUnderlier-fee)); // min DAI out after fees

        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            // swap all for pTokens
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertEq(dai.balanceOf(address(userProxy)), userProxyInitialBalance - upfrontUnderlier);
        assertGe(
            IERC20(address(sP_maDAI)).balanceOf(address(maDAIVault)),
            vaultInitialBalance + (estDeltaCollateral - 5 ether)
        );
        assertGe(
            _collateral(address(maDAIVault), address(userProxy)), // subtract fees
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
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(maDAIVault));
        uint256 initialCollateral = _collateral(address(maDAIVault), address(userProxy));

        uint256 estDeltaCollateral = leverActions.underlierToPToken(
            address(maDAISpace),
            balancerVault,
            totalUnderlier
        );

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));

        limits.push(int(lendFIAT)); // Limit In set in the contracts as exactAmountIn
        limits.push(int(totalUnderlier-upfrontUnderlier-fee)); // min DAI out after fees

        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            // swap all for pTokens
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertEq(dai.balanceOf(address(userProxy)), userProxyInitialBalance - upfrontUnderlier);
        assertGe(
            IERC20(address(sP_maDAI)).balanceOf(address(maDAIVault)),
            vaultInitialBalance + (estDeltaCollateral - 5 ether)
        );
        assertGe(
            _collateral(address(maDAIVault), address(userProxy)), // subtract fees
            initialCollateral + wdiv(estDeltaCollateral, 5 ether) - WAD // subtract fees
        );
    }

    function test_sellCollateralAndDecreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;

        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(maDAIVault));
        uint256 initialCollateral = _collateral(address(maDAIVault), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));

        limits.push(int(lendFIAT)); // Limit In set in the contracts as exactAmountIn
        limits.push(int(totalUnderlier-upfrontUnderlier-fee)); // min DAI out after fees
        
        assertEq(usdc.balanceOf(address(leverActions)), 0);

        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        delete swaps;
        delete assets;
        delete limits;

        uint256 pTokenAmount = _collateral(address(maDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(maDAIVault), address(userProxy));

        // Prepare buy FIAT params
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);
        
        pathAssetsIn.push(address(dai));
        pathAssetsIn.push(address(usdc));
        pathAssetsIn.push(address(dai));
        pathAssetsIn.push(address(usdc));
      
        uint maxUnderliersIn = totalUnderlier - upfrontUnderlier+fee; // max DAI In
        uint deadline = block.timestamp + 10 days;
        
        _sellCollateralAndDecreaseLever(
            address(maDAIVault),
            me,
            pTokenAmount,
            normalDebt,
            leverActions.buildBuyFIATSwapParams(pathPoolIds, pathAssetsIn, maxUnderliersIn, deadline),
            _getCollateralSwapParams(address(sP_maDAI), address(dai), address(maDAIAdapter), type(uint256).max, 0)
        );
        assertEq(usdc.balanceOf(address(leverActions)), 0);
        assertGt(dai.balanceOf(me), meInitialBalance - 15 ether); // subtract fees / rounding errors
        assertEq(IERC20(address(sP_maDAI)).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = dai.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(maDAIVault));
        uint256 initialCollateral = _collateral(address(maDAIVault), address(userProxy));
        
        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));

        limits.push(int(lendFIAT)); // Limit In set in the contracts as exactAmountIn
        limits.push(int(totalUnderlier-upfrontUnderlier-fee)); // min DAI out after fees

        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        delete swaps;
        delete assets;
        delete limits;

        uint256 pTokenAmount = _collateral(address(maDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(maDAIVault), address(userProxy));

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(dai)));
        assets.push(IAsset(address(fiat)));
        
        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max DAI In
        limits.push(-int(lendFIAT)); // limit set as exact amount out

        _sellCollateralAndDecreaseLever(
            address(maDAIVault),
            address(user),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(sP_maDAI), address(dai), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertGt(dai.balanceOf(address(user)), userInitialBalance - 5 ether); // subtract fees / rounding errors
        assertEq(IERC20(sP_maDAI).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);
    }

    function test_update_rate_and_sellCollateralAndDecreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = dai.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(maDAIVault));
        uint256 initialCollateral = _collateral(address(maDAIVault), address(userProxy));
        
        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));

        limits.push(int(lendFIAT)); // Limit In set in the contracts as exactAmountIn
        limits.push(int(totalUnderlier-upfrontUnderlier-fee)); // min DAI out after fees

        publican.setParam(address(maDAIVault), "interestPerSecond", 1.000000000790000 ether);
        publican.collect(address(maDAIVault));

        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        delete swaps;
        delete assets;
        delete limits;

        uint256 pTokenAmount = _collateral(address(maDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(maDAIVault), address(userProxy));

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(dai)));
        assets.push(IAsset(address(fiat)));
        
        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max DAI In
        limits.push(-int(lendFIAT)); // limit set as exact amount out

        vm.warp(block.timestamp+ 40 days);
        publican.collect(address(maDAIVault));
        codex.createUnbackedDebt(address(moneta), address(moneta), 2 *WAD);

        _sellCollateralAndDecreaseLever(
            address(maDAIVault),
            address(user),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(sP_maDAI), address(dai), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertGt(dai.balanceOf(address(user)), userInitialBalance - 5 ether); // subtract fees / rounding errors
        assertEq(IERC20(sP_maDAI).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_zero_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(maDAIVault));
        uint256 initialCollateral = _collateral(address(maDAIVault), address(userProxy));

        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));

        limits.push(int(lendFIAT)); // Limit In set in the contracts as exactAmountIn
        limits.push(int(totalUnderlier-upfrontUnderlier-fee)); // min DAI out after fees
        
        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        delete swaps;
        delete assets;
        delete limits;

        uint256 pTokenAmount = _collateral(address(maDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(maDAIVault), address(userProxy));

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(dai)));
        assets.push(IAsset(address(fiat)));
        
        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max DAI In
        limits.push(-int(lendFIAT)); // limit set as exact amount out

        _sellCollateralAndDecreaseLever(
            address(maDAIVault),
            address(0),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(sP_maDAI), address(dai), address(maDAIAdapter), type(uint256).max, 0)
        );

        // subtract fees / rounding errors
        assertGt(dai.balanceOf(address(userProxy)), userProxyInitialBalance - 5 ether);
        assertEq(IERC20(address(sP_maDAI)).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);
    }

    function test_sellCollateralAndDecreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(maDAIVault));
        uint256 initialCollateral = _collateral(address(maDAIVault), address(userProxy));
        
        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));

        limits.push(int(lendFIAT)); // Limit In set in the contracts as exactAmountIn
        limits.push(int(totalUnderlier-upfrontUnderlier-fee)); // min DAI out after fees
        
        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        uint256 pTokenAmount = _collateral(address(maDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(maDAIVault), address(userProxy));
        
        delete swaps;
        delete assets;
        delete limits;

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(dai)));
        assets.push(IAsset(address(fiat)));
        
        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max DAI In
        limits.push(-int(lendFIAT)); // limit set as exact amount out

        _sellCollateralAndDecreaseLever(
            address(maDAIVault),
            address(userProxy),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(sP_maDAI), address(dai), address(maDAIAdapter), type(uint256).max, 0)
        );

        // subtract fees / rounding errors
        assertGt(dai.balanceOf(address(userProxy)), userProxyInitialBalance - 5 ether);
        assertEq(IERC20(address(sP_maDAI)).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(maDAIVault));
        uint256 initialCollateral = _collateral(address(maDAIVault), address(userProxy));
        
        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));

        limits.push(int(lendFIAT)); // Limit In set in the contracts as exactAmountIn
        limits.push(int(totalUnderlier-upfrontUnderlier-fee)); // min DAI out after fees
        
        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertLt(dai.balanceOf(me), meInitialBalance);
        assertGt(IERC20(sP_maDAI).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertGt(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = _collateral(address(maDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(maDAIVault), address(userProxy));

        // we now move AFTER maturity, settle serie and redeem
        // get Sponsor address
        IDivider.Series memory serie = divider.series(maDAIAdapter, maturity);
        address sponsor = serie.sponsor;

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        vm.prank(sponsor);
        divider.settleSeries(maDAIAdapter, maturity);

        delete swaps;
        delete assets;
        delete limits;

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(dai)));
        assets.push(IAsset(address(fiat)));
        
        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max DAI In
        limits.push(-int(lendFIAT)); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(maDAIVault),
            address(sP_maDAI),
            me,
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getRedeemParams(address(maDAIAdapter))
        );

        assertGt(dai.balanceOf(me), meInitialBalance);
        assertEq(IERC20(address(sP_maDAI)).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = dai.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(maDAIVault));
        uint256 initialCollateral = _collateral(address(maDAIVault), address(userProxy));
        
        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));

        limits.push(int(lendFIAT)); // Limit In set in the contracts as exactAmountIn
        limits.push(int(totalUnderlier-upfrontUnderlier-fee)); // min DAI out after fees
        
        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertLt(dai.balanceOf(address(user)), userInitialBalance);
        assertGt(IERC20(sP_maDAI).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertGt(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = _collateral(address(maDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(maDAIVault), address(userProxy));

        // we now move AFTER maturity, settle serie and redeem
        // get Sponsor address
        IDivider.Series memory serie = divider.series(maDAIAdapter, maturity);
        address sponsor = serie.sponsor;

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        vm.prank(sponsor);
        divider.settleSeries(maDAIAdapter, maturity);
        
        delete swaps;
        delete assets;
        delete limits;

                // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(dai)));
        assets.push(IAsset(address(fiat)));
        
        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max DAI In
        limits.push(-int(lendFIAT)); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(maDAIVault),
            address(sP_maDAI),
            address(user),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getRedeemParams(maDAIAdapter)
        );

        assertGt(dai.balanceOf(address(user)), userInitialBalance);
        assertEq(IERC20(address(sP_maDAI)).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_zero_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(maDAIVault));
        uint256 initialCollateral = _collateral(address(maDAIVault), address(userProxy));
        
        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));

        limits.push(int(lendFIAT)); // Limit In set in the contracts as exactAmountIn
        limits.push(int(totalUnderlier-upfrontUnderlier-fee)); // min DAI out after fees
        
        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertLt(dai.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertGt(IERC20(address(sP_maDAI)).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertGt(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = _collateral(address(maDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(maDAIVault), address(userProxy));

        IDivider.Series memory serie = divider.series(maDAIAdapter, maturity);
        address sponsor = serie.sponsor;

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        vm.prank(sponsor);
        divider.settleSeries(maDAIAdapter, maturity);

        delete swaps;
        delete assets;
        delete limits;

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(dai)));
        assets.push(IAsset(address(fiat)));
        
        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max DAI In
        limits.push(-int(lendFIAT)); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(maDAIVault),
            address(sP_maDAI),
            address(0),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getRedeemParams(maDAIAdapter)
        );

        assertGt(dai.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertEq(IERC20(sP_maDAI).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        uint256 fee = 5 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(maDAIVault));
        uint256 initialCollateral = _collateral(address(maDAIVault), address(userProxy));
        
        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));

        limits.push(int(lendFIAT)); // Limit In set in the contracts as exactAmountIn
        limits.push(int(totalUnderlier-upfrontUnderlier-fee)); // min DAI out after fees
        
        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertLt(dai.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertGt(IERC20(sP_maDAI).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertGt(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = _collateral(address(maDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(maDAIVault), address(userProxy));

        IDivider.Series memory serie = divider.series(maDAIAdapter, maturity);
        address sponsor = serie.sponsor;

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        vm.prank(sponsor);
        divider.settleSeries(maDAIAdapter, maturity);

        delete swaps;
        delete assets;
        delete limits;
        
        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(dai)));
        assets.push(IAsset(address(fiat)));
        
        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max DAI In
        limits.push(-int(lendFIAT)); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(maDAIVault),
            maDAIVault.token(),
            address(userProxy),
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getRedeemParams(maDAIAdapter)
        );

        assertGt(dai.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertEq(IERC20(address(sP_maDAI)).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);
    }

    function test_update_rate_and_redeemCollateralAndDecreaseLever() public {
        
        uint256 lendFIAT = 100 * WAD;
        uint256 upfrontUnderlier = 600 * WAD;
        uint256 totalUnderlier = 700 * WAD;
        uint256 fee = 5 * WAD;
        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(sP_maDAI).balanceOf(address(maDAIVault));
        uint256 initialCollateral = _collateral(address(maDAIVault), address(userProxy));
        // Prepare sell FIAT params
        IBalancerVault.BatchSwapStep memory step = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(step);

        assets.push(IAsset(address(fiat)));
        assets.push(IAsset(address(dai)));

        limits.push(int(lendFIAT)); // Limit In set in the contracts as exactAmountIn
        limits.push(int(totalUnderlier-upfrontUnderlier-fee)); // min DAI out after fees

        publican.setParam(address(maDAIVault), "interestPerSecond", 1.000000000790000 ether);
        publican.collect(address(maDAIVault));
        
        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(swaps, assets, limits),
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertLt(dai.balanceOf(me), meInitialBalance);
        assertGt(IERC20(sP_maDAI).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertGt(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);

        uint256 pTokenAmount = _collateral(address(maDAIVault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(maDAIVault), address(userProxy));
 
        // we now move AFTER maturity, settle serie and redeem
        // get Sponsor address
        IDivider.Series memory serie = divider.series(maDAIAdapter, maturity);
        address sponsor = serie.sponsor;
        
        // Move post maturity
        vm.warp(maturity + 1);

        publican.collect(address(maDAIVault));
        codex.createUnbackedDebt(address(moneta), address(moneta), 2 *WAD);

        // Settle serie from sponsor
        vm.prank(sponsor);
        divider.settleSeries(maDAIAdapter, maturity);

        delete swaps;
        delete assets;
        delete limits;

        // Prepare buy FIAT params
        IBalancerVault.BatchSwapStep memory buy = IBalancerVault.BatchSwapStep(fiatPoolId, 0, 1, 0, new bytes(0));
        swaps.push(buy);

        assets.push(IAsset(address(dai)));
        assets.push(IAsset(address(fiat)));
        
        limits.push(int(totalUnderlier-upfrontUnderlier+fee)); // max DAI In
        limits.push(-int(lendFIAT)); // limit set as exact amount out

        _redeemCollateralAndDecreaseLever(
            address(maDAIVault),
            address(sP_maDAI),
            me,
            pTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(swaps, assets, limits),
            _getRedeemParams(address(maDAIAdapter))
        );

        assertGt(dai.balanceOf(me), meInitialBalance);
        assertEq(IERC20(address(sP_maDAI)).balanceOf(address(maDAIVault)), vaultInitialBalance);
        assertEq(_collateral(address(maDAIVault), address(userProxy)), initialCollateral);
    }

    function test_underlierToPToken() external {
        uint256 pTokenAmountNow = leverActions.underlierToPToken(address(maDAISpace), balancerVault, 100 ether);
        assertGt(pTokenAmountNow, 0);
        // advance some months
        vm.warp(block.timestamp + 180 days);
        uint256 pTokenAmountBeforeMaturity = leverActions.underlierToPToken(
            address(maDAISpace), balancerVault, 100 ether
        );
        // closest to the maturity we get less sPT for same underlier amount
        assertGt(pTokenAmountNow, pTokenAmountBeforeMaturity);

        // go to maturity
        vm.warp(maturity);
        uint256 pTokenAmountAtMaturity = leverActions.underlierToPToken(
            address(maDAISpace), balancerVault, 100 ether
        );
        // at maturity we get even less pT
        assertGt(pTokenAmountBeforeMaturity, pTokenAmountAtMaturity);

        vm.warp(maturity + 24 days);
        uint256 pTokenAmountAfterMaturity = leverActions.underlierToPToken(
            address(maDAISpace), balancerVault, 100 ether
        );
        // same after maturity
        assertEq(pTokenAmountAtMaturity, pTokenAmountAfterMaturity);
        assertGt(pTokenAmountBeforeMaturity, pTokenAmountAfterMaturity);
    }

    function test_pTokenToUnderlier() external {
        uint256 underlierNow = leverActions.pTokenToUnderlier(address(maDAISpace), balancerVault, 100 ether);
        assertGt(underlierNow, 0);

        // advance some months
        vm.warp(block.timestamp + 90 days);
        uint256 underlierBeforeMaturity = leverActions.pTokenToUnderlier(address(maDAISpace), balancerVault, 100 ether);
        // closest to the maturity we get more underlier for same sPT
        assertGt(underlierBeforeMaturity, underlierNow);

        // go to maturity
        vm.warp(maturity);

        uint256 underlierAtMaturity = leverActions.pTokenToUnderlier(address(maDAISpace), balancerVault, 100 ether);

        // at maturity we get even more underlier but we would redeem instead
        assertGt(underlierAtMaturity, underlierBeforeMaturity);

        // same after maturity
        vm.warp(maturity + 10 days);
        uint256 underlierAfterMaturity = leverActions.pTokenToUnderlier(address(maDAISpace), balancerVault, 100 ether);
        assertEq(underlierAtMaturity, underlierAfterMaturity);
    }

    function test_fiatForUnderlier() public {
        uint256 fiatOut = 500 * WAD;

        // Prepare arguments for preview method
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);

        pathAssetsIn.push(address(dai));
        pathAssetsIn.push(address(usdc));
        
        uint underlierIn = leverActions.fiatForUnderlier(pathPoolIds, pathAssetsIn, fiatOut);

        uint fiatIn = fiatOut;
        
        pathAssetsOut.push(address(usdc));
        pathAssetsOut.push(address(dai));

        assertApproxEqAbs(underlierIn, fiatOut, 4 * WAD);
        assertApproxEqAbs(underlierIn, leverActions.fiatToUnderlier(pathPoolIds, pathAssetsOut, fiatIn), 4 ether);
    }

    function test_fiatToUnderlier() public {
        uint256 fiatIn = 500 * WAD;
        
        // Prepare arguments for preview method
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);

        pathAssetsOut.push(address(usdc));
        pathAssetsOut.push(address(dai));

        uint underlierOut = leverActions.fiatToUnderlier(pathPoolIds, pathAssetsOut, fiatIn);

        uint256 fiatOut = fiatIn;
        
        pathAssetsIn.push(address(dai));
        pathAssetsIn.push(address(usdc));

        assertApproxEqAbs(underlierOut, fiatIn, 5 * WAD);
        assertApproxEqAbs(underlierOut, leverActions.fiatForUnderlier(pathPoolIds, pathAssetsIn, fiatOut), 0.22 ether);
    }

    function testFail_buyCollateralAndIncreaseLever_with_ZERO_upfrontUnderlier_without_a_position() public {
        collybus.setParam(address(maDAIVault), "liquidationRatio",1.03 ether);
        uint256 lendFIAT = 1000 * WAD;
        uint256 upfrontUnderlier = 0 * WAD;
        uint256 totalUnderlier = 1000 * WAD;
        uint256 fee = 10 * WAD;

        // Prepare sell FIAT params
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);
        
        pathAssetsOut.push(address(usdc));
        pathAssetsOut.push(address(dai));
        pathAssetsOut.push(address(usdc));
        pathAssetsOut.push(address(dai));
      
        uint256 minUnderliersOut = totalUnderlier-upfrontUnderlier-fee;
        uint256 deadline = block.timestamp + 10 days;

        assertEq(_collateral(address(maDAIVault), address(userProxy)), 0);
        assertEq(_normalDebt(address(maDAIVault), address(userProxy)), 0);

        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline), 
            // swap all for pTokens
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertGe(_collateral(address(maDAIVault), address(userProxy)), 1000 * WAD);
        assertGe(_normalDebt(address(maDAIVault), address(userProxy)), 1000 * WAD);
    }

    function test_buyCollateralAndIncreaseLever_with_ZERO_upfrontUnderlier() public {
        collybus.setParam(address(maDAIVault), "liquidationRatio",1.03 ether);
        
        // First we need to open a position
        uint256 amount = 100 * WAD;
        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = sP_maDAI.balanceOf(address(maDAIVault));
        assertEq(_collateral(address(maDAIVault), address(userProxy)),0);
        uint256 previewOut = vaultActions.underlierToPToken(maDAISpace, balancerVault, amount);

        _buyCollateralAndModifyDebt(
            address(maDAIVault),
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
        assertTrue(sP_maDAI.balanceOf(address(maDAIVault)) >= previewOut + vaultInitialBalance);
        assertTrue(
            _collateral(address(maDAIVault), address(userProxy)) >=
                 wdiv(previewOut, 10**IERC20Metadata(address(sP_maDAI)).decimals())
        );

        uint256 lendFIAT = 1000 * WAD;
        uint256 upfrontUnderlier = 0 * WAD;
        uint256 totalUnderlier = 1000 * WAD;
        uint256 fee = 10 * WAD;

        // Prepare sell FIAT params
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);
        pathPoolIds.push(fiatPoolId);
        
        pathAssetsOut.push(address(usdc));
        pathAssetsOut.push(address(dai));
        pathAssetsOut.push(address(usdc));
        pathAssetsOut.push(address(dai));
      
        uint256 minUnderliersOut = totalUnderlier-upfrontUnderlier-fee;
        uint256 deadline = block.timestamp + 10 days;

        assertGt(_collateral(address(maDAIVault), address(userProxy)), 0);
        assertEq(_normalDebt(address(maDAIVault), address(userProxy)), 0);

        // Now we can leverage it
        _buyCollateralAndIncreaseLever(
            address(maDAIVault),
            me,
            upfrontUnderlier,
            lendFIAT,
            leverActions.buildSellFIATSwapParams(pathPoolIds, pathAssetsOut, minUnderliersOut, deadline), 
            // swap all for pTokens
            _getCollateralSwapParams(address(dai), address(sP_maDAI), address(maDAIAdapter), type(uint256).max, 0)
        );

        assertGe(_collateral(address(maDAIVault), address(userProxy)), 1000 * WAD);
        assertGe(_normalDebt(address(maDAIVault), address(userProxy)), 1000 * WAD);
    }
}
