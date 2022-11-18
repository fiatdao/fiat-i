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
import {SenseToken} from "../../../test/utils/SenseToken.sol";
import {TestERC20} from "../../../test/utils/TestERC20.sol";
import {Caller} from "../../../test/utils/Caller.sol";

contract VaultSPTActions_UnitTest is Test {
    Codex codex;
    Moneta moneta;

    SenseToken sP_cDAI;
    TestERC20 cDAI;
    TestERC20 dai;

    PRBProxy userProxy;
    PRBProxyFactory prbProxyFactory;

    VaultSPTActions internal vaultActions;
    IVault vaultSense;
    VaultFactory vaultFactory;
    VaultSPT impl;
    FIAT fiat;

    // keccak256(abi.encode("periphery"))
    address public periphery = address(0x2E4539d290929511560fcACf8d16Bb4D8590Fc8f);
    // keccak256(abi.encode("divider"))
    address public divider = address(0x70484eac7e3661b7562f465E7b6F939A3F45D254);

    Collybus collybus;
    Publican publican;

    address me = address(this);
    uint256 defaultPTokenAmount;
    address internal balancerVault;

    function setUp() public {
        vaultFactory = new VaultFactory();
        fiat = new FIAT();
        codex = new Codex();
        publican = new Publican(address(codex));
        moneta = new Moneta(address(codex), address(fiat));
        collybus = new Collybus();
        prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        // allow moneta to call mint on fiat
        fiat.allowCaller(fiat.mint.selector, address(moneta));

        // Config for codex
        codex.allowCaller(codex.modifyRate.selector, address(publican));
        codex.allowCaller(codex.transferCredit.selector, address(moneta));
        codex.setParam("globalDebtCeiling", 1000 ether);

        dai = new TestERC20("DAI", "DAI", 18); // DAI
        cDAI = new TestERC20("cDAI", "cDAI", 18); // Compound cDAI
        sP_cDAI = new SenseToken("sP_cDAI", "sPT", 18, me); // Sense Finance cDAI Principal Token

        impl = new VaultSPT(address(codex), address(cDAI), address(dai));
        vaultSense = IVault(
            vaultFactory.createVault(
                address(impl),
                abi.encode(block.timestamp + 8 weeks, address(sP_cDAI), address(collybus))
            )
        );
        balancerVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

        vaultActions = new VaultSPTActions(
            address(codex),
            address(moneta),
            address(fiat),
            address(publican),
            periphery,
            divider
        );

        // set Vault
        codex.init(address(vaultSense));
        codex.setParam(address(vaultSense), "debtCeiling", 1000 ether);
        collybus.setParam(address(vaultSense), "liquidationRatio", 1 ether);
        collybus.updateSpot(address(dai), 1 ether);
        publican.init(address(vaultSense));
        codex.allowCaller(codex.modifyBalance.selector, address(vaultSense));

        // mint some sPT
        defaultPTokenAmount = 100 ether;
        sP_cDAI.mint(me, defaultPTokenAmount);
        assertEq(sP_cDAI.balanceOf(me), defaultPTokenAmount);
    }

    function test_enter_and_exit_no_proxy() public {
        // approve vaultActions for sP_cDAI
        sP_cDAI.approve(address(vaultActions), type(uint256).max);

        uint256 sP_cDAIs = 5 ether;

        // Enter vault with sP_cDAI
        vaultActions.enterVault(address(vaultSense), address(sP_cDAI), 0, me, sP_cDAIs);

        assertEq(sP_cDAI.balanceOf(me), defaultPTokenAmount - sP_cDAIs);
        assertEq(sP_cDAI.balanceOf(address(vaultSense)), sP_cDAIs);

        // Exit vault
        vaultActions.exitVault(address(vaultSense), address(sP_cDAI), 0, me, sP_cDAIs);

        assertEq(sP_cDAI.balanceOf(me), defaultPTokenAmount);
        assertEq(sP_cDAI.balanceOf(address(vaultSense)), 0);
    }

    function test_enter_and_exit() public {
        assertEq(sP_cDAI.balanceOf(me), defaultPTokenAmount);
        assertEq(sP_cDAI.balanceOf(address(vaultSense)), 0);
        assertEq(sP_cDAI.balanceOf(address(userProxy)), 0);

        sP_cDAI.approve(address(userProxy), type(uint256).max);

        uint256 sP_cDAIs = 23 ether;

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.enterVault.selector,
                address(vaultSense),
                address(sP_cDAI),
                0,
                me,
                sP_cDAIs
            )
        );

        assertEq(sP_cDAI.balanceOf(me), defaultPTokenAmount - sP_cDAIs);
        assertEq(sP_cDAI.balanceOf(address(vaultSense)), sP_cDAIs);
        assertEq(sP_cDAI.balanceOf(address(userProxy)), 0);

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.exitVault.selector,
                address(vaultSense),
                address(sP_cDAI),
                0,
                me,
                sP_cDAIs
            )
        );

        assertEq(sP_cDAI.balanceOf(me), defaultPTokenAmount);
        assertEq(sP_cDAI.balanceOf(address(vaultSense)), 0);
        assertEq(sP_cDAI.balanceOf(address(userProxy)), 0);
    }

    function test_modifyCollateralAndDebt_no_proxy() public {
        // approve vaultActions for sP_cDAI
        sP_cDAI.approve(address(vaultActions), 100 ether);

        uint256 sP_cDAIs = 1 ether;

        int256 collateralAdded = 1 ether;
        int256 debtTaken = 0.1 ether;

        // "me" grant delegation to moneta and vaultActions for modifying collateral and fiat
        codex.grantDelegate(address(vaultActions));
        codex.grantDelegate(address(moneta));

        vaultActions.modifyCollateralAndDebt(
            address(vaultSense),
            address(sP_cDAI),
            0,
            me,
            address(this),
            address(this),
            collateralAdded,
            debtTaken
        );

        assertEq(sP_cDAI.balanceOf(address(vaultSense)), sP_cDAIs);
        // Already no credit bc fiat is minted
        assertEq(codex.credit(me), 0);
        assertEq(fiat.balanceOf(me), uint256(debtTaken));

        // approve moneta to burn fiat tokens from vaultActions
        vaultActions.approveFIAT(address(moneta), 100 ether);
        // approve vaultActions for fiat
        fiat.approve(address(vaultActions), 100 ether);

        vaultActions.modifyCollateralAndDebt(
            address(vaultSense),
            address(sP_cDAI),
            0,
            me,
            address(this),
            address(this),
            -collateralAdded,
            -debtTaken
        );

        assertEq(sP_cDAI.balanceOf(me), 100 ether);
        assertEq(fiat.balanceOf(me), 0);
    }

    function test_modifyCollateralAndDebt() public {
        // Approve moneta to burn fiat from vaultActions
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), 100 ether)
        );

        sP_cDAI.approve(address(userProxy), 100 ether);

        fiat.approve(address(userProxy), 100 ether);

        assertEq(sP_cDAI.balanceOf(me), 100 ether);
        assertEq(sP_cDAI.balanceOf(address(userProxy)), 0);

        assertEq(codex.credit(me), 0);

        uint256 sP_cDAIs = 1 ether;

        int256 collateralAdded = 1 ether;
        int256 debtTaken = 0.1 ether;

        // // "me" grant delegation to userProxy

        codex.grantDelegate(address(userProxy));

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vaultSense),
                address(sP_cDAI),
                0,
                me,
                me,
                me,
                collateralAdded,
                debtTaken
            )
        );

        assertEq(sP_cDAI.balanceOf(address(vaultSense)), sP_cDAIs);
        // Already no creadit credit
        assertEq(codex.credit(me), 0);

        assertEq(fiat.balanceOf(me), uint256(debtTaken));

        assertEq(sP_cDAI.balanceOf(me), 99 ether);
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vaultSense),
                address(sP_cDAI),
                0,
                me,
                me,
                me,
                -collateralAdded,
                -debtTaken
            )
        );

        assertEq(fiat.balanceOf(me), 0);

        assertEq(sP_cDAI.balanceOf(me), 100 ether);
    }
}
