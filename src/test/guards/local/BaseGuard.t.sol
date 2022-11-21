// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {WAD} from "../../../core/utils/Math.sol";

import {DSToken} from "../../../test/utils/dapphub/DSToken.sol";

import {BaseGuard} from "../../../guards/BaseGuard.sol";

contract TestGuard is BaseGuard {
    bool public done;

    constructor(
        address senatus,
        address guardian,
        uint256 delay
    ) BaseGuard(senatus, guardian, delay) {}

    function isGuard() external pure override returns (bool) {
        return true;
    }

    function scheduledMethod() external isDelayed {
        done = true;
    }

    function inRange(
        uint256 value,
        uint256 min,
        uint256 max
    ) external pure {
        _inRange(value, min, max);
    }
}

contract NotSenatus {
    TestGuard internal testGuard;

    constructor(TestGuard testGuard_) {
        testGuard = testGuard_;
    }

    function setSenatus(address senatus) external {
        testGuard.setSenatus(senatus);
    }

    function setGuardian(address guardian) external {
        testGuard.setGuardian(guardian);
    }

    function setDelay(uint256 delay) external {
        testGuard.setDelay(delay);
    }
}

contract BaseGuardTest is Test {
    TestGuard testGuard;

    function setUp() public {
        testGuard = new TestGuard(address(this), address(this), 1);
    }

    function try_call(address addr, bytes memory data) public returns (bool) {
        bytes memory _data = data;
        assembly {
            let ok := call(gas(), addr, 0, add(_data, 0x20), mload(_data), 0, 0)
            let free := mload(0x40)
            mstore(free, ok)
            mstore(0x40, add(free, 32))
            revert(free, 32)
        }
    }

    function can_call(address addr, bytes memory data) public returns (bool) {
        bytes memory call = abi.encodeWithSignature("try_call(address,bytes)", addr, data);
        (bool ok, bytes memory success) = address(this).call(call);
        ok = abi.decode(success, (bool));
        if (ok) return true;
        return false;
    }

    function test_setSenatus() public {
        testGuard.setSenatus(address(1));

        assertEq(testGuard.senatus(), address(1));

        NotSenatus notSenatus = new NotSenatus(testGuard);
        assertTrue(!can_call(address(notSenatus), abi.encodeWithSelector(notSenatus.setSenatus.selector, address(1))));
    }

    function test_setGuardian() public {
        testGuard.setGuardian(address(1));

        assertEq(testGuard.guardian(), address(1));

        NotSenatus notSenatus = new NotSenatus(testGuard);
        assertTrue(!can_call(address(notSenatus), abi.encodeWithSelector(notSenatus.setGuardian.selector, address(1))));
    }

    function test_setDelay() public {
        testGuard.setDelay(2);

        assertEq(testGuard.delay(), 2);

        NotSenatus notSenatus = new NotSenatus(testGuard);
        assertTrue(!can_call(address(notSenatus), abi.encodeWithSelector(notSenatus.setDelay.selector, 2)));
    }

    function test_schedule() public {
        assertTrue(!can_call(address(testGuard), abi.encodeWithSelector(testGuard.scheduledMethod.selector)));

        bytes memory call = abi.encodeWithSelector(testGuard.scheduledMethod.selector);
        testGuard.schedule(call);

        assertTrue(
            !can_call(
                address(testGuard),
                abi.encodeWithSelector(
                    testGuard.execute.selector,
                    address(testGuard),
                    call,
                    block.timestamp + testGuard.delay()
                )
            )
        );

        vm.warp(block.timestamp + testGuard.delay());
        testGuard.execute(address(testGuard), call, block.timestamp);
        assertTrue(testGuard.done());
    }

    function test_inRange(
        uint256 value,
        uint256 min,
        uint256 max
    ) public {
        if (min <= value && value <= max) {
            testGuard.inRange(value, min, max);
        } else {
            assertTrue(
                !can_call(address(testGuard), abi.encodeWithSelector(testGuard.inRange.selector, value, min, max))
            );
        }
    }
}
