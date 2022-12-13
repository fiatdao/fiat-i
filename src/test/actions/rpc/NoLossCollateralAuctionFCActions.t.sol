// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
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
import {Vault20} from "../../../vaults/Vault.sol";
import {toInt256, WAD, sub, wdiv} from "../../../core/utils/Math.sol";

import {VaultFactory} from "../../../vaults/VaultFactory.sol";
import {VaultFCv2} from "../../../vaults/VaultFCv2.sol";
import {NoLossCollateralAuctionFCActions} from "../../../actions/auction/NoLossCollateralAuctionFCActions.sol";
import {VaultFCActions, INotional, Constants, EncodeDecode} from "../../../actions/vault/VaultFCActions.sol";
import {NotionalMinter} from "../../../test/vaults/rpc/VaultFC.t.sol";

contract NoLossCollateralAuctionFCActions_UnitTest is Test, ERC1155Holder{
    Codex internal codex;
    Moneta internal moneta;
    PRBProxy internal userProxy;
    PRBProxyFactory internal prbProxyFactory;
    VaultFactory internal vaultFactory;

    FIAT internal fiat;
    Collybus internal collybus;
    Publican internal publican;
    Aer internal aer;
    Limes internal limes;
    VaultFCv2 internal vault_impl;
    VaultFCv2 internal vaultFC_DAI;
    VaultFCActions internal vaultActions;
    NoLossCollateralAuction internal collateralAuction;
    NoLossCollateralAuctionFCActions internal auctionActions;

    address internal me = address(this);


    //  Notional
    NotionalMinter internal minterfDAI_1;

    IERC20 internal DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address internal cDAI = address(0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643);
    address internal notional = address(0x1344A36A1B56144C3Bc62E7757377D288fDE0369);
    IERC1155 internal notional1155 = IERC1155(notional);
    uint256 internal DAI_fCashId_1;
    uint256 internal DAI_fCashId_2;
    uint16 internal DAI_currencyId = 2;

    INotional.MarketParameters internal DAI_market_1;
    INotional.MarketParameters internal DAI_market_2;
    
    uint256 internal QUARTER = 86400 * 6 * 5 * 3;
    uint256 internal ONE_DAI = 1e18;
    uint256 internal ONE_FCASH = 1e8;

    uint256 internal collateralAmount = 100000000;

    uint internal maturity; 

    function setUp() public {        
        vm.createSelectFork(vm.rpcUrl("mainnet"), 13627845);

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

        // Notional
        vault_impl = new VaultFCv2(
            address(codex),
            address(collybus),
            notional,
            address(DAI), // cDAI,
            uint256(86400 * 6 * 5 * 3),
            DAI_currencyId
        );
        
        _mintDAI(me, 2000 ether);

        vaultFC_DAI = vault_impl;

        // set Vault
        codex.init(address(vaultFC_DAI));
        codex.allowCaller(codex.transferCredit.selector, address(moneta));
        codex.setParam("globalDebtCeiling", 500 ether);
        codex.setParam(address(vaultFC_DAI), "debtCeiling", 500 ether);
        collybus.setParam(address(vaultFC_DAI), "liquidationRatio", 1 ether);
        collybus.updateSpot(address(DAI), 1 ether);
        publican.init(address(vaultFC_DAI));
        codex.allowCaller(codex.modifyBalance.selector, address(vaultFC_DAI));

        calculator.setParam(bytes32("duration"), 100000);

        collateralAuction.init(address(vaultFC_DAI), address(collybus));
        collateralAuction.setParam(address(vaultFC_DAI), bytes32("maxAuctionDuration"), 200000);
        collateralAuction.setParam(address(vaultFC_DAI), bytes32("calculator"), address(calculator));
        collateralAuction.allowCaller(collateralAuction.ANY_SIG(), address(limes));

        limes.setParam(bytes32("globalMaxDebtOnAuction"), 500e18);
        limes.setParam(bytes32("aer"), address(aer));
        limes.setParam(address(vaultFC_DAI), bytes32("liquidationPenalty"), WAD);
        limes.setParam(address(vaultFC_DAI), bytes32("maxDebtOnAuction"), 500e18);
        limes.setParam(address(vaultFC_DAI), bytes32("collateralAuction"), address(collateralAuction));
        limes.allowCaller(limes.ANY_SIG(), address(collateralAuction));

        aer.allowCaller(aer.ANY_SIG(), address(limes));
        aer.allowCaller(aer.ANY_SIG(), address(collateralAuction));

        codex.allowCaller(codex.ANY_SIG(), address(moneta));
        codex.allowCaller(codex.ANY_SIG(), address(vaultFC_DAI));
        codex.allowCaller(codex.ANY_SIG(), address(limes));
        codex.allowCaller(codex.ANY_SIG(), address(collateralAuction));

        DAI.approve(address(userProxy), type(uint256).max);

        // Notional
        INotional.MarketParameters[] memory markets = INotional(notional).getActiveMarkets(2);
        maturity = markets[0].maturity;
        minterfDAI_1 = new NotionalMinter(notional, 2, uint40(markets[0].maturity));
        DAI_fCashId_1 = minterfDAI_1.getfCashId();

        IERC20(DAI).approve(address(minterfDAI_1), type(uint256).max);
      
        minterfDAI_1.mintFromUnderlying(1000 * ONE_FCASH, me);
 
        IERC1155(notional).setApprovalForAll(address(vaultFC_DAI), true);
        vaultFC_DAI.enter(DAI_fCashId_1, me, IERC1155(notional).balanceOf(me, DAI_fCashId_1));

        codex.modifyCollateralAndDebt(address(vaultFC_DAI), DAI_fCashId_1, me, me, me, 1000e18, 500e18);
        
        // update price so we can liquidate
        collybus.updateSpot(address(DAI), 0.4 ether);

        limes.liquidate(address(vaultFC_DAI), DAI_fCashId_1, me, me);

        // re-update price
        collybus.updateSpot(address(DAI), 1 ether);

        auctionActions = new NoLossCollateralAuctionFCActions(
            address(codex),
            address(moneta),
            address(fiat),
            address(collateralAuction),
            notional
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

    function _mintDAI(address to, uint256 amount) internal {
        vm.store(address(DAI), keccak256(abi.encode(address(address(this)), uint256(0))), bytes32(uint256(1)));
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(DAI).call(abi.encodeWithSignature(sig, to, amount));
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

    function test_takeCollateral() public {
        collateralAuction.redoAuction(1, me);
        fiat.transfer(address(userProxy), 100e18);

        uint256 fiatBalance = fiat.balanceOf(address(userProxy));
        uint256 collateralBalance = codex.balances(address(vaultFC_DAI), DAI_fCashId_1, address(userProxy));

        vm.warp(block.timestamp + 100);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateral.selector,
                address(vaultFC_DAI),
                DAI_fCashId_1,
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
        assertLt(collateralBalance, codex.balances(address(vaultFC_DAI), DAI_fCashId_1, address(userProxy)));
    }

    function test_takeCollateral_from_user_BEFORE_maturity() public {
        collateralAuction.redoAuction(1, me);
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = codex.balances(address(vaultFC_DAI), DAI_fCashId_1, me);

        vm.warp(block.timestamp + 100);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateral.selector,
                address(vaultFC_DAI),
                DAI_fCashId_1,
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
         // we have the collateral in FIAT system
        assertLt(collateralBalance, codex.balances(address(vaultFC_DAI), DAI_fCashId_1, me));
    }

    function test_takeCollateral_from_user_AFTER_maturity() public {
      
        vm.warp(maturity + 1);
        collateralAuction.redoAuction(1, me);
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = codex.balances(address(vaultFC_DAI), DAI_fCashId_1, me);
        assertEq(collateralBalance, 0);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateral.selector,
                address(vaultFC_DAI),
                DAI_fCashId_1,
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
        // we have the collateral in FIAT system
        assertLt(collateralBalance, codex.balances(address(vaultFC_DAI), DAI_fCashId_1, me));
    }

    function test_takeCollateralAndSwapForUnderlier_BEFORE_maturity() public {
        fiat.transfer(address(userProxy), 100e18);
        uint256 collateralBalance = notional1155.balanceOf(address(userProxy), DAI_fCashId_1 );

        assertEq(collateralBalance, 0);

        vm.warp(block.timestamp + 100);
        collateralAuction.redoAuction(1, me);

        assertEq(DAI.balanceOf(address(userProxy)), 0);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndSwapForUnderlier.selector,
                address(vaultFC_DAI),
                DAI_fCashId_1,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy),
                1e9
            )
        );

        // we have more DAI than before
        assertGt(DAI.balanceOf(address(userProxy)), 0);
        // used all FIAT
        assertEq(fiat.balanceOf(address(userProxy)), 0);
        // No collateral left in FIAT
        assertEq(codex.balances(address(vaultFC_DAI), DAI_fCashId_1, address(userProxy)), 0);
        // No collateral transferred
        assertEq(collateralBalance, notional1155.balanceOf(address(userProxy), DAI_fCashId_1 ));
    }

    function test_takeCollateralAndSwapForUnderlier_from_user_BEFORE_maturity() public {
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = notional1155.balanceOf(me, DAI_fCashId_1 );
        assertEq(fiatBalance, 100e18);
        assertEq(collateralBalance, 0);

        vm.warp(block.timestamp + 100);
        collateralAuction.redoAuction(1, me);

        uint256 daiBefore = DAI.balanceOf(me);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndSwapForUnderlier.selector,
                address(vaultFC_DAI),
                DAI_fCashId_1,
                me,
                1,
                100e18,
                1e18,
                me,
                1e9
            )
        );

        // we have more DAI than before
        assertGt(DAI.balanceOf(me), daiBefore);
        // used all FIAT
        assertEq(fiat.balanceOf(address(me)), 0);
        // No collateral left in FIAT
        assertEq(codex.balances(address(vaultFC_DAI), DAI_fCashId_1, me), 0);
        assertEq(codex.balances(address(vaultFC_DAI), DAI_fCashId_1, address(auctionActions)), 0);
        // No collateral transferred
        assertEq(collateralBalance, notional1155.balanceOf(me, DAI_fCashId_1 ));
    }

    function test_takeCollateralAndRedeemForUnderlier_AFTER_maturity() public {
        fiat.transfer(address(userProxy), 100e18);
        uint256 fiatBalance = fiat.balanceOf(address(userProxy));
        uint256 collateralBalance = notional1155.balanceOf(address(userProxy), DAI_fCashId_1);

        // Move post maturity
        vm.warp(maturity + 1);

        collateralAuction.redoAuction(1, me);

        uint256 daiBefore = DAI.balanceOf(address(userProxy));
    
        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndRedeemForUnderlier.selector,
                address(vaultFC_DAI),
                DAI_fCashId_1,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy)
            )
        );

        // DAI balance increased
        assertGt(DAI.balanceOf(address(userProxy)), daiBefore);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(address(userProxy)));
        // No collateral left in FIAT
        assertEq(codex.balances(address(vaultFC_DAI), DAI_fCashId_1, address(userProxy)), 0);
        assertEq(codex.balances(address(vaultFC_DAI), DAI_fCashId_1, address(auctionActions)), 0);
        // No collateral transferred
        assertEq(collateralBalance, notional1155.balanceOf(address(userProxy), DAI_fCashId_1));
    }

    function test_takeCollateralAndRedeemForUnderlier_from_user_AFTER_maturity() public {
        fiat.transfer(me, 100e18);
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = notional1155.balanceOf(me, DAI_fCashId_1);

        // Move post maturity
        vm.warp(maturity + 1);

        collateralAuction.redoAuction(1, me);

        uint256 daiBefore = DAI.balanceOf(me);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndRedeemForUnderlier.selector,
                address(vaultFC_DAI),
                DAI_fCashId_1,
                me,
                1,
                100e18,
                1e18,
                me
            )
        );

        // we have more DAI
        assertGt(DAI.balanceOf(me), daiBefore);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(me));
        // No collateral left in FIAT
        assertEq(codex.balances(address(vaultFC_DAI), DAI_fCashId_1, me), 0);
        // No collateral transferred
        assertEq(collateralBalance, notional1155.balanceOf(me, DAI_fCashId_1 ));
    }
}
