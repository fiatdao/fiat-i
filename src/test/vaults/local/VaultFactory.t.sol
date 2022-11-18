// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {Caller} from "../../../test/utils/Caller.sol";

import {IVaultInitializable, VaultFactory} from "../../../vaults/VaultFactory.sol";

contract Tony {
    address public root;

    function initialize(bytes calldata params) external {
        (root) = abi.decode(params, (address));
    }

    function whatIsYourName() external pure returns (string memory) {
        return "Tony";
    }
}

contract VaultFactoryUnitTest is Test {
    VaultFactory factory;
    Tony implementation;
    Caller kakaroto;
    bool ok;

    address internal me = address(this);

    function setUp() public {
        implementation = new Tony();
        kakaroto = new Caller();

        factory = new VaultFactory();
    }

    function test_createVault_guarded() public {
        (ok, ) = kakaroto.externalCall(
            address(factory),
            abi.encodeWithSelector(factory.createVault.selector, address(implementation), bytes(""))
        );
        assertTrue(ok == false, "Cannot call guarded method before adding permissions");

        factory.allowCaller(factory.createVault.selector, address(kakaroto));
        (ok, ) = kakaroto.externalCall(
            address(factory),
            abi.encodeWithSelector(factory.createVault.selector, address(implementation), bytes(""))
        );
        assertTrue(ok, "Can call method after adding permissions");
    }

    function test_createVault_deploys_a_impl_clone() public {
        address clone = factory.createVault(address(implementation), bytes(""));
        string memory name = Tony(clone).whatIsYourName();
        assertEq(name, string("Tony"), "Clone should have Tony implementation");
    }

    function test_createVault_should_append_sender_as_root() public {
        address clone = factory.createVault(address(implementation), bytes(""));
        assertEq(Tony(clone).root(), me);
    }
}
