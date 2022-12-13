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
import {VaultSPT} from "../../../vaults/VaultSPT.sol";
import {NoLossCollateralAuctionSPTActions} from "../../../actions/auction/NoLossCollateralAuctionSPTActions.sol";

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

    function divider() external view returns (address divider);
}

contract NoLossCollateralAuctionSPTActions_UnitTest is Test {
    Codex internal codex;
    Moneta internal moneta;
    PRBProxy internal userProxy;
    PRBProxyFactory internal prbProxyFactory;
    IVault internal maDAIVault;
    VaultFactory internal vaultFactory;
    VaultSPT internal impl;
    FIAT internal fiat;
    Collybus internal collybus;
    Publican internal publican;
    Aer internal aer;
    NoLossCollateralAuction internal collateralAuction;
    Limes internal limes;
    NoLossCollateralAuctionSPTActions internal auctionActions;

    // Caller internal user;
    address internal me = address(this);

    IPeriphery internal periphery;
    IDivider internal divider;
    address internal maDAIAdapter;

    IERC20 internal dai;
    IERC20 internal maDAI;
    IERC20 internal sP_maDAI;
   
    uint256 internal maturity = 1688169600; // morpho maturity 1st July 2023



    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 15855705); // 29 October 2022

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

        // Sense
        periphery = IPeriphery(address(0xFff11417a58781D3C72083CB45EF54d79Cd02437)); //  Sense Finance Periphery
        divider = IDivider(periphery.divider()); // Sense Finance Divider

        dai = IERC20(address(0x6B175474E89094C44Da98b954EedeAC495271d0F)); // dai
        maDAI = IERC20(address(0x36F8d0D0573ae92326827C4a82Fe4CE4C244cAb6)); // Morpho maDAI (target)
        sP_maDAI = IERC20(address(0x0427a3A0De8c4B3dB69Dd7FdD6A90689117C3589)); // Sense Finance maDAI Principal Token
        maDAIAdapter = address(0x9887e67AaB4388eA4cf173B010dF5c92B91f55B5); // Sense Finance maDAI adapter

        impl = new VaultSPT(address(codex), address(maDAI), address(dai));
        maDAIVault = IVault(
            vaultFactory.createVault(
                address(impl),
                abi.encode(block.timestamp + 8 weeks, address(sP_maDAI), address(collybus))
            )
        );

        // set Vault
        codex.init(address(maDAIVault));
        codex.allowCaller(codex.transferCredit.selector, address(moneta));
        codex.setParam("globalDebtCeiling", 500 ether);
        codex.setParam(address(maDAIVault), "debtCeiling", 500 ether);
        collybus.setParam(address(maDAIVault), "liquidationRatio", 1 ether);
        collybus.updateSpot(address(dai), 1 ether);
        publican.init(address(maDAIVault));
        codex.allowCaller(codex.modifyBalance.selector, address(maDAIVault));

        calculator.setParam(bytes32("duration"), 100000);

        collateralAuction.init(address(maDAIVault), address(collybus));
        collateralAuction.setParam(address(maDAIVault), bytes32("maxAuctionDuration"), 200000);
        collateralAuction.setParam(address(maDAIVault), bytes32("calculator"), address(calculator));
        collateralAuction.allowCaller(collateralAuction.ANY_SIG(), address(limes));

        limes.setParam(bytes32("globalMaxDebtOnAuction"), 500e18);
        limes.setParam(bytes32("aer"), address(aer));
        limes.setParam(address(maDAIVault), bytes32("liquidationPenalty"), WAD);
        limes.setParam(address(maDAIVault), bytes32("maxDebtOnAuction"), 500e18);
        limes.setParam(address(maDAIVault), bytes32("collateralAuction"), address(collateralAuction));
        limes.allowCaller(limes.ANY_SIG(), address(collateralAuction));

        aer.allowCaller(aer.ANY_SIG(), address(limes));
        aer.allowCaller(aer.ANY_SIG(), address(collateralAuction));

        codex.allowCaller(codex.ANY_SIG(), address(moneta));
        codex.allowCaller(codex.ANY_SIG(), address(maDAIVault));
        codex.allowCaller(codex.ANY_SIG(), address(limes));
        codex.allowCaller(codex.ANY_SIG(), address(collateralAuction));

        vm.prank(0xcAc59F91E4536Bc0E79aB816a5cD54e89f10433C); // user with spT
        sP_maDAI.transfer(me, 1000 ether);
        sP_maDAI.approve(address(maDAIVault), 1000 ether);

        maDAIVault.enter(0, me, 1000 ether);
        codex.modifyCollateralAndDebt(address(maDAIVault), 0, me, me, me, 1000e18, 500e18);
        // update price so we can liquidate
        collybus.updateSpot(address(dai), 0.4 ether);

        limes.liquidate(address(maDAIVault), 0, me, me);

        // re-update price
        collybus.updateSpot(address(dai), 1 ether);
      
        auctionActions = new NoLossCollateralAuctionSPTActions(
            address(codex),
            address(moneta),
            address(fiat),
            address(collateralAuction),
            address(periphery)
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


    function _balance(address vault, address user) internal view returns (uint256) {
        return codex.balances(vault, 0, user);
    }

    function test_takeCollateral() public {
        collateralAuction.redoAuction(1, me);
        fiat.transfer(address(userProxy), 100e18);

        uint256 fiatBalance = fiat.balanceOf(address(userProxy));
        uint256 collateralBalance = _balance(address(maDAIVault), address(userProxy));

        vm.warp(block.timestamp + 100);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateral.selector,
                address(maDAIVault),
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
        assertGt(_balance(address(maDAIVault), address(userProxy)), collateralBalance);
    }

    function test_takeCollateral_from_user_BEFORE_maturity() public {
        collateralAuction.redoAuction(1, me);
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = _balance(address(maDAIVault), me);

        vm.warp(block.timestamp + 100);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(auctionActions.takeCollateral.selector, address(maDAIVault), 0, me, 1, 100e18, 1e18, me)
        );

        // should have refunded excess FIAT
        assertGt(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(me));
        // the collateral is still in FIAT system
        assertGt(_balance(address(maDAIVault), me), collateralBalance);
    }

    function test_takeCollateral_from_user_AFTER_maturity() public {
        
        vm.warp(maturity + 3600 * 24 * 20);
        collateralAuction.redoAuction(1, me);
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = sP_maDAI.balanceOf(me);
        assertEq(collateralBalance, 0);
   
        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(auctionActions.takeCollateral.selector, address(maDAIVault), 0, me, 1, 100e18, 1e18, me)
        );

        // all FIAT was used
        assertEq(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(me));
    }

    function test_takeCollateralAndSwapForUnderlier_BEFORE_maturity() public {
       
        fiat.transfer(address(userProxy), 100e18);
        uint256 fiatBalance = fiat.balanceOf(address(userProxy));
        uint256 collateralBalance = sP_maDAI.balanceOf(address(userProxy));

        vm.warp(block.timestamp + 100);
        collateralAuction.redoAuction(1, me);

        NoLossCollateralAuctionSPTActions.SwapParams memory swapParams;
        swapParams.adapter = maDAIAdapter;
        swapParams.minAccepted = 0;
        swapParams.maturity = maturity;
        swapParams.assetIn = address(sP_maDAI);
        swapParams.assetOut = address(dai);
        swapParams.approve= type(uint).max;

        assertEq(dai.balanceOf(address(userProxy)), 0);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndSwapForUnderlier.selector,
                address(maDAIVault),
                0,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy),
                swapParams
            )
        );
        // DAI received
        assertGt(dai.balanceOf(address(userProxy)), 0);
        // used all FIAT
        assertEq(fiat.balanceOf(address(userProxy)), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(address(userProxy)));
        // No collateral left
        assertEq(collateralBalance, sP_maDAI.balanceOf(address(userProxy)));
    }
    
    function test_takeCollateralAndSwapForUnderlier_from_user_BEFORE_maturity() public {
       
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = sP_maDAI.balanceOf(me);

        vm.warp(block.timestamp + 100);
        collateralAuction.redoAuction(1, me);

        NoLossCollateralAuctionSPTActions.SwapParams memory swapParams;
        swapParams.adapter = maDAIAdapter;
        swapParams.minAccepted = 0;
        swapParams.maturity = maturity;
        swapParams.assetIn = address(sP_maDAI);
        swapParams.assetOut = address(dai);
        swapParams.approve= type(uint).max;

        assertEq(dai.balanceOf(me), 0);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndSwapForUnderlier.selector,
                address(maDAIVault),
                0,
                me,
                1,
                100e18,
                1e18,
                me,
                swapParams
            )
        );

        assertGt(dai.balanceOf(me), 0);
        // used all FIAT
        assertEq(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(me));
        // No collateral 
        assertEq(collateralBalance, sP_maDAI.balanceOf(me));
    }

    function test_takeCollateralAndSwapForUnderlier_AFTER_maturity() public {
       
        fiat.transfer(address(userProxy), 100e18);
        uint256 fiatBalance = fiat.balanceOf(address(userProxy));
        uint256 collateralBalance = sP_maDAI.balanceOf(address(userProxy));
        
        assertEq(collateralBalance, 0);

        vm.warp(maturity + 3600 * 24 * 20);
        collateralAuction.redoAuction(1, me);

        NoLossCollateralAuctionSPTActions.SwapParams memory swapParams;
        swapParams.adapter = maDAIAdapter;
        swapParams.minAccepted = 0;
        swapParams.maturity = maturity;
        swapParams.assetIn = address(sP_maDAI);
        swapParams.assetOut = address(dai);
        swapParams.approve= type(uint).max;

        assertEq(dai.balanceOf(address(userProxy)), 0);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndSwapForUnderlier.selector,
                address(maDAIVault),
                0,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy),
                swapParams
            )
        );
        // DAI received
        assertGt(dai.balanceOf(address(userProxy)), 0);
        // used all FIAT
        assertEq(fiat.balanceOf(address(userProxy)), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(address(userProxy)));
        // No collateral left
        assertEq(collateralBalance, sP_maDAI.balanceOf(address(userProxy)));
    }

    function test_takeCollateralAndSwapForUnderlier_from_user_AFTER_maturity() public {
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = sP_maDAI.balanceOf(me);

        vm.warp(maturity + 3600 * 24 * 20);
        collateralAuction.redoAuction(1, me);

        NoLossCollateralAuctionSPTActions.SwapParams memory swapParams;
        swapParams.adapter = maDAIAdapter;
        swapParams.minAccepted = 0;
        swapParams.maturity = maturity;
        swapParams.assetIn = address(sP_maDAI);
        swapParams.assetOut = address(dai);
        swapParams.approve= type(uint).max;

        assertEq(dai.balanceOf(me), 0);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndSwapForUnderlier.selector,
                address(maDAIVault),
                0,
                me,
                1,
                100e18,
                1e18,
                me,
                swapParams
            )
        );

        assertGt(dai.balanceOf(me), 0);
        // used all FIAT
        assertEq(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(me));
        // no collateral left
        assertEq(collateralBalance, sP_maDAI.balanceOf(me));
    }

    function test_takeCollateralAndRedeemForUnderlier_AFTER_maturity() public {
       
        fiat.transfer(address(userProxy), 100e18);
        uint256 fiatBalance = fiat.balanceOf(address(userProxy));
        uint256 collateralBalance = sP_maDAI.balanceOf(address(userProxy));

        IDivider.Series memory serie = divider.series(maDAIAdapter, maturity);
        address sponsor = serie.sponsor;

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        vm.prank(sponsor);
        divider.settleSeries(maDAIAdapter, maturity);

        collateralAuction.redoAuction(1, me);

        NoLossCollateralAuctionSPTActions.RedeemParams memory redeemParams;
        redeemParams.adapter = maDAIAdapter;
        redeemParams.maturity = maturity;
        redeemParams.target = address(maDAI);
        redeemParams.underlierToken = address(dai);
        redeemParams.approveTarget= type(uint).max;

        assertEq(dai.balanceOf(address(userProxy)), 0);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndRedeemForUnderlier.selector,
                address(maDAIVault),
                0,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy),
                redeemParams
            )
        );

        assertGt(dai.balanceOf(address(userProxy)), 0);
        // used all FIAT
        assertEq(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(address(userProxy)));
        // No collateral left
        assertEq(collateralBalance, sP_maDAI.balanceOf(address(userProxy)));
    }
    
    function test_takeCollateralAndRedeemForUnderlier_from_user_AFTER_maturity() public {
       
        fiat.transfer(me, 100e18);
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = sP_maDAI.balanceOf(me);

        IDivider.Series memory serie = divider.series(maDAIAdapter, maturity);
        address sponsor = serie.sponsor;

        // Move post maturity
        vm.warp(maturity + 1);

        // Settle serie from sponsor
        vm.prank(sponsor);
        divider.settleSeries(maDAIAdapter, maturity);

        collateralAuction.redoAuction(1, me);

        NoLossCollateralAuctionSPTActions.RedeemParams memory redeemParams;
        redeemParams.adapter = maDAIAdapter;
        redeemParams.maturity = maturity;
        redeemParams.target = address(maDAI);
        redeemParams.underlierToken = address(dai);
        redeemParams.approveTarget= type(uint).max;

        assertEq(dai.balanceOf(me), 0);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndRedeemForUnderlier.selector,
                address(maDAIVault),
                0,
                me,
                1,
                100e18,
                1e18,
                me,
                redeemParams
            )
        );

        assertGt(dai.balanceOf(me), 0);
        // used all FIAT
        assertEq(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(me));
        // No collateral left
        assertEq(collateralBalance, sP_maDAI.balanceOf(me));
    }

    function testFail_takeCollateralAndRedeemForUnderlier_BEFORE_maturity() public {
        fiat.transfer(address(userProxy), 100e18);

        vm.warp(block.timestamp + 24*3600);

        collateralAuction.redoAuction(1, me);

        NoLossCollateralAuctionSPTActions.RedeemParams memory redeemParams;
        redeemParams.adapter = maDAIAdapter;
        redeemParams.maturity = maturity;
        redeemParams.target = address(maDAI);
        redeemParams.underlierToken = address(dai);
        redeemParams.approveTarget= type(uint).max;

        assertEq(dai.balanceOf(address(userProxy)), 0);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndRedeemForUnderlier.selector,
                address(maDAIVault),
                0,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy),
                redeemParams
            )
        );
    }
}
