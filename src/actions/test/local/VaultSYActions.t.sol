// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {MockProvider} from "mockprovider/MockProvider.sol";

import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {Publican} from "../../../Publican.sol";

import {VaultSYActions} from "../../vault/VaultSYActions.sol";

contract VaultSYActionsUnitTest is Test {
    MockProvider fiat;
    MockProvider codex;
    MockProvider moneta;
    MockProvider mockVault;
    MockProvider mockCollateral;
    MockProvider publican;

    PRBProxy userProxy;
    PRBProxyFactory prbProxyFactory;

    VaultSYActions vaultActions;

    address me = address(this);

    function setUp() public {
        fiat = new MockProvider();
        codex = new MockProvider();
        moneta = new MockProvider();
        mockVault = new MockProvider();
        mockCollateral = new MockProvider();
        publican = new MockProvider();

        prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        vaultActions = new VaultSYActions(address(codex), address(moneta), address(fiat), address(publican));

        publican.givenSelectorReturnResponse(
            Publican.collect.selector,
            MockProvider.ReturnData({success: true, data: abi.encode(uint256(10 ** 18))}),
            false
        );
    }

    function testFail_increaseCollateral_when_vault_zero() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(0),
                address(mockCollateral),
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
                address(mockVault),
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
                address(mockCollateral),
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
                address(mockVault),
                address(mockCollateral),
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
                address(mockVault),
                address(mockCollateral),
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
