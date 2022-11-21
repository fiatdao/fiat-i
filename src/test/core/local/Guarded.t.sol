// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {Caller} from "../../utils/Caller.sol";

import {Guarded} from "../../../core/utils/Guarded.sol";

contract GuardedInstance is Guarded {
    constructor() Guarded() {}

    function guardedMethod() external checkCaller {}

    function guardedMethodRoot() external checkCaller {}
}

contract GuardedTest is Test {
    GuardedInstance guarded;

    function setUp() public {
        guarded = new GuardedInstance();
    }

    function test_anyone() public {
        Caller anyone = new Caller();
        bool ok;
        bool canCall;

        // Should not be able to call method initially
        (ok, ) = anyone.externalCall(address(guarded), abi.encodeWithSelector(guarded.guardedMethod.selector));
        assertTrue(ok == false);

        // Allow anyone to call method
        guarded.allowCaller(guarded.guardedMethod.selector, guarded.ANY_CALLER());
        canCall = guarded.canCall(guarded.guardedMethod.selector, address(anyone));
        assertTrue(canCall);

        // Should be able to call method after allowing anyone
        (ok, ) = anyone.externalCall(address(guarded), abi.encodeWithSelector(guarded.guardedMethod.selector));
        assertTrue(ok);

        // Block everyone to call method
        guarded.blockCaller(guarded.guardedMethod.selector, guarded.ANY_CALLER());
        canCall = guarded.canCall(guarded.guardedMethod.selector, guarded.ANY_CALLER());
        assertTrue(canCall == false);

        // Should not be able to call method after blocking anyone
        (ok, ) = anyone.externalCall(address(guarded), abi.encodeWithSelector(guarded.guardedMethod.selector));
        assertTrue(ok == false);
    }

    function test_user() public {
        Caller user = new Caller();
        bool ok;
        bool canCall;

        // Should not be able to call method initially
        (ok, ) = user.externalCall(address(guarded), abi.encodeWithSelector(guarded.guardedMethod.selector));
        assertTrue(ok == false);

        // Allow user to call method
        guarded.allowCaller(guarded.guardedMethod.selector, address(user));
        canCall = guarded.canCall(guarded.guardedMethod.selector, address(user));
        assertTrue(canCall);

        // Should be able to call method after being allowed to
        (ok, ) = user.externalCall(address(guarded), abi.encodeWithSelector(guarded.guardedMethod.selector));
        assertTrue(ok);

        // Block user to call method
        guarded.blockCaller(guarded.guardedMethod.selector, address(user));
        canCall = guarded.canCall(guarded.guardedMethod.selector, address(user));
        assertTrue(canCall == false);

        // Should not be able to call method after being blocked
        (ok, ) = user.externalCall(address(guarded), abi.encodeWithSelector(guarded.guardedMethod.selector));
        assertTrue(ok == false);
    }

    function test_root() public {
        Caller user = new Caller();
        bool ok;

        // Should not be able to call method initially
        (ok, ) = user.externalCall(address(guarded), abi.encodeWithSelector(guarded.guardedMethodRoot.selector));
        assertTrue(ok == false);

        // Allow user to call any method
        guarded.allowCaller(guarded.ANY_SIG(), address(user));
        bool canCall = guarded.canCall(guarded.ANY_SIG(), address(user));
        assertTrue(canCall);

        // Should be able to call any method after being allowed to
        (ok, ) = user.externalCall(address(guarded), abi.encodeWithSelector(guarded.guardedMethodRoot.selector));
        assertTrue(ok);

        // Block user from calling any method
        guarded.blockCaller(guarded.ANY_SIG(), address(user));
        canCall = guarded.canCall(guarded.ANY_SIG(), address(user));
        assertTrue(canCall == false);

        // Should not be able to call any method after being blocked
        (ok, ) = user.externalCall(address(guarded), abi.encodeWithSelector(guarded.guardedMethodRoot.selector));
        assertTrue(ok == false);
    }
}
