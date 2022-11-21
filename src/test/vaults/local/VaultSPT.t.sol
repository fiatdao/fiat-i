// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Collybus} from "../../../core/Collybus.sol";
import {Codex} from "../../../core/Codex.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {WAD, toInt256, wmul, wdiv, sub, add} from "../../../core/utils/Math.sol";
import {Publican} from "../../../core/Publican.sol";
import {IVault} from "../../../interfaces/IVault.sol";

import {SenseToken} from "../../../test/utils/SenseToken.sol";
import {TestERC20} from "../../../test/utils/TestERC20.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";
import {VaultSPT} from "../../../vaults/VaultSPT.sol";

contract VaultSPT_Test is Test {
    Codex codex;
    Moneta moneta;
    FIAT fiat;
    Collybus collybus;
    Publican publican;

    // Token mocks
    SenseToken sP_cUSDC;
    SenseToken sP_cDAI;
    TestERC20 cUSDC;
    TestERC20 cDAI;
    TestERC20 usdc;
    TestERC20 dai;

    VaultFactory vaultFactory;
    VaultSPT impl;
    VaultSPT impl18;
    IVault vault;
    IVault vault18;

    address me = address(this);
    uint256 maturity = 1656633600; // 1st july 2022;

    function setUp() public {
        vaultFactory = new VaultFactory();
        fiat = new FIAT();
        codex = new Codex();
        publican = new Publican(address(codex));
        moneta = new Moneta(address(codex), address(fiat));

        sP_cUSDC = new SenseToken("sP_cUSDC", "sPT", 8, me);
        cUSDC = new TestERC20("cUSDC", "cUSDC", 8);
        usdc = new TestERC20("USDC", "USDC", 6);

        sP_cDAI = new SenseToken("sP_cDAI", "sPT", 18, me);
        cDAI = new TestERC20("cDAI", "cDAI", 18);
        dai = new TestERC20("DAI", "DAI", 18);

        collybus = new Collybus();
        impl = new VaultSPT(address(codex), address(cUSDC), address(usdc));
        impl18 = new VaultSPT(address(codex), address(cDAI), address(dai));

        vault = IVault(
            vaultFactory.createVault(
                address(impl),
                abi.encode(maturity, address(sP_cUSDC), address(collybus))
            )
        );
        vault18 = IVault(
            vaultFactory.createVault(
                address(impl18),
                abi.encode(maturity, address(sP_cDAI), address(collybus))
            )
        );

        assertEq(vault.live(), 1);
        assertEq(vault18.live(), 1);

        fiat.allowCaller(keccak256("ANY_SIG"), address(moneta));
        codex.allowCaller(keccak256("ANY_SIG"), address(publican));

        codex.init(address(vault));
        codex.init(address(vault18));

        // Config for codex and collybus
        codex.allowCaller(codex.ANY_SIG(), address(moneta));
        codex.setParam("globalDebtCeiling", 1000 ether);

        codex.setParam(address(vault), "debtCeiling", 1000 ether);
        collybus.setParam(address(vault), "liquidationRatio", 1 ether);
        collybus.updateSpot(address(usdc), WAD);
        // Set 18 decimals vault
        codex.setParam(address(vault18), "debtCeiling", 1000 ether);
        collybus.setParam(address(vault18), "liquidationRatio", 1 ether);
        collybus.updateSpot(address(dai), WAD);

        publican.init(address(vault));
        publican.init(address(vault18));

        codex.allowCaller(codex.ANY_SIG(), address(vault));
        codex.allowCaller(codex.ANY_SIG(), address(vault18));

        // "me" grant delegation to moneta
        codex.grantDelegate(address(moneta));
    }

    function test_vaultSPT_no_proxy_flow_8_decimals_cUSDC() public {
        uint256 sensePTs = 1e8; // 1 sPT
        sP_cUSDC.mint(me, sensePTs);
        assertEq(sP_cUSDC.balanceOf(me), sensePTs, "balance me spt");

        assertEq(codex.credit(me), 0, "credit me");
        sP_cUSDC.approve(address(vault), sensePTs);

        // 1 token for sP_cUSDC
        // Enter vault with sP_cUSDC
        vault.enter(0, me, sensePTs);

        assertEq(sP_cUSDC.balanceOf(address(vault)), sensePTs, "balance vault spt");
        // No credit yet
        assertEq(codex.credit(me), 0, "balance credit spt");
        // withdrawble balance updated in the vault
        assertEq(codex.balances(address(vault), 0, me), wdiv(sensePTs, 10**sP_cUSDC.decimals()), "codex balances");
        (uint256 collateral1, uint256 normalDebt1) = codex.positions(address(vault), 0, me);
        assertEq(collateral1, 0, "collateral");
        assertEq(normalDebt1, 0, "normalDebt");

        int256 collateralAdded = 1 ether;
        int256 debtTaken = 0.1 ether;

        // Use balance from vault as collateral and take a credit
        codex.modifyCollateralAndDebt(address(vault), 0, me, address(this), address(this), collateralAdded, debtTaken);
        // All balance is still in the vault
        assertEq(sP_cUSDC.balanceOf(address(vault)), sensePTs, "balance in vault");
        // got the credit
        assertEq(codex.credit(me), uint256(debtTaken), "debt taken");
        // vault balance is zero (moved everything as collateral)
        assertEq(codex.balances(address(vault), 0, me), 0, "again codex");
        // No fiat minted yet
        assertEq(fiat.balanceOf(me), 0);

        (uint256 collateral, uint256 normalDebt) = codex.positions(address(vault), 0, me);
        // Collateral and normal debt are as expected
        assertEq(collateral, uint256(collateralAdded));
        assertEq(normalDebt, uint256(debtTaken));

        // Credit is available
        assertEq(codex.credit(me), uint256(debtTaken));

        // exit moneta and get FIAT
        moneta.exit(me, uint256(debtTaken));
        // got FIAT and no more credit
        assertEq(fiat.balanceOf(me), uint256(debtTaken));
        assertEq(codex.credit(me), 0);

        // Approve moneta to burn fiat and get credit back
        fiat.approve(address(moneta), uint256(debtTaken));
        moneta.enter(me, uint256(debtTaken));

        // no more FIAT
        assertEq(fiat.balanceOf(me), 0);
        assertEq(codex.credit(me), uint256(debtTaken));

        // Pay back credit and remove collateral (now we can exit)
        codex.modifyCollateralAndDebt(
            address(vault),
            0,
            me,
            address(this),
            address(this),
            -collateralAdded,
            -debtTaken
        );

        assertEq(codex.credit(me), 0);

        // Withdraw from vault
        vault.exit(0, me, sensePTs);

        (uint256 collateralEnd, uint256 normalDebtEnd) = codex.positions(address(vault), 0, me);
        assertEq(collateralEnd, 0);
        assertEq(normalDebtEnd, 0);
        assertEq(fiat.balanceOf(me), 0);
    }

    function test_vaultSPT_no_proxy_flow_18_decimals_target() public {
        uint256 sensePTs = 1 ether; // 1 sPT
        sP_cDAI.mint(me, sensePTs);
        assertEq(sP_cDAI.balanceOf(me), sensePTs, "balance me spt");

        assertEq(codex.credit(me), 0, "credit me");
        sP_cDAI.approve(address(vault18), sensePTs);

        // 1 token for sP's target
        // Enter vault with sP_cUSDC
        vault18.enter(0, me, sensePTs);

        assertEq(sP_cDAI.balanceOf(address(vault18)), sensePTs, "balance vault spt");
        // No credit yet
        assertEq(codex.credit(me), 0, "balance credit spt");
        // withdrawble balance updated in the vault
        assertEq(codex.balances(address(vault18), 0, me), sensePTs, "codex balances");
        (uint256 collateral1, uint256 normalDebt1) = codex.positions(address(vault18), 0, me);
        assertEq(collateral1, 0, "collateral");
        assertEq(normalDebt1, 0, "normalDebt");

        int256 collateralAdded = 1 ether;
        int256 debtTaken = 0.1 ether;
        // Use balance from vault as collateral and take a credit
        codex.modifyCollateralAndDebt(
            address(vault18),
            0,
            me,
            address(this),
            address(this),
            collateralAdded,
            debtTaken
        );
        // All balance is still in the vault18
        assertEq(sP_cDAI.balanceOf(address(vault18)), sensePTs, "balance in vault18");
        // got the credit
        assertEq(codex.credit(me), uint256(debtTaken), "debt taken");
        // vault18 balance is zero (moved everything as collateral)
        assertEq(codex.balances(address(vault18), 0, me), 0, "again codex");
        // No fiat minted yet
        assertEq(fiat.balanceOf(me), 0);

        (uint256 collateral, uint256 normalDebt) = codex.positions(address(vault18), 0, me);
        // Collateral and normal debt are as expected
        assertEq(collateral, uint256(collateralAdded));
        assertEq(normalDebt, uint256(debtTaken));

        // Credit is available
        assertEq(codex.credit(me), uint256(debtTaken));

        // exit moneta and get FIAT
        moneta.exit(me, uint256(debtTaken));
        // got FIAT and no more credit
        assertEq(fiat.balanceOf(me), uint256(debtTaken));
        assertEq(codex.credit(me), 0);

        // Approve moneta to burn fiat and get credit back
        fiat.approve(address(moneta), uint256(debtTaken));
        moneta.enter(me, uint256(debtTaken));

        // no more FIAT
        assertEq(fiat.balanceOf(me), 0);
        assertEq(codex.credit(me), uint256(debtTaken));

        // Pay back credit and remove collateral (now we can exit)
        codex.modifyCollateralAndDebt(
            address(vault18),
            0,
            me,
            address(this),
            address(this),
            -collateralAdded,
            -debtTaken
        );

        assertEq(codex.credit(me), 0);

        // Withdraw from vault18
        vault18.exit(0, me, sensePTs);

        (uint256 collateralEnd, uint256 normalDebtEnd) = codex.positions(address(vault18), 0, me);
        assertEq(collateralEnd, 0);
        assertEq(normalDebtEnd, 0);
        assertEq(fiat.balanceOf(me), 0);
    }

    function test_codex() public {
        assertEq(address(vault.codex()), address(codex));
    }

    function test_collybus() public {
        assertEq(address(vault.collybus()), address(collybus));
    }

    function test_token() public {
        assertEq(vault.token(), address(sP_cUSDC));
    }

    function test_token18() public {
        assertEq(vault18.token(), address(sP_cDAI));
    }

    function test_tokenScale() public {
        assertEq(vault.tokenScale(), 10**sP_cUSDC.decimals());
    }

    function test_tokenScale18() public {
        assertEq(vault18.tokenScale(), 10**sP_cDAI.decimals());
    }

    function test_live() public {
        assertEq(uint256(vault.live()), uint256(1));
    }

    function test_maturity() public {
        assertEq(vault.maturity(0), maturity);
    }
    
    function test_maturity18() public {
        assertEq(vault18.maturity(0), maturity);
    }

    function test_underlierToken() public {
        assertEq(vault.underlierToken(), address(usdc));
    }
    
    function test_underlierToken18() public {
        assertEq(vault18.underlierToken(), address(dai));
    }

    function test_underlierScale() public {
        assertEq(vault.underlierScale(), 10**usdc.decimals());
    }
    
    function test_underlierScale18() public {
        assertEq(vault18.underlierScale(), 10**dai.decimals());
    }

    function test_vaultType() public {
        assertEq(vault.vaultType(), bytes32("ERC20:SPT"));
    }

     function test_vaultType18() public {
        assertEq(vault18.vaultType(), bytes32("ERC20:SPT"));
    }
}
