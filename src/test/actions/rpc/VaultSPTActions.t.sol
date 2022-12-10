// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

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
import {TestERC20} from "../../../test/utils/TestERC20.sol";

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
    TestERC20 internal sensePT;
    PRBProxy internal userProxy;
    PRBProxyFactory internal prbProxyFactory;
    VaultSPTActions internal vaultActions;
    IVault internal vaultSenseUSDC;
    VaultFactory internal vaultFactory;
    VaultSPT internal impl;
    FIAT internal fiat;
    Collybus internal collybus;
    Publican internal publican;

    Caller internal user;
    address internal me = address(this);

    IPeriphery internal periphery;
    IDivider internal divider;
    address internal cUSDCAdapter;
    address internal balancerVault;

    IERC20 internal usdc;
    IERC20 internal cUSDC;
    IERC20 internal sP_cUSDC;

    uint256 internal maturity = 1656633600; // 1st July 2022

    uint256 internal ONE_USDC = 1e6;
    uint256 internal defaultUnderlierAmount = 10 * 1e6; // 10 dollars due to low liquity

    function _mintUSDC(address to, uint256 amount) internal {
        // USDC minters
        vm.store(address(usdc), keccak256(abi.encode(address(this), uint256(12))), bytes32(uint256(1)));
        // USDC minterAllowed
        vm.store(address(usdc), keccak256(abi.encode(address(this), uint256(13))), bytes32(uint256(type(uint256).max)));
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(usdc).call(abi.encodeWithSignature(sig, to, amount));
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
        // Fork when during buying window
        vm.createSelectFork(vm.rpcUrl("mainnet"), 14718858); // 5 may 2022

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

        periphery = IPeriphery(address(0x9a8fbC2548Da808E6cBC853Fee7e18fB06d52f18)); //  Sense Finance Periphery
        assertEq(periphery.divider(), address(0x86bA3E96Be68563E41c2f5769F1AF9fAf758e6E0)); // sanity check
        divider = IDivider(periphery.divider()); // Sense Finance Divider

        usdc = IERC20(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)); // USDC
        cUSDC = IERC20(address(0x39AA39c021dfbaE8faC545936693aC917d5E7563)); // Compound cUSDC (target)
        sP_cUSDC = IERC20(address(0xb636ADB2031DCbf6e2A04498e8Af494A819d4CB9)); // Sense Finance cUSDC Principal Token
        cUSDCAdapter = address(0xEc30fEaC79898aC5FFe055bD128BBbA9584080eC); // Sense Finance cUSDC adapter

        balancerVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

        impl = new VaultSPT(address(codex), address(cUSDC), address(usdc));
        vaultSenseUSDC = IVault(
            vaultFactory.createVault(
                address(impl),
                abi.encode(block.timestamp + 8 weeks, address(sP_cUSDC), address(collybus))
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
        codex.init(address(vaultSenseUSDC));
        codex.allowCaller(codex.transferCredit.selector, address(moneta));
        codex.setParam("globalDebtCeiling", 1000 ether);
        codex.setParam(address(vaultSenseUSDC), "debtCeiling", 1000 ether);
        collybus.setParam(address(vaultSenseUSDC), "liquidationRatio", 1 ether);
        collybus.updateSpot(address(usdc), 1 ether);
        publican.init(address(vaultSenseUSDC));
        codex.allowCaller(codex.modifyBalance.selector, address(vaultSenseUSDC));

        // get test USDC
        user = new Caller();
        _mintUSDC(address(user), defaultUnderlierAmount);
        _mintUSDC(me, defaultUnderlierAmount);
    }

    function test_sense_periphery() public {
        // Approve periphery for usdc
        usdc.approve(address(periphery), 100 ether);

        // Swap underlier for sPT
        uint256 ptBal = periphery.swapUnderlyingForPTs(cUSDCAdapter, maturity, defaultUnderlierAmount, 0);
        assertEq(sP_cUSDC.balanceOf(me), ptBal);
        assertEq(usdc.balanceOf(me), 0);

        // Approve periphery for sPT
        sP_cUSDC.approve(address(periphery), 100 ether);

        // Swap sPT for USDC (underlier)
        uint256 usdcAmount = periphery.swapPTsForUnderlying(cUSDCAdapter, maturity, ptBal, 0);
        assertEq(sP_cUSDC.balanceOf(me), 0);
        assertEq(usdc.balanceOf(me), usdcAmount);
    }

    function test_sense_redeem_sPT_directly() external {
        // get Sponsor address
        IDivider.Series memory serie = divider.series(cUSDCAdapter, maturity);
        address sponsor = serie.sponsor;

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        vm.prank(sponsor);
        divider.settleSeries(cUSDCAdapter, maturity);

        // A user with some PTs
        address userWithPT = address(0x0B4509F330Ff558090571861a723F71657a26f78);
        vm.startPrank(userWithPT);
        // approve sPT for divider
        sP_cUSDC.approve(address(divider), type(uint256).max);
        // user has some sPT but no target
        assertGt(sP_cUSDC.balanceOf(userWithPT), 0);
        assertEq(cUSDC.balanceOf(userWithPT), 0);
        // redeeem sPTs for cUSDC (pT to target)
        divider.redeem(cUSDCAdapter, maturity, sP_cUSDC.balanceOf(userWithPT));
        // user now has some target but no sPT
        assertEq(sP_cUSDC.balanceOf(userWithPT), 0);
        assertGt(cUSDC.balanceOf(userWithPT), 0);

        uint256 usdcBefore = usdc.balanceOf(userWithPT);
        // approve adapter for target
        cUSDC.approve(cUSDCAdapter, type(uint256).max);
        // unwrap target (target to underlier)
        IAdapter(cUSDCAdapter).unwrapTarget(cUSDC.balanceOf(userWithPT));
        // user has more usdc than before and no target
        assertEq(cUSDC.balanceOf(userWithPT), 0);
        assertGt(usdc.balanceOf(userWithPT), usdcBefore);
    }

    function test_buy_and_sell_CollateralAndModifyDebt_no_proxy() external {
        // Approve vaultActions for USDC
        usdc.approve(address(vaultActions), 100 ether);

        // Approve vaultActions for sPT
        sP_cUSDC.approve(address(vaultActions), 100 ether);

        // Allow vaultActions as delegate
        codex.grantDelegate(address(vaultActions));

        VaultSPTActions.SwapParams memory swapParamsIn = _getSwapParams(
            cUSDCAdapter,
            address(usdc),
            address(sP_cUSDC),
            0,
            maturity,
            defaultUnderlierAmount
        );

        // Buy sPT from USDC and mint fiat
        int256 fiatAmount = 9 ether; // 9 fiat
        vaultActions.buyCollateralAndModifyDebt(
            address(vaultSenseUSDC),
            me,
            me,
            me,
            defaultUnderlierAmount,
            fiatAmount,
            swapParamsIn
        );

        assertEq(usdc.balanceOf(me), 0);
        assertEq(fiat.balanceOf(me), uint256(fiatAmount));

        // sPT in the vault
        uint256 sPTBal = sP_cUSDC.balanceOf(address(vaultSenseUSDC));

        // Approve moneta for FIAT from vaultActions
        vaultActions.approveFIAT(address(moneta), 100 ether);

        // Approve vaultActions for FIAT
        fiat.approve(address(vaultActions), 100 ether);

        VaultSPTActions.SwapParams memory swapParamsOut = _getSwapParams(
            cUSDCAdapter,
            address(sP_cUSDC),
            address(usdc),
            0,
            maturity,
            sPTBal
        );

        assertEq(fiat.balanceOf(me), uint256(fiatAmount));
        assertEq(sP_cUSDC.balanceOf(me), 0);

        uint256 usdcBefore = usdc.balanceOf(me);

        // Repay debt and get back underlying
        vaultActions.sellCollateralAndModifyDebt(
            address(vaultSenseUSDC),
            me,
            me,
            me,
            sPTBal,
            -fiatAmount,
            swapParamsOut
        );

        assertGt(usdc.balanceOf(me), usdcBefore);
        assertEq(fiat.balanceOf(me), 0);
        assertEq(sP_cUSDC.balanceOf(me), 0);
    }

    function test_buy_and_sell_CollateralAndModifyDebt() external {
        // Approve moneta to burn FIAT from vaultActions for userProxy owner
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), 100 ether)
        );

        // Approve userProxy for USDC
        usdc.approve(address(userProxy), 100 ether);

        VaultSPTActions.SwapParams memory swapParamsIn = _getSwapParams(
            cUSDCAdapter,
            address(usdc),
            address(sP_cUSDC),
            0,
            maturity,
            defaultUnderlierAmount
        );

        int256 fiatAmount = 9 ether; // 9 FIAT
        // Buy sPT from USDC and mint FIAT
        _buyCollateralAndModifyDebt(address(vaultSenseUSDC), me, me, defaultUnderlierAmount, fiatAmount, swapParamsIn);

        assertEq(usdc.balanceOf(me), 0);
        assertEq(fiat.balanceOf(me), uint256(fiatAmount));
        (uint256 collateral, uint256 normalDebt) = codex.positions(address(vaultSenseUSDC), 0, address(userProxy));

        // sPT in the vault
        uint256 sPTBal = sP_cUSDC.balanceOf(address(vaultSenseUSDC));

        // Collateral corresponds to sPTBal scaled 
        assertEq(collateral, wdiv(sPTBal, vaultSenseUSDC.tokenScale()));
        // Debt is fiat balance
        assertEq(normalDebt, fiat.balanceOf(me));

        // Approve userProxy for fiat
        fiat.approve(address(userProxy), 100 ether);

        // Params to exit from sPT to underlying asset
        VaultSPTActions.SwapParams memory swapParamsOut = _getSwapParams(
            cUSDCAdapter,
            address(sP_cUSDC),
            address(usdc),
            0,
            maturity,
            sPTBal
        );

        assertEq(fiat.balanceOf(me), uint256(fiatAmount));
        assertEq(sP_cUSDC.balanceOf(me), 0);

        uint256 usdcBefore = usdc.balanceOf(me);

        // Repay debt and get back underlying
        _sellCollateralAndModifyDebt(address(vaultSenseUSDC), me, me, sPTBal, -fiatAmount, swapParamsOut);

        assertGt(usdc.balanceOf(me), usdcBefore);
        assertGt(defaultUnderlierAmount, usdc.balanceOf(me)); // we have a bit less
        assertEq(fiat.balanceOf(me), 0);
        assertEq(sP_cUSDC.balanceOf(me), 0);
    }

    function test_buy_and_sell_CollateralAndModifyDebt_from_user() external {
        user.externalCall(
            address(fiat),
            abi.encodeWithSelector(fiat.approve.selector, address(userProxy), type(uint256).max)
        );
        user.externalCall(
            address(usdc),
            abi.encodeWithSelector(usdc.approve.selector, address(userProxy), type(uint256).max)
        );

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), type(uint256).max)
        );

        VaultSPTActions.SwapParams memory swapParamsIn = _getSwapParams(
            cUSDCAdapter,
            address(usdc),
            address(sP_cUSDC),
            0,
            maturity,
            defaultUnderlierAmount
        );

        // Buy sPT from USDC and mint fiat
        int256 fiatAmount = 9 ether; // 9 fiat

        _buyCollateralAndModifyDebt(
            address(vaultSenseUSDC),
            address(user),
            address(user),
            defaultUnderlierAmount,
            fiatAmount,
            swapParamsIn
        );

        assertEq(usdc.balanceOf(address(user)), 0);
        assertEq(fiat.balanceOf(address(user)), uint256(fiatAmount));
        (uint256 collateral, uint256 normalDebt) = codex.positions(address(vaultSenseUSDC), 0, address(userProxy));

        // sPT in the vault
        uint256 sPTBal = sP_cUSDC.balanceOf(address(vaultSenseUSDC));

        // Collateral corresponds to sPTBal scaled 
        assertEq(collateral, wdiv(sPTBal, vaultSenseUSDC.tokenScale()));
        // Debt is fiat balance
        assertEq(normalDebt, fiat.balanceOf(address(user)));

        // Params to exit from sPT to underlying asset
        VaultSPTActions.SwapParams memory swapParamsOut = _getSwapParams(
            cUSDCAdapter,
            address(sP_cUSDC),
            address(usdc),
            0,
            maturity,
            sPTBal
        );

        assertEq(fiat.balanceOf(address(user)), uint256(fiatAmount));
        assertEq(sP_cUSDC.balanceOf(address(user)), 0);

        uint256 usdcBefore = usdc.balanceOf(address(user));

        // Repay debt and get back underlying
        _sellCollateralAndModifyDebt(
            address(vaultSenseUSDC),
            address(user),
            address(user),
            sPTBal,
            -fiatAmount,
            swapParamsOut
        );

        assertGt(usdc.balanceOf(address(user)), usdcBefore);
        assertGt(defaultUnderlierAmount, usdc.balanceOf(address(user))); // we have a bit less
        assertEq(fiat.balanceOf(address(user)), 0);
        assertEq(sP_cUSDC.balanceOf(address(user)), 0);
    }

    function test_redeemCollateralAndModifyDebt_no_proxy() external {
        // Approve vaultActions for USDC
        usdc.approve(address(vaultActions), 100 ether);

        // Approve vaultActions for sPT
        sP_cUSDC.approve(address(vaultActions), 100 ether);

        // Allow vaultActions as delegate
        codex.grantDelegate(address(vaultActions));

        VaultSPTActions.SwapParams memory swapParamsIn = _getSwapParams(
            cUSDCAdapter,
            address(usdc),
            address(sP_cUSDC),
            0,
            maturity,
            defaultUnderlierAmount
        );

        // Buy sPT from USDC and mint fiat
        int256 fiatAmount = 9 ether; // 9 fiat
        vaultActions.buyCollateralAndModifyDebt(
            address(vaultSenseUSDC),
            me,
            me,
            me,
            defaultUnderlierAmount,
            fiatAmount,
            swapParamsIn
        );
        // sPT in the vault
        uint256 sPTBal = sP_cUSDC.balanceOf(address(vaultSenseUSDC));

        VaultSPTActions.RedeemParams memory redeemParams = _getRedeemParams(
            cUSDCAdapter,
            maturity,
            address(cUSDC),
            address(usdc),
            type(uint256).max
        );

        // Approve moneta for fiat from vaultActions
        vaultActions.approveFIAT(address(moneta), 100 ether);

        sP_cUSDC.approve(address(vaultActions), type(uint256).max);
        fiat.approve(address(vaultActions), type(uint256).max);

        // we now move AFTER maturity, settle serie and redeem
        // get Sponsor address
        IDivider.Series memory serie = divider.series(cUSDCAdapter, maturity);
        address sponsor = serie.sponsor;

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        vm.prank(sponsor);
        divider.settleSeries(cUSDCAdapter, maturity);

        // no usdc, cUSDC, sPT, only FIAT
        assertEq(fiat.balanceOf(me), uint256(fiatAmount));
        assertEq(usdc.balanceOf(me), 0);
        assertEq(cUSDC.balanceOf(me), 0);
        assertEq(sP_cUSDC.balanceOf(me), 0);

        // Pay back fiat and redeem sPT for usdc;
        vaultActions.redeemCollateralAndModifyDebt(
            address(vaultSenseUSDC),
            address(sP_cUSDC),
            me,
            me,
            me,
            sPTBal,
            -fiatAmount,
            redeemParams
        );

        // no fiat, cUSDC, sPT, only USDC, which is now more than we had initially
        assertGt(usdc.balanceOf(me), defaultUnderlierAmount);
        assertEq(fiat.balanceOf(me), 0);
        assertEq(cUSDC.balanceOf(me), 0);
        assertEq(sP_cUSDC.balanceOf(me), 0);
    }

    function test_redeemCollateralAndModifyDebt() external {
        // Approve userProxy for USDC
        usdc.approve(address(userProxy), 100 ether);

        sP_cUSDC.approve(address(userProxy), 100 ether);

        VaultSPTActions.SwapParams memory swapParamsIn = _getSwapParams(
            cUSDCAdapter,
            address(usdc),
            address(sP_cUSDC),
            0,
            maturity,
            defaultUnderlierAmount
        );

        // Buy sPT from USDC and mint fiat
        int256 fiatAmount = 9 ether; // 9 fiat

        _buyCollateralAndModifyDebt(address(vaultSenseUSDC), me, me, defaultUnderlierAmount, fiatAmount, swapParamsIn);

        // sPT in the vault
        uint256 sPTBal = sP_cUSDC.balanceOf(address(vaultSenseUSDC));

        VaultSPTActions.RedeemParams memory redeemParams = _getRedeemParams(
            cUSDCAdapter,
            maturity,
            address(cUSDC),
            address(usdc),
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
        IDivider.Series memory serie = divider.series(cUSDCAdapter, maturity);
        address sponsor = serie.sponsor;

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        vm.prank(sponsor);
        divider.settleSeries(cUSDCAdapter, maturity);

        // no usdc, cUSDC, sPT, only FIAT
        assertEq(fiat.balanceOf(me), uint256(fiatAmount));
        assertEq(usdc.balanceOf(me), 0);
        assertEq(cUSDC.balanceOf(me), 0);
        assertEq(sP_cUSDC.balanceOf(me), 0);

        // Pay back fiat and redeem sPT for usdc;
        _redeemCollateralAndModifyDebt(
            address(vaultSenseUSDC),
            address(sP_cUSDC),
            me,
            me,
            sPTBal,
            -fiatAmount,
            redeemParams
        );

        // no fiat, cUSDC, sPT, only USDC, which is now more than we had initially
        assertGt(usdc.balanceOf(me), defaultUnderlierAmount);
        assertEq(fiat.balanceOf(me), 0);
        assertEq(cUSDC.balanceOf(me), 0);
        assertEq(sP_cUSDC.balanceOf(me), 0);
    }

    function test_redeemCollateralAndModifyDebt_from_user() external {
        vm.startPrank(address(user));
        fiat.approve(address(userProxy), type(uint256).max);
        usdc.approve(address(userProxy), type(uint256).max);
        vm.stopPrank();

        VaultSPTActions.SwapParams memory swapParamsIn = _getSwapParams(
            cUSDCAdapter,
            address(usdc),
            address(sP_cUSDC),
            0,
            maturity,
            defaultUnderlierAmount
        );

        // Buy sPT from USDC and mint fiat
        int256 fiatAmount = 9 ether; // 9 fiat

        _buyCollateralAndModifyDebt(
            address(vaultSenseUSDC),
            address(user),
            address(user),
            defaultUnderlierAmount,
            fiatAmount,
            swapParamsIn
        );

        assertEq(usdc.balanceOf(address(user)), 0);
        assertEq(fiat.balanceOf(address(user)), uint256(fiatAmount));

        // sPT in the vault
        uint256 sPTBal = sP_cUSDC.balanceOf(address(vaultSenseUSDC));

        VaultSPTActions.RedeemParams memory redeemParams = _getRedeemParams(
            cUSDCAdapter,
            maturity,
            address(cUSDC),
            address(usdc),
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
        IDivider.Series memory serie = divider.series(cUSDCAdapter, maturity);
        address sponsor = serie.sponsor;

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        vm.prank(sponsor);
        divider.settleSeries(cUSDCAdapter, maturity);

        // // no usdc, cUSDC, sPT, only FIAT
        assertEq(fiat.balanceOf(address(user)), uint256(fiatAmount));
        assertEq(usdc.balanceOf(address(user)), 0);
        assertEq(cUSDC.balanceOf(address(user)), 0);
        assertEq(sP_cUSDC.balanceOf(address(user)), 0);

        // Pay back fiat and redeem sPT for usdc;
        _redeemCollateralAndModifyDebt(
            address(vaultSenseUSDC),
            address(sP_cUSDC),
            address(user),
            address(user),
            sPTBal,
            -fiatAmount,
            redeemParams
        );

        // no fiat, cUSDC, sPT, only USDC, which is now more than we had initially
        assertGt(usdc.balanceOf(address(user)), defaultUnderlierAmount);
        assertEq(fiat.balanceOf(address(user)), 0);
        assertEq(cUSDC.balanceOf(address(user)), 0);
        assertEq(sP_cUSDC.balanceOf(address(user)), 0);
    }
}
