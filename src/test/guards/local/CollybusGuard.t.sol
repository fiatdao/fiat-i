// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {DSToken} from "../../../test/utils/dapphub/DSToken.sol";

import {Collybus} from "../../../core/Collybus.sol";
import {WAD} from "../../../core/utils/Math.sol";

import {CollybusGuard} from "../../../guards/CollybusGuard.sol";

contract CollybusGuardTest is Test {
    Collybus collybus;
    CollybusGuard collybusGuard;

    function setUp() public {
        collybus = new Collybus();

        collybusGuard = new CollybusGuard(address(this), address(this), 1, address(collybus));
        collybus.allowCaller(collybus.ANY_SIG(), address(collybusGuard));
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

    function test_isGuard() public {
        collybusGuard.isGuard();

        collybus.blockCaller(collybus.ANY_SIG(), address(collybusGuard));
        assertTrue(!can_call(address(collybusGuard), abi.encodeWithSelector(collybusGuard.isGuard.selector)));
    }

    function test_setLiquidationRatio() public {
        collybusGuard.setLiquidationRatio(address(1), uint128(WAD));
        collybusGuard.setLiquidationRatio(address(1), uint128(2 * WAD));
        (uint128 liquidationRatio, ) = collybus.vaults(address(1));
        assertEq(liquidationRatio, 2 * WAD);

        assertTrue(
            !can_call(
                address(collybusGuard),
                abi.encodeWithSelector(collybusGuard.setLiquidationRatio.selector, address(1), uint128(2 * WAD + 1))
            )
        );

        collybusGuard.setGuardian(address(0));
        assertTrue(
            !can_call(
                address(collybusGuard),
                abi.encodeWithSelector(collybusGuard.setLiquidationRatio.selector, address(1), uint128(2 * WAD))
            )
        );
    }

    function test_setDefaultRateId() public {
        collybusGuard.setDefaultRateId(address(1), 1);
        (, uint128 defaultRateId) = collybus.vaults(address(1));
        assertEq(defaultRateId, 1);

        collybusGuard.setGuardian(address(0));
        assertTrue(
            !can_call(
                address(collybusGuard),
                abi.encodeWithSelector(collybusGuard.setDefaultRateId.selector, address(1), uint128(2 * WAD))
            )
        );
    }

    function test_setRateId() public {
        collybusGuard.setRateId(address(1), 1, 1);
        assertEq(collybus.rateIds(address(1), 1), 1);

        collybusGuard.setGuardian(address(0));
        assertTrue(
            !can_call(
                address(collybusGuard),
                abi.encodeWithSelector(collybusGuard.setRateId.selector, address(1), 1, 1)
            )
        );
    }

    function test_setSpotRelayer() public {
        assertTrue(
            !can_call(address(collybusGuard), abi.encodeWithSelector(collybusGuard.setSpotRelayer.selector, address(1)))
        );

        bytes memory call = abi.encodeWithSelector(collybusGuard.setSpotRelayer.selector, address(1));
        collybusGuard.schedule(call);

        assertTrue(
            !can_call(
                address(collybusGuard),
                abi.encodeWithSelector(
                    collybusGuard.execute.selector,
                    address(collybusGuard),
                    call,
                    block.timestamp + collybusGuard.delay()
                )
            )
        );

        vm.warp(block.timestamp + collybusGuard.delay());
        collybusGuard.execute(address(collybusGuard), call, block.timestamp);

        assertTrue(collybus.canCall(collybus.updateSpot.selector, address(1)));
    }

    function test_unsetSpotRelayer() public {
        bytes memory call_ = abi.encodeWithSelector(collybusGuard.setSpotRelayer.selector, address(1));
        collybusGuard.schedule(call_);
        vm.warp(block.timestamp + collybusGuard.delay());
        collybusGuard.execute(address(collybusGuard), call_, block.timestamp);
        assertTrue(collybus.canCall(collybus.updateSpot.selector, address(1)));

        assertTrue(
            !can_call(
                address(collybusGuard),
                abi.encodeWithSelector(collybusGuard.unsetSpotRelayer.selector, address(1))
            )
        );

        bytes memory call = abi.encodeWithSelector(collybusGuard.unsetSpotRelayer.selector, address(1));
        collybusGuard.schedule(call);

        assertTrue(
            !can_call(
                address(collybusGuard),
                abi.encodeWithSelector(
                    collybusGuard.execute.selector,
                    address(collybusGuard),
                    call,
                    block.timestamp + collybusGuard.delay()
                )
            )
        );

        vm.warp(block.timestamp + collybusGuard.delay());
        collybusGuard.execute(address(collybusGuard), call, block.timestamp);

        assertTrue(!collybus.canCall(collybus.updateSpot.selector, address(1)));
    }

    function test_setDiscountRateRelayer() public {
        assertTrue(
            !can_call(
                address(collybusGuard),
                abi.encodeWithSelector(collybusGuard.setDiscountRateRelayer.selector, address(1))
            )
        );

        bytes memory call = abi.encodeWithSelector(collybusGuard.setDiscountRateRelayer.selector, address(1));
        collybusGuard.schedule(call);

        assertTrue(
            !can_call(
                address(collybusGuard),
                abi.encodeWithSelector(
                    collybusGuard.execute.selector,
                    address(collybusGuard),
                    call,
                    block.timestamp + collybusGuard.delay()
                )
            )
        );

        vm.warp(block.timestamp + collybusGuard.delay());
        collybusGuard.execute(address(collybusGuard), call, block.timestamp);

        assertTrue(collybus.canCall(collybus.updateDiscountRate.selector, address(1)));
    }

    function test_unsetDiscountRateRelayer() public {
        bytes memory call_ = abi.encodeWithSelector(collybusGuard.setDiscountRateRelayer.selector, address(1));
        collybusGuard.schedule(call_);
        vm.warp(block.timestamp + collybusGuard.delay());
        collybusGuard.execute(address(collybusGuard), call_, block.timestamp);
        assertTrue(collybus.canCall(collybus.updateDiscountRate.selector, address(1)));

        assertTrue(
            !can_call(
                address(collybusGuard),
                abi.encodeWithSelector(collybusGuard.unsetDiscountRateRelayer.selector, address(1))
            )
        );

        bytes memory call = abi.encodeWithSelector(collybusGuard.unsetDiscountRateRelayer.selector, address(1));
        collybusGuard.schedule(call);

        assertTrue(
            !can_call(
                address(collybusGuard),
                abi.encodeWithSelector(
                    collybusGuard.execute.selector,
                    address(collybusGuard),
                    call,
                    block.timestamp + collybusGuard.delay()
                )
            )
        );

        vm.warp(block.timestamp + collybusGuard.delay());
        collybusGuard.execute(address(collybusGuard), call, block.timestamp);

        assertTrue(!collybus.canCall(collybus.updateDiscountRate.selector, address(1)));
    }
}
