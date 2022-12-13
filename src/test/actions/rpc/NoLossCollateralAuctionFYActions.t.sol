// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";
import {IVault} from "../../../interfaces/IVault.sol";
import {Aer} from "../../../core/Aer.sol";
import {Codex} from "../../../core/Codex.sol";
import {NoLossCollateralAuction} from "../../../core/auctions/NoLossCollateralAuction.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {Limes} from "../../../core/Limes.sol";
import {LinearDecrease} from "../../../core/auctions/PriceCalculator.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {Publican} from "../../../core/Publican.sol";
import {toInt256, WAD, sub, wdiv} from "../../../core/utils/Math.sol";

import {Vault20} from "../../../vaults/Vault.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";
import {VaultFY} from "../../../vaults/VaultFY.sol";
import {NoLossCollateralAuctionFYActions} from "../../../actions/auction/NoLossCollateralAuctionFYActions.sol";

contract NoLossCollateralAuctionFYActions_UnitTest is Test {
    Codex internal codex;
    Moneta internal moneta;
    PRBProxy internal userProxy;
    PRBProxyFactory internal prbProxyFactory;
    VaultFactory internal vaultFactory;

    FIAT internal fiat;
    Collybus internal collybus;
    Publican internal publican;
    Aer internal aer;
    NoLossCollateralAuction internal collateralAuction;
    Limes internal limes;
    NoLossCollateralAuctionFYActions internal auctionActions;

    address internal me = address(this);
    uint256 internal ONE_USDC = 1e6;
    uint256 internal maturity = 1640919600; // 21 DEC 21
    IERC20 internal underlierUSDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // Yield
    VaultFY internal vaultFY_impl;
    VaultFY internal vaultFY_USDC06;

    // Collateral
    IERC20 internal fyUSDC04 = IERC20(0x30FaDeEaAB2d7a23Cb1C35c05e2f8145001fA533);
    // Yield pool
    address internal fyUSDC04LP = address(0x407353d527053F3a6140AAA7819B93Af03114227);

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 13700000);

        vaultFactory = new VaultFactory();
        fiat = new FIAT();
        codex = new Codex();
        publican = new Publican(address(codex));
        codex.allowCaller(codex.modifyRate.selector, address(publican));
        moneta = new Moneta(address(codex), address(fiat));
        fiat.allowCaller(fiat.mint.selector, address(moneta));
        collybus = new Collybus();
        aer = new Aer(address(codex), address(0), address(0));
        limes = new Limes(address(codex));
        collateralAuction = new NoLossCollateralAuction(address(codex), address(limes));
        LinearDecrease calculator = new LinearDecrease();
        prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        // Yield
        vaultFY_impl = new VaultFY(
            address(codex),
            address(underlierUSDC)
        );
        _mintUSDC(me, 2000000 * ONE_USDC);

        address instance = vaultFactory.createVault(address(vaultFY_impl), abi.encode(fyUSDC04, address(collybus)));
        vaultFY_USDC06 = VaultFY(instance);

        // set Vault
        codex.init(address(vaultFY_USDC06));
        codex.allowCaller(codex.transferCredit.selector, address(moneta));
        codex.setParam("globalDebtCeiling", 500 ether);
        codex.setParam(address(vaultFY_USDC06), "debtCeiling", 500 ether);
        collybus.setParam(address(vaultFY_USDC06), "liquidationRatio", 1 ether);
        collybus.updateSpot(address(underlierUSDC), 1 ether);
        publican.init(address(vaultFY_USDC06));
        codex.allowCaller(codex.modifyBalance.selector, address(vaultFY_USDC06));

        calculator.setParam(bytes32("duration"), 100000);

        collateralAuction.init(address(vaultFY_USDC06), address(collybus));
        collateralAuction.setParam(address(vaultFY_USDC06), bytes32("maxAuctionDuration"), 200000);
        collateralAuction.setParam(address(vaultFY_USDC06), bytes32("calculator"), address(calculator));
        collateralAuction.allowCaller(collateralAuction.ANY_SIG(), address(limes));

        limes.setParam(bytes32("globalMaxDebtOnAuction"), 500e18);
        limes.setParam(bytes32("aer"), address(aer));
        limes.setParam(address(vaultFY_USDC06), bytes32("liquidationPenalty"), WAD);
        limes.setParam(address(vaultFY_USDC06), bytes32("maxDebtOnAuction"), 500e18);
        limes.setParam(address(vaultFY_USDC06), bytes32("collateralAuction"), address(collateralAuction));
        limes.allowCaller(limes.ANY_SIG(), address(collateralAuction));

        aer.allowCaller(aer.ANY_SIG(), address(limes));
        aer.allowCaller(aer.ANY_SIG(), address(collateralAuction));

        codex.allowCaller(codex.ANY_SIG(), address(moneta));
        codex.allowCaller(codex.ANY_SIG(), address(vaultFY_USDC06));
        codex.allowCaller(codex.ANY_SIG(), address(limes));
        codex.allowCaller(codex.ANY_SIG(), address(collateralAuction));

        underlierUSDC.approve(address(userProxy), type(uint256).max);
        fyUSDC04.approve(address(vaultFY_USDC06), type(uint256).max);

        // transfer some pT to us
        vm.prank(address(0x5066c297F970b63D28f86Ef6FfEfeAF7A208014C));// user with pT
        fyUSDC04.transfer(me, 1000 * ONE_USDC);

        vaultFY_USDC06.enter(0, me, fyUSDC04.balanceOf(me));

        codex.modifyCollateralAndDebt(address(vaultFY_USDC06), 0, me, me, me, 1000e18, 500e18);
        // update price so we can liquidate
        collybus.updateSpot(address(underlierUSDC), 0.4 ether);

        limes.liquidate(address(vaultFY_USDC06), 0, me, me);

        // re-update price
        collybus.updateSpot(address(underlierUSDC), 1 ether);

        auctionActions = new NoLossCollateralAuctionFYActions(
            address(codex),
            address(moneta),
            address(fiat),
            address(collateralAuction)
        );

        fiat.allowCaller(keccak256("ANY_SIG"), address(moneta));

        codex.grantDelegate(address(moneta));
        moneta.exit(me, 100e18);

        fiat.approve(address(userProxy), 100e18);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(auctionActions.approveFIAT.selector, address(moneta), 100e18)
        );
    }

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

    function _balance(address vault, address user) internal view returns (uint256) {
        return codex.balances(vault, 0, user);
    }

    function _getSwapParams(
        address assetIn,
        address assetOut,
        uint256 minOutput
    ) internal view returns (NoLossCollateralAuctionFYActions.SwapParams memory swapParams) {
        swapParams.yieldSpacePool = fyUSDC04LP;
        swapParams.assetIn = assetIn;
        swapParams.assetOut = assetOut;
        swapParams.minAssetOut = minOutput;
    }

    function test_takeCollateral() public {
        collateralAuction.redoAuction(1, me);
        fiat.transfer(address(userProxy), 100e18);

        uint256 fiatBalance = fiat.balanceOf(address(userProxy));
        uint256 collateralBalance = _balance(address(vaultFY_USDC06), address(userProxy));

        vm.warp(block.timestamp + 100);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateral.selector,
                address(vaultFY_USDC06),
                0,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy)
            )
        );

        // should have refunded excess FIAT
        assertGt(fiat.balanceOf(address(userProxy)), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(address(userProxy)));
        // the collateral is still in FIAT system
        assertGt(_balance(address(vaultFY_USDC06), address(userProxy)), collateralBalance);
    }

    function test_takeCollateral_from_user_BEFORE_maturity() public {
        collateralAuction.redoAuction(1, me);
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = _balance(address(fyUSDC04), me);

        vm.warp(block.timestamp + 100);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateral.selector,
                address(vaultFY_USDC06),
                0,
                me,
                1,
                100e18,
                1e18,
                me
            )
        );

        // should have refunded excess FIAT
        assertGt(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(me));
        // the collateral is still in FIAT system
        assertGt(_balance(address(vaultFY_USDC06), me), collateralBalance);
    }

    function test_takeCollateral_from_user_AFTER_maturity() public {
        vm.warp(maturity + 3600 * 24 * 20);
        collateralAuction.redoAuction(1, me);
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = _balance(address(fyUSDC04), me);
        assertEq(collateralBalance, 0);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateral.selector,
                address(vaultFY_USDC06),
                0,
                me,
                1,
                100e18,
                1e18,
                me
            )
        );

        // all FIAT was used
        assertEq(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(me));
        // the collateral is still in FIAT system
        assertGt(_balance(address(vaultFY_USDC06), me), collateralBalance);
    }

    function test_takeCollateralAndSwapForUnderlier_BEFORE_maturity() public {
        fiat.transfer(address(userProxy), 100e18);
        uint256 collateralBalance = fyUSDC04.balanceOf(address(userProxy));

        assertEq(collateralBalance, 0);

        vm.warp(block.timestamp + 100);
        collateralAuction.redoAuction(1, me);

        assertEq(underlierUSDC.balanceOf(address(userProxy)), 0);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndSwapForUnderlier.selector,
                address(vaultFY_USDC06),
                0,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy),
                _getSwapParams(address(fyUSDC04), address(underlierUSDC), 0)
            )
        );

        // we have more USDC than before
        assertGt(underlierUSDC.balanceOf(address(userProxy)), 0);
        // used all FIAT
        assertEq(fiat.balanceOf(address(userProxy)), 0);
        // No collateral left
        assertEq(collateralBalance, fyUSDC04.balanceOf(address(userProxy)));
    }

    function test_takeCollateralAndSwapForUnderlier_from_user_BEFORE_maturity() public {
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = _balance(address(fyUSDC04), me);
        assertEq(fiatBalance, 100e18);
        assertEq(collateralBalance, 0);

        vm.warp(block.timestamp + 100);
        collateralAuction.redoAuction(1, me);

        uint256 usdcBefore = underlierUSDC.balanceOf(me);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndSwapForUnderlier.selector,
                address(vaultFY_USDC06),
                0,
                me,
                1,
                100e18,
                1e18,
                me,
                _getSwapParams(address(fyUSDC04), address(underlierUSDC), 0)
            )
        );

        // we have more USDC than before
        assertGt(underlierUSDC.balanceOf(me), usdcBefore);
        // used all FIAT
        assertEq(fiat.balanceOf(address(me)), 0);
        // No collateral
        assertEq(collateralBalance, fyUSDC04.balanceOf(me));
    }

    function test_takeCollateralAndRedeemForUnderlier_AFTER_maturity() public {
        fiat.transfer(address(userProxy), 100e18);
        uint256 fiatBalance = fiat.balanceOf(address(userProxy));
        uint256 collateralBalance = fyUSDC04.balanceOf(address(userProxy));

        // Move post maturity
        vm.warp(maturity + 1);

        collateralAuction.redoAuction(1, me);

        uint256 usdcBefore = underlierUSDC.balanceOf(address(userProxy));

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndRedeemForUnderlier.selector,
                address(vaultFY_USDC06),
                0,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy)
            )
        );

        assertGt(underlierUSDC.balanceOf(address(userProxy)), usdcBefore);
        // used all FIAT
        assertEq(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(address(userProxy)));
        // No collateral left
        assertEq(collateralBalance, fyUSDC04.balanceOf(address(userProxy)));
    }

    function test_takeCollateralAndRedeemForUnderlier_from_user_AFTER_maturity() public {
        fiat.transfer(me, 100e18);
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = _balance(address(fyUSDC04), me);

        // Move post maturity
        vm.warp(maturity + 1);

        collateralAuction.redoAuction(1, me);

        uint256 usdcBefore = underlierUSDC.balanceOf(me);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndRedeemForUnderlier.selector,
                address(vaultFY_USDC06),
                0,
                me,
                1,
                100e18,
                1e18,
                me
            )
        );

        assertGt(underlierUSDC.balanceOf(me), usdcBefore);
        // used all FIAT
        assertEq(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(me));
        // No collateral left
        assertEq(collateralBalance, fyUSDC04.balanceOf(me));
    }

    function testFail_takeCollateralAndRedeemForUnderlier_BEFORE_maturity() public {
        fiat.transfer(address(userProxy), 100e18);

        vm.warp(block.timestamp + 24 * 3600);

        collateralAuction.redoAuction(1, me);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndRedeemForUnderlier.selector,
                address(vaultFY_USDC06),
                0,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy)
            )
        );
    }

    function testFail_takeCollateralAndSwapForUnderlier_AFTER_maturity() public {
        fiat.transfer(address(userProxy), 100e18);

        vm.warp(maturity + 3600 * 24 * 20);
        collateralAuction.redoAuction(1, me);


        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndSwapForUnderlier.selector,
                address(vaultFY_USDC06),
                0,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy),
                _getSwapParams(address(fyUSDC04), address(underlierUSDC), 0)
            )
        );
    }

    function testFail_takeCollateralAndSwapForUnderlier_from_user_AFTER_maturity() public {
        vm.warp(maturity + 3600 * 24 * 20);
        collateralAuction.redoAuction(1, me);
        
        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndSwapForUnderlier.selector,
                address(vaultFY_USDC06),
                0,
                me,
                1,
                100e18,
                1e18,
                me,
                _getSwapParams(address(fyUSDC04), address(underlierUSDC), 0)
            )
        );
    }
}
