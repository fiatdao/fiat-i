// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {Codex} from "../../../core/Codex.sol";
import {Publican} from "../../../core/Publican.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {IMoneta} from "../../../interfaces/IMoneta.sol";
import {IVault} from "../../../interfaces/IVault.sol";

import {Vault20Actions} from "../../../actions/vault/Vault20Actions.sol";

interface IERC20Safe {
    function safeTransfer(address to, uint256 value) external;

    function safeTransferFrom(
        address from,
        address to,
        uint256 value
    ) external;
}

contract Vault20Actions_UnitTest is Test {
    Codex codex;
    Moneta moneta;

    // keccak256(abi.encode(0x624646310fa836B250c9285b044CB443c741f663))
    address mockCollateral = address(0x624646310fa836B250c9285b044CB443c741f663);
    PRBProxy userProxy;
    PRBProxyFactory prbProxyFactory;
    Vault20Actions vaultActions;
    FIAT fiat;

    address me = address(this);

    function setUp() public {
        fiat = new FIAT();
        codex = new Codex();
        moneta = new Moneta(address(codex), address(fiat));

        prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        vaultActions = new Vault20Actions(address(codex), address(moneta), address(fiat), address(0));

        fiat.allowCaller(keccak256("ANY_SIG"), address(moneta));
        codex.createUnbackedDebt(address(userProxy), address(userProxy), 100);

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), 100)
        );
    }

    function test_exitMoneta() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.exitMoneta.selector, address(userProxy), 100)
        );

        assertEq(codex.credit(address(userProxy)), 0);
        assertEq(fiat.balanceOf(address(userProxy)), 100);
        assertEq(codex.credit(address(moneta)), 100);
        assertEq(fiat.balanceOf(address(moneta)), 0);
    }

    function test_exitMoneta_to_user() public {
        userProxy.execute(address(vaultActions), abi.encodeWithSelector(vaultActions.exitMoneta.selector, me, 100));

        assertEq(codex.credit(address(userProxy)), 0);
        assertEq(fiat.balanceOf(address(userProxy)), 0);
        assertEq(codex.credit(address(moneta)), 100);
        assertEq(fiat.balanceOf(address(moneta)), 0);
        assertEq(fiat.balanceOf(me), 100);
    }

    function test_enterMoneta() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.exitMoneta.selector, address(userProxy), 100)
        );
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.enterMoneta.selector, address(userProxy), 100)
        );

        assertEq(fiat.balanceOf(address(userProxy)), 0);
        assertEq(codex.credit(address(userProxy)), 100);
        assertEq(codex.credit(address(moneta)), 0);
    }

    function test_enterMoneta_from_user() public {
        userProxy.execute(address(vaultActions), abi.encodeWithSelector(vaultActions.exitMoneta.selector, me, 100));

        fiat.approve(address(userProxy), 100);

        userProxy.execute(address(vaultActions), abi.encodeWithSelector(vaultActions.enterMoneta.selector, me, 100));

        assertEq(fiat.balanceOf(me), 0);
        assertEq(codex.credit(address(userProxy)), 100);
        assertEq(codex.credit(address(moneta)), 0);
    }
}
