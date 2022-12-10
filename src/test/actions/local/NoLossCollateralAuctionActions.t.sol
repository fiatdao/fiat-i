// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import "forge-std/Vm.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {Aer} from "../../../core/Aer.sol";
import {Codex} from "../../../core/Codex.sol";
import {NoLossCollateralAuction} from "../../../core/auctions/NoLossCollateralAuction.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {Limes} from "../../../core/Limes.sol";
import {LinearDecrease} from "../../../core/auctions/PriceCalculator.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {Publican} from "../../../core/Publican.sol";
import {Vault20} from "../../../vaults/Vault.sol";
import {toInt256, WAD, sub, wdiv} from "../../../core/utils/Math.sol";

import {TestERC20} from "../../../test/utils/TestERC20.sol";

import {NoLossCollateralAuctionActionsBase} from "../../../actions/auction/NoLossCollateralAuctionActionsBase.sol";

contract Vault20Actions_UnitTest is Test {
    Aer internal aer;
    Codex internal codex;
    NoLossCollateralAuction internal collateralAuction;
    address internal collybus = address(0xc0111b115);
    FIAT internal fiat;
    Limes internal limes;
    Moneta internal moneta;
    Publican internal publican;
    Vault20 internal vault;
    TestERC20 internal collateralToken;

    PRBProxy internal userProxy;

    NoLossCollateralAuctionActionsBase internal auctionActions;

    address me = address(this);

    function setUp() public {
        fiat = new FIAT();
        codex = new Codex();
        aer = new Aer(address(codex), address(0), address(0));
        moneta = new Moneta(address(codex), address(fiat));
        limes = new Limes(address(codex));
        collateralAuction = new NoLossCollateralAuction(address(codex), address(limes));
        LinearDecrease calculator = new LinearDecrease();
        collateralToken = new TestERC20("", "", 18);
        vault = new Vault20(address(codex), address(collateralToken), collybus);

        calculator.setParam(bytes32("duration"), 100000);

        collateralAuction.init(address(vault), collybus);
        collateralAuction.setParam(address(vault), bytes32("maxAuctionDuration"), 200000);
        collateralAuction.setParam(address(vault), bytes32("calculator"), address(calculator));

        collateralAuction.allowCaller(collateralAuction.ANY_SIG(), address(limes));

        limes.setParam(bytes32("globalMaxDebtOnAuction"), 500e18);
        limes.setParam(bytes32("aer"), address(aer));
        limes.setParam(address(vault), bytes32("liquidationPenalty"), WAD);
        limes.setParam(address(vault), bytes32("maxDebtOnAuction"), 500e18);
        limes.setParam(address(vault), bytes32("collateralAuction"), address(collateralAuction));

        limes.allowCaller(limes.ANY_SIG(), address(collateralAuction));

        aer.allowCaller(aer.ANY_SIG(), address(limes));
        aer.allowCaller(aer.ANY_SIG(), address(collateralAuction));

        codex.init(address(vault));
        codex.setParam(bytes32("globalDebtCeiling"), 500e18);
        codex.setParam(address(vault), bytes32("debtCeiling"), 500e18);

        codex.allowCaller(codex.ANY_SIG(), address(moneta));
        codex.allowCaller(codex.ANY_SIG(), address(vault));
        codex.allowCaller(codex.ANY_SIG(), address(limes));
        codex.allowCaller(codex.ANY_SIG(), address(collateralAuction));

        vm.mockCall(collybus, abi.encodeWithSelector(Collybus.read.selector), abi.encode(uint256(WAD)));
        
        collateralToken.mint(me, 1000e18);
        collateralToken.approve(address(vault), 1000e18);
        vault.enter(0, me, 1000e18);
        codex.modifyCollateralAndDebt(address(vault), 0, me, me, me, 1000e18, 500e18);

        vm.mockCall(collybus, abi.encodeWithSelector(Collybus.read.selector), abi.encode(uint256(0.4e18)));

        limes.liquidate(address(vault), 0, me, me);

        vm.mockCall(collybus, abi.encodeWithSelector(Collybus.read.selector), abi.encode(uint256(WAD)));

        collateralAuction.redoAuction(1, me);

        auctionActions = new NoLossCollateralAuctionActionsBase(
            address(codex),
            address(moneta),
            address(fiat),
            address(collateralAuction)
        );

        PRBProxyFactory prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        fiat.allowCaller(keccak256("ANY_SIG"), address(moneta));
        codex.createUnbackedDebt(address(userProxy), address(userProxy), 100e18);

        codex.grantDelegate(address(moneta));
        moneta.exit(me, 100e18);

        fiat.approve(address(userProxy), 100e18);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(auctionActions.approveFIAT.selector, address(moneta), 100e18)
        );
    }

    function test_takeCollateral() public {
        fiat.transfer(address(userProxy), 100e18);

        uint256 fiatBalance = fiat.balanceOf(address(userProxy));
        uint256 collateralBalance = codex.balances(address(vault), 0, address(userProxy));
        assertEq(collateralBalance, 0);

        vm.warp(block.timestamp + 100);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateral.selector,
                address(vault),
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
        // we have the collateral in FIAT system
        assertGt(codex.balances(address(vault), 0, address(userProxy)), collateralBalance);
    }

    function test_takeCollateral_from_user() public {
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = codex.balances(address(vault), 0, me);
        assertEq(collateralBalance, 0);

        vm.warp(block.timestamp + 100);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(auctionActions.takeCollateral.selector, address(vault), 0, me, 1, 100e18, 1e18, me)
        );

        // should have refunded excess FIAT
        assertGt(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(me));
        // we have the collateral in FIAT system
        assertGt(codex.balances(address(vault), 0, me), collateralBalance);
    }
}
