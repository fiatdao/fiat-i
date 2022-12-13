// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "openzeppelin/contracts/interfaces/IERC4626.sol";

import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {Collybus} from "../../../core/Collybus.sol";
import {Codex} from "../../../core/Codex.sol";
import {Publican} from "../../../core/Publican.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {WAD, toInt256, wmul, wdiv, sub, add} from "../../../core/utils/Math.sol";
import {Publican} from "../../../core/Publican.sol";
import {IVault} from "../../../interfaces/IVault.sol";

import {VaultFactory} from "../../../vaults/VaultFactory.sol";
import {VaultSPT} from "../../../vaults/VaultSPT.sol";

import {VaultSPTActions} from "../../../actions/vault/VaultSPTActions.sol";
import {IBalancerVault, IConvergentCurvePool} from "../../../actions/helper/ConvergentCurvePoolHelper.sol";

import {Caller} from "../../../test/utils/Caller.sol";

interface IAdapter {
    function unwrapTarget(uint256 amount) external returns (uint256);
}

interface IDivider {
    function redeem(
        address adapter,
        uint256 maturity,
        uint256 uBal
    ) external returns (uint256 tBal);

    function series(address adapter, uint256 maturitu) external returns (Series memory);

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

interface ISenseSpace {
    function getFairBPTPrice(uint256 ptTwapDuration) external view returns (uint256 fairBptPriceInTarget);
}

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

contract VaultSPTActions_RPC_tests is Test {
    Codex internal codex;
    Moneta internal moneta;
    PRBProxy internal userProxy;
    PRBProxyFactory internal prbProxyFactory;
    VaultSPTActions internal vaultActions;
    IVault internal maDAIVault;
    VaultFactory internal vaultFactory;
    VaultSPT internal impl;
    FIAT internal fiat;
    Collybus internal collybus;
    Publican internal publican;

    Caller internal user;
    address internal me = address(this);

    IPeriphery internal periphery;
    IDivider internal divider;
    address internal maDAIAdapter;
    address internal balancerVault;

    IERC20 internal dai;
    IERC20 internal maDAI;
    IERC20 internal sP_maDAI;
    ISenseSpace internal maDAISpace;

    uint256 internal maturity = 1688169600; // morpho maturity 1st July 2023

    uint256 internal defaultUnderlierAmount = 100 ether; 

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

    function _sellCollateralAndModifyDebt(
        address vault,
        address collateralizer,
        address creditor,
        uint256 pTokenAmount,
        int256 deltaNormalDebt,
        VaultSPTActions.SwapParams memory swapParams
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
        address token,
        address collateralizer,
        address creditor,
        uint256 pTokenAmount,
        int256 deltaNormalDebt,
        VaultSPTActions.RedeemParams memory redeemParams
    ) internal {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.redeemCollateralAndModifyDebt.selector,
                vault,
                token,
                address(userProxy),
                collateralizer,
                creditor,
                pTokenAmount,
                deltaNormalDebt,
                redeemParams
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

    function _getRedeemParams(
        address adapter,
        uint256 _maturity,
        address target,
        address underlierToken,
        uint256 approveTarget
    ) internal pure returns (VaultSPTActions.RedeemParams memory) {
        return VaultSPTActions.RedeemParams(adapter, _maturity, target, underlierToken, approveTarget);
    }

    function setUp() public {
        // Fork
        vm.createSelectFork(vm.rpcUrl("mainnet"), 15855705); // 29 October 2022

        vaultFactory = new VaultFactory();
        fiat = new FIAT();
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
        maDAISpace = ISenseSpace(0x67F8db40638D8e06Ac78E1D04a805F59d11aDf9b); // Sense Bal V2 pool for maDAI/sP_maDAI

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
        codex.setParam("globalDebtCeiling", 1000 ether);
        codex.setParam(address(maDAIVault), "debtCeiling", 1000 ether);
        collybus.setParam(address(maDAIVault), "liquidationRatio", 1 ether);
        collybus.updateSpot(address(dai), 1 ether);
        publican.init(address(maDAIVault));
        codex.allowCaller(codex.modifyBalance.selector, address(maDAIVault));

        // get test dai
        user = new Caller();
        _mintDAI(address(user), defaultUnderlierAmount);
        _mintDAI(me, defaultUnderlierAmount);
    }

    function test_sense_periphery() public {
        // Approve periphery for dai
        dai.approve(address(periphery), type(uint256).max);

        // Swap underlier for sPT
        uint256 ptBal = periphery.swapUnderlyingForPTs(maDAIAdapter, maturity, defaultUnderlierAmount, 0);
        assertEq(sP_maDAI.balanceOf(me), ptBal);
        assertEq(dai.balanceOf(me), 0);

        // Approve periphery for sPT
        sP_maDAI.approve(address(periphery), type(uint256).max);

        // Swap sPT for dai (underlier)
        uint256 daiAmount = periphery.swapPTsForUnderlying(maDAIAdapter, maturity, ptBal, 0);
        assertEq(sP_maDAI.balanceOf(me), 0);
        assertEq(dai.balanceOf(me), daiAmount);
    }

    function test_buy_and_sell_CollateralAndModifyDebt_no_proxy() external {
        // Approve vaultActions for dai
        dai.approve(address(vaultActions), 100 ether);

        // Approve vaultActions for sPT
        sP_maDAI.approve(address(vaultActions), 100 ether);

        // Allow vaultActions as delegate
        codex.grantDelegate(address(vaultActions));

        VaultSPTActions.SwapParams memory swapParamsIn = _getSwapParams(
            maDAIAdapter,
            address(dai),
            address(sP_maDAI),
            0,
            maturity,
            defaultUnderlierAmount
        );

        // Buy sPT from dai and mint fiat
        int256 fiatAmount = 9 ether; // 9 fiat
        vaultActions.buyCollateralAndModifyDebt(
            address(maDAIVault),
            me,
            me,
            me,
            defaultUnderlierAmount,
            fiatAmount,
            swapParamsIn
        );

        assertEq(dai.balanceOf(me), 0);
        assertEq(fiat.balanceOf(me), uint256(fiatAmount));

        // sPT in the vault
        uint256 sPTBal = sP_maDAI.balanceOf(address(maDAIVault));

        // Approve moneta for FIAT from vaultActions
        vaultActions.approveFIAT(address(moneta), 100 ether);

        // Approve vaultActions for FIAT
        fiat.approve(address(vaultActions), 100 ether);

        VaultSPTActions.SwapParams memory swapParamsOut = _getSwapParams(
            maDAIAdapter,
            address(sP_maDAI),
            address(dai),
            0,
            maturity,
            sPTBal
        );

        assertEq(fiat.balanceOf(me), uint256(fiatAmount));
        assertEq(sP_maDAI.balanceOf(me), 0);

        uint256 daiBefore = dai.balanceOf(me);

        // Repay debt and get back underlying
        vaultActions.sellCollateralAndModifyDebt(address(maDAIVault), me, me, me, sPTBal, -fiatAmount, swapParamsOut);

        assertGt(dai.balanceOf(me), daiBefore);
        assertEq(fiat.balanceOf(me), 0);
        assertEq(sP_maDAI.balanceOf(me), 0);
    }

    function test_buy_and_sell_CollateralAndModifyDebt() external {
        // Approve moneta to burn FIAT from vaultActions for userProxy owner
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), 100 ether)
        );

        // Approve userProxy for dai
        dai.approve(address(userProxy), 100 ether);

        VaultSPTActions.SwapParams memory swapParamsIn = _getSwapParams(
            maDAIAdapter,
            address(dai),
            address(sP_maDAI),
            0,
            maturity,
            defaultUnderlierAmount
        );

        int256 fiatAmount = 9 ether; // 9 FIAT
        // Buy sPT from dai and mint FIAT
        _buyCollateralAndModifyDebt(address(maDAIVault), me, me, defaultUnderlierAmount, fiatAmount, swapParamsIn);

        assertEq(dai.balanceOf(me), 0);
        assertEq(fiat.balanceOf(me), uint256(fiatAmount));
        (uint256 collateral, uint256 normalDebt) = codex.positions(address(maDAIVault), 0, address(userProxy));

        // sPT in the vault
        uint256 sPTBal = sP_maDAI.balanceOf(address(maDAIVault));

        // Collateral corresponds to sPTBal scaled 
        assertEq(collateral, sPTBal);
        // Debt is fiat balance
        assertEq(normalDebt, fiat.balanceOf(me));

        // Approve userProxy for fiat
        fiat.approve(address(userProxy), 100 ether);

        // Params to exit from sPT to underlying asset
        VaultSPTActions.SwapParams memory swapParamsOut = _getSwapParams(
            maDAIAdapter,
            address(sP_maDAI),
            address(dai),
            0,
            maturity,
            sPTBal
        );

        assertEq(fiat.balanceOf(me), uint256(fiatAmount));
        assertEq(sP_maDAI.balanceOf(me), 0);

        uint256 daiBefore = dai.balanceOf(me);

        // Repay debt and get back underlying
        _sellCollateralAndModifyDebt(address(maDAIVault), me, me, sPTBal, -fiatAmount, swapParamsOut);

        assertGt(dai.balanceOf(me), daiBefore);
        assertGt(defaultUnderlierAmount, dai.balanceOf(me)); // we have a bit less
        assertEq(fiat.balanceOf(me), 0);
        assertEq(sP_maDAI.balanceOf(me), 0);
    }

    function test_buy_and_sell_CollateralAndModifyDebt_from_user() external {
        user.externalCall(
            address(fiat),
            abi.encodeWithSelector(fiat.approve.selector, address(userProxy), type(uint256).max)
        );
        user.externalCall(
            address(dai),
            abi.encodeWithSelector(dai.approve.selector, address(userProxy), type(uint256).max)
        );

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), type(uint256).max)
        );

        VaultSPTActions.SwapParams memory swapParamsIn = _getSwapParams(
            maDAIAdapter,
            address(dai),
            address(sP_maDAI),
            0,
            maturity,
            defaultUnderlierAmount
        );

        // Buy sPT from dai and mint fiat
        int256 fiatAmount = 9 ether; // 9 fiat

        _buyCollateralAndModifyDebt(
            address(maDAIVault),
            address(user),
            address(user),
            defaultUnderlierAmount,
            fiatAmount,
            swapParamsIn
        );

        assertEq(dai.balanceOf(address(user)), 0);
        assertEq(fiat.balanceOf(address(user)), uint256(fiatAmount));
        (uint256 collateral, uint256 normalDebt) = codex.positions(address(maDAIVault), 0, address(userProxy));

        // sPT in the vault
        uint256 sPTBal = sP_maDAI.balanceOf(address(maDAIVault));

        // Collateral corresponds to sPTBal scaled
        assertEq(collateral, sPTBal);
        // Debt is fiat balance
        assertEq(normalDebt, fiat.balanceOf(address(user)));

        // Params to exit from sPT to underlying asset
        VaultSPTActions.SwapParams memory swapParamsOut = _getSwapParams(
            maDAIAdapter,
            address(sP_maDAI),
            address(dai),
            0,
            maturity,
            sPTBal
        );

        assertEq(fiat.balanceOf(address(user)), uint256(fiatAmount));
        assertEq(sP_maDAI.balanceOf(address(user)), 0);

        uint256 daiBefore = dai.balanceOf(address(user));

        // Repay debt and get back underlying
        _sellCollateralAndModifyDebt(
            address(maDAIVault),
            address(user),
            address(user),
            sPTBal,
            -fiatAmount,
            swapParamsOut
        );

        assertGt(dai.balanceOf(address(user)), daiBefore);
        assertGt(defaultUnderlierAmount, dai.balanceOf(address(user))); // we have a bit less
        assertEq(fiat.balanceOf(address(user)), 0);
        assertEq(sP_maDAI.balanceOf(address(user)), 0);
    }

    function test_redeemCollateralAndModifyDebt_no_proxy() external {
        // Approve vaultActions for dai
        dai.approve(address(vaultActions), 100 ether);

        // Approve vaultActions for sPT
        sP_maDAI.approve(address(vaultActions), 100 ether);

        // Allow vaultActions as delegate
        codex.grantDelegate(address(vaultActions));

        VaultSPTActions.SwapParams memory swapParamsIn = _getSwapParams(
            maDAIAdapter,
            address(dai),
            address(sP_maDAI),
            0,
            maturity,
            defaultUnderlierAmount
        );

        // Buy sPT from dai and mint fiat
        int256 fiatAmount = 9 ether; // 9 fiat
        vaultActions.buyCollateralAndModifyDebt(
            address(maDAIVault),
            me,
            me,
            me,
            defaultUnderlierAmount,
            fiatAmount,
            swapParamsIn
        );
        // sPT in the vault
        uint256 sPTBal = sP_maDAI.balanceOf(address(maDAIVault));

        VaultSPTActions.RedeemParams memory redeemParams = _getRedeemParams(
            maDAIAdapter,
            maturity,
            address(maDAI),
            address(dai),
            type(uint256).max
        );

        // Approve moneta for fiat from vaultActions
        vaultActions.approveFIAT(address(moneta), 100 ether);

        sP_maDAI.approve(address(vaultActions), type(uint256).max);
        fiat.approve(address(vaultActions), type(uint256).max);

        // we now move AFTER maturity, settle serie and redeem
        // get Sponsor address
        IDivider.Series memory serie = divider.series(maDAIAdapter, maturity);
        address sponsor = serie.sponsor;

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        vm.prank(sponsor);
        divider.settleSeries(maDAIAdapter, maturity);

        // no dai, maDAI, sPT, only FIAT
        assertEq(fiat.balanceOf(me), uint256(fiatAmount));
        assertEq(dai.balanceOf(me), 0);
        assertEq(maDAI.balanceOf(me), 0);
        assertEq(sP_maDAI.balanceOf(me), 0);

        // Pay back fiat and redeem sPT for dai;
        vaultActions.redeemCollateralAndModifyDebt(
            address(maDAIVault),
            address(sP_maDAI),
            me,
            me,
            me,
            sPTBal,
            -fiatAmount,
            redeemParams
        );

        // no fiat, maDAI, sPT, only dai, which is now more than we had initially
        assertGt(dai.balanceOf(me), defaultUnderlierAmount);
        assertEq(fiat.balanceOf(me), 0);
        assertEq(maDAI.balanceOf(me), 0);
        assertEq(sP_maDAI.balanceOf(me), 0);
    }

    function test_redeemCollateralAndModifyDebt() external {
        // Approve userProxy for dai
        dai.approve(address(userProxy), 100 ether);

        sP_maDAI.approve(address(userProxy), 100 ether);

        VaultSPTActions.SwapParams memory swapParamsIn = _getSwapParams(
            maDAIAdapter,
            address(dai),
            address(sP_maDAI),
            0,
            maturity,
            defaultUnderlierAmount
        );

        // Buy sPT from dai and mint fiat
        int256 fiatAmount = 9 ether; // 9 fiat

        _buyCollateralAndModifyDebt(address(maDAIVault), me, me, defaultUnderlierAmount, fiatAmount, swapParamsIn);

        // sPT in the vault
        uint256 sPTBal = sP_maDAI.balanceOf(address(maDAIVault));

        VaultSPTActions.RedeemParams memory redeemParams = _getRedeemParams(
            maDAIAdapter,
            maturity,
            address(maDAI),
            address(dai),
            type(uint256).max
        );

        // Approve moneta to burn fiat from vaultActions for userProxy owner
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), 100 ether)
        );

        // Approve userProxy for fiat
        fiat.approve(address(userProxy), 100 ether);

        // we now move AFTER maturity, settle serie and redeem
        // get Sponsor address
        IDivider.Series memory serie = divider.series(maDAIAdapter, maturity);
        address sponsor = serie.sponsor;

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        vm.prank(sponsor);
        divider.settleSeries(maDAIAdapter, maturity);

        // no dai, maDAI, sPT, only FIAT
        assertEq(fiat.balanceOf(me), uint256(fiatAmount));
        assertEq(dai.balanceOf(me), 0);
        assertEq(maDAI.balanceOf(me), 0);
        assertEq(sP_maDAI.balanceOf(me), 0);

        // Pay back fiat and redeem sPT for dai;
        _redeemCollateralAndModifyDebt(
            address(maDAIVault),
            address(sP_maDAI),
            me,
            me,
            sPTBal,
            -fiatAmount,
            redeemParams
        );

        // no fiat, maDAI, sPT, only dai, which is now more than we had initially
        assertGt(dai.balanceOf(me), defaultUnderlierAmount);
        assertEq(fiat.balanceOf(me), 0);
        assertEq(maDAI.balanceOf(me), 0);
        assertEq(sP_maDAI.balanceOf(me), 0);
    }

    function test_redeemCollateralAndModifyDebt_from_user() external {
        vm.startPrank(address(user));
        fiat.approve(address(userProxy), type(uint256).max);
        dai.approve(address(userProxy), type(uint256).max);
        vm.stopPrank();

        VaultSPTActions.SwapParams memory swapParamsIn = _getSwapParams(
            maDAIAdapter,
            address(dai),
            address(sP_maDAI),
            0,
            maturity,
            defaultUnderlierAmount
        );

        // Buy sPT from dai and mint fiat
        int256 fiatAmount = 9 ether; // 9 fiat

        _buyCollateralAndModifyDebt(
            address(maDAIVault),
            address(user),
            address(user),
            defaultUnderlierAmount,
            fiatAmount,
            swapParamsIn
        );

        assertEq(dai.balanceOf(address(user)), 0);
        assertEq(fiat.balanceOf(address(user)), uint256(fiatAmount));

        // sPT in the vault
        uint256 sPTBal = sP_maDAI.balanceOf(address(maDAIVault));

        VaultSPTActions.RedeemParams memory redeemParams = _getRedeemParams(
            maDAIAdapter,
            maturity,
            address(maDAI),
            address(dai),
            type(uint256).max
        );

        // Approve moneta to burn fiat from vaultActions for userProxy owner
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), 100 ether)
        );

        // Approve userProxy for fiat
        fiat.approve(address(userProxy), 100 ether);

        // we now move AFTER maturity, settle serie and redeem
        // get Sponsor address
        IDivider.Series memory serie = divider.series(maDAIAdapter, maturity);
        address sponsor = serie.sponsor;

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        vm.prank(sponsor);
        divider.settleSeries(maDAIAdapter, maturity);

        // // no dai, maDAI, sPT, only FIAT
        assertEq(fiat.balanceOf(address(user)), uint256(fiatAmount));
        assertEq(dai.balanceOf(address(user)), 0);
        assertEq(maDAI.balanceOf(address(user)), 0);
        assertEq(sP_maDAI.balanceOf(address(user)), 0);

        // Pay back fiat and redeem sPT for dai;
        _redeemCollateralAndModifyDebt(
            address(maDAIVault),
            address(sP_maDAI),
            address(user),
            address(user),
            sPTBal,
            -fiatAmount,
            redeemParams
        );

        // no fiat, maDAI, sPT, only dai, which is now more than we had initially
        assertGt(dai.balanceOf(address(user)), defaultUnderlierAmount);
        assertEq(fiat.balanceOf(address(user)), 0);
        assertEq(maDAI.balanceOf(address(user)), 0);
        assertEq(sP_maDAI.balanceOf(address(user)), 0);
    }

    function test_underlierToPToken() external {
        uint256 pTokenAmountNow = vaultActions.underlierToPToken(address(maDAISpace), balancerVault, 100 ether);
        assertGt(pTokenAmountNow, 0);
        // advance some months
        vm.warp(block.timestamp + 180 days);
        uint256 pTokenAmountBeforeMaturity = vaultActions.underlierToPToken(address(maDAISpace), balancerVault, 100 ether);
        // closest to the maturity we get less sPT for same underlier amount
        assertGt(pTokenAmountNow, pTokenAmountBeforeMaturity);

        // go to maturity
        vm.warp(maturity);
        uint256 pTokenAmountAtMaturity = vaultActions.underlierToPToken(address(maDAISpace), balancerVault, 100 ether);
        // at maturity we get even less pT
        assertGt(pTokenAmountBeforeMaturity, pTokenAmountAtMaturity);

        vm.warp(maturity + 24 days);
        uint256 pTokenAmountAfterMaturity = vaultActions.underlierToPToken(address(maDAISpace), balancerVault, 100 ether);
        // same after maturity
        assertEq(pTokenAmountAtMaturity, pTokenAmountAfterMaturity);
        assertGt(pTokenAmountBeforeMaturity, pTokenAmountAfterMaturity);
    }

    function test_pTokenToUnderlier() external {
        uint256 underlierNow = vaultActions.pTokenToUnderlier(address(maDAISpace), balancerVault, 100 ether);
        assertGt(underlierNow, 0);

        // advance some months
        vm.warp(block.timestamp + 180 days);
        uint256 underlierBeforeMaturity = vaultActions.pTokenToUnderlier(address(maDAISpace), balancerVault, 100 ether);
        // closest to the maturity we get more underlier for same sPT
        assertGt(underlierBeforeMaturity, underlierNow);

        // go to maturity
        vm.warp(maturity);

        uint256 underlierAtMaturity = vaultActions.pTokenToUnderlier(address(maDAISpace), balancerVault, 100 ether);

        // at maturity we get even more underlier but we would redeem instead
        assertGt(underlierAtMaturity, underlierBeforeMaturity);

        // same after maturity
        vm.warp(maturity + 24 days);
        uint256 underlierAfterMaturity = vaultActions.pTokenToUnderlier(address(maDAISpace), balancerVault, 100 ether);
        assertEq(underlierAtMaturity, underlierAfterMaturity);
    }

    function test_maUSDC_different_decimals() external {
        // Morpho use 18 decimals for each vault token

        // Underlier amounts (different scale same value)
        uint256 usdcAmount = 10 * 1e6; // 10 dollars
        uint256 daiAmount = 10 ether; // 10 dollars

        // Morpho Aave USDC
        IERC4626 maUSDC = IERC4626(0xA5269A8e31B93Ff27B887B56720A25F844db0529);
        // Morpho Compound USDC
        IERC4626 mcUSDC = IERC4626(0xba9E3b3b684719F80657af1A19DEbc3C772494a0);

        // get mxUSDC amount and maDAI amount
        uint256 maUSDCAmount = maUSDC.previewDeposit(usdcAmount);
        uint256 mcUSDCAmount = mcUSDC.previewDeposit(usdcAmount);
        uint256 maDAIAmount = IERC4626(address(maDAI)).previewDeposit(daiAmount);

        // get decimals
        uint256 maUSDCDecimals = maUSDC.decimals();
        uint256 mcUSDCDecimals = mcUSDC.decimals();
        uint256 maDAIDecimals = IERC4626(address(maDAI)).decimals();

        // Target amounts returned are already scaled to 18
        assertApproxEqAbs(maUSDCAmount, mcUSDCAmount, 0.01 ether);
        assertApproxEqAbs(maDAIAmount, mcUSDCAmount, 0.01 ether);
        assertApproxEqAbs(maDAIAmount, maUSDCAmount, 0.01 ether);

        // all target amounts have 18 decimals
        assertEq(maUSDCDecimals, 18);
        assertEq(mcUSDCDecimals, 18);
        assertEq(maUSDCDecimals, maDAIDecimals);
    }
}
