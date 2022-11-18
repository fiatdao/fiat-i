// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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

contract VaultSPT_Test_rpc is Test {
    Codex codex;
    Moneta moneta;
    FIAT fiat;
    address collybus = address(0xc0111b115);
    Publican publican;

    IERC20 sP_cUSDC; // spToken
    IERC20 cUSDC; // target
    IERC20 usdc; // underlier
    IERC20 weth; // underlier

    IERC20 sP_wstETH; // spToken
    IERC20 wstETH; // target

    VaultFactory vaultFactory;
    VaultSPT impl_sP_cUSDC;
    VaultSPT impl_sP_wstETH;
    IVault vault_sP_cUSDC;
    IVault vault_sP_wstETH;

    address sP_cUSDC_Account;
    address sP_wstETH_Account;
    address me = address(this);
    uint256 maturity = 1656633600; // 1st july 2022;
    uint256 sPTs = 1e8; // 1 sPT 8 decimals cUSDC
    uint256 sPTEs = 0.5 ether; // 0.5 sPT 18 decimals wstETH

    function setUp() public {
        // Fork during buying window
        vm.createSelectFork(vm.rpcUrl("mainnet"), 14977810); // Jun-17-2022

        sP_cUSDC = IERC20(address(0xb636ADB2031DCbf6e2A04498e8Af494A819d4CB9)); // 8 decimals)
        sP_wstETH = IERC20(address(0xc1Fd90b0C31CF4BF16C04Ed8c6A05105EFc7c989)); // (18 decimals)

        cUSDC = IERC20(address(0x39AA39c021dfbaE8faC545936693aC917d5E7563)); // cUSDC from compound (target)
        wstETH = IERC20(address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0)); // wstETH (target)
        usdc = IERC20(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)); // USDC mainnet (underlier)
        weth = IERC20(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)); // weth underlier

        sP_cUSDC_Account = address(0x0B4509F330Ff558090571861a723F71657a26f78); // account with sP_cUSDC
        sP_wstETH_Account = address(0xa4a1BC8c47Ab8AF831d043233974B1107Ae87412); // account with sP_wstETH

        vaultFactory = new VaultFactory();
        codex = new Codex();

        impl_sP_cUSDC = new VaultSPT(address(codex), address(cUSDC), address(usdc));
        impl_sP_wstETH = new VaultSPT(address(codex), address(wstETH), address(weth));

        vault_sP_cUSDC = IVault(
            vaultFactory.createVault(
                address(impl_sP_cUSDC),
                abi.encode(maturity, address(sP_cUSDC), collybus)
            )
        );
        assertEq(vault_sP_cUSDC.live(), 1);

        vault_sP_wstETH = IVault(
            vaultFactory.createVault(
                address(impl_sP_wstETH),
                abi.encode(maturity, address(sP_wstETH), collybus)
            )
        );
        assertEq(vault_sP_wstETH.live(), 1);

        // Allow sP_cUSDC Vault in fiat
        codex.allowCaller(codex.modifyBalance.selector, address(vault_sP_cUSDC));

        // Allow sP_wstETH Vault
        codex.allowCaller(codex.modifyBalance.selector, address(vault_sP_wstETH));

        // take some sP tokens from users
        vm.prank(sP_cUSDC_Account);
        sP_cUSDC.transfer(me, sPTs);

        vm.prank(sP_wstETH_Account);
        sP_wstETH.transfer(me, sPTEs);
    }

    function _balance(address _vault, address _user) internal view returns (uint256) {
        return codex.balances(_vault, 0, _user);
    }

    function test_enter_and_exit_no_proxy_flow_8_decimals_cUSDC() public {
        // check that we have PTs
        assertEq(sP_cUSDC.balanceOf(me), sPTs);

        sP_cUSDC.approve(address(vault_sP_cUSDC), sPTs);

        assertEq(sP_cUSDC.balanceOf(address(vault_sP_cUSDC)), 0);
        assertEq(_balance(address(vault_sP_cUSDC), me), 0);
        // 1 token for sPT cUSDC
        // Enter vault_sP_cUSDC with sP_cUSDC
        vault_sP_cUSDC.enter(0, me, sPTs);

        assertEq(sP_cUSDC.balanceOf(address(vault_sP_cUSDC)), sPTs);

        // token is scale to 1e18 in codex
        assertEq(_balance(address(vault_sP_cUSDC), me), wdiv(sPTs, 10**IERC20Metadata(address(sP_cUSDC)).decimals()));

        // Withdraw from vault_sP_cUSDC
        vault_sP_cUSDC.exit(0, me, sPTs);

        assertEq(sP_cUSDC.balanceOf(address(vault_sP_cUSDC)), 0);
        assertEq(sP_cUSDC.balanceOf(address(me)), sPTs);
        assertEq(_balance(address(vault_sP_cUSDC), me), 0);
    }

    function test_enter_and_exit_no_proxy_flow_18_decimals_wstETH() public {
        // check that we have the PTs
        assertEq(sP_wstETH.balanceOf(me), sPTEs);

        sP_wstETH.approve(address(vault_sP_wstETH), sPTEs);
        assertEq(_balance(address(vault_sP_wstETH), me), 0);
        // 0.5 sP_wstETH
        // Enter vault_sP_cUSDC with sP_cUSDC
        vault_sP_wstETH.enter(0, me, sPTEs);

        assertEq(sP_wstETH.balanceOf(address(vault_sP_wstETH)), sPTEs);
        assertEq(_balance(address(vault_sP_wstETH), me), sPTEs);
        // Withdraw from vault_sP_wstETH
        vault_sP_wstETH.exit(0, me, sPTEs);

        assertEq(sP_wstETH.balanceOf(address(vault_sP_wstETH)), 0);
        assertEq(sP_wstETH.balanceOf(address(me)), sPTEs);
        assertEq(_balance(address(vault_sP_wstETH), me), 0);
    }

    function test_fairPrice_calls_into_collybus_face() public {
        uint256 fairPriceExpected = 96;
        bytes memory query = abi.encodeWithSelector(
            Collybus.read.selector,
            address(vault_sP_cUSDC),
            address(usdc),
            0,
            block.timestamp,
            true
        );

        vm.mockCall(
            collybus,
            query,
            abi.encode(uint256(fairPriceExpected))
        );

        uint256 fairPriceReturned = vault_sP_cUSDC.fairPrice(0, true, true);
        assertEq(fairPriceReturned, fairPriceExpected);
    }

    function test_fairPrice_calls_into_collybus_no_face() public {
        uint256 fairPriceExpected = 100;
        bytes memory query = abi.encodeWithSelector(
            Collybus.read.selector,
            address(vault_sP_cUSDC),
            address(usdc),
            0,
            maturity,
            true
        );

        vm.mockCall(collybus, query, abi.encode(uint256(fairPriceExpected)));
        uint256 fairPriceReturned = vault_sP_cUSDC.fairPrice(0, true, false);
        assertEq(fairPriceReturned, fairPriceExpected);
    }

    function test_maturity() public {
        assertEq(maturity, vault_sP_cUSDC.maturity(0));
        assertEq(maturity, vault_sP_wstETH.maturity(0));
    }
}
