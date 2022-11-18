// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {Publican} from "../../../core/Publican.sol";

import {VaultSYActions} from "../../../actions/vault/VaultSYActions.sol";

contract VaultSYActionsUnitTest is Test {
    address fiat = address(0xf1a7);
    address codex = address(0xc0d311);
    address moneta = address(0x11101137a);

    //keccak256(abi.encode("mockVault"));
    address mockVault = address(0x4E0075d8C837f8fb999012e556b7A63FC65fceDa);

    //keccak256(abi.encode("mockCollateral"));
    address mockCollateral = address(0x624646310fa836B250c9285b044CB443c741f663);

    //keccak256(abi.encode("publican"));
    address publican = address(0xDF68e6705C6Cc25E78aAC874002B5ab31b679db4);

    PRBProxy userProxy;
    PRBProxyFactory prbProxyFactory;

    VaultSYActions vaultActions;

    address me = address(this);

    function setUp() public {
        prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        vaultActions = new VaultSYActions(codex, moneta, fiat, publican);

        vm.mockCall(publican, abi.encodeWithSelector(Publican.collect.selector), abi.encode(uint256(10**18)));
    }

    function testFail_increaseCollateral_when_vault_zero() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(0),
                mockCollateral,
                0,
                address(userProxy),
                me,
                address(0),
                1,
                0
            )
        );
    }

    function testFail_increaseCollateral_when_token_zero() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                mockVault,
                address(0),
                0,
                address(userProxy),
                me,
                address(0),
                1,
                0
            )
        );
    }

    function testFail_decreaseCollateral_when_vault_zero() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(0),
                mockCollateral,
                0,
                address(userProxy),
                me,
                address(0),
                -1,
                0
            )
        );
    }

    function testFail_decreaseCollateral_to_zero_address() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                mockVault,
                mockCollateral,
                0,
                address(userProxy),
                address(0),
                me,
                -1,
                0
            )
        );
    }

    function testFail_increaseDebt_to_zero_address() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                mockVault,
                mockCollateral,
                0,
                address(userProxy),
                me,
                address(0),
                0,
                1
            )
        );
    }
}
