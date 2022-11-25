// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {ICollybus} from "../../../interfaces/ICollybus.sol";
import {IPriceCalculator} from "../../../interfaces/IPriceCalculator.sol";
import {Codex} from "../../../core/Codex.sol";
import {Limes} from "../../../core/Limes.sol";
import {NoLossCollateralAuction} from "../../../core/auctions/NoLossCollateralAuction.sol";
import {LinearDecrease} from "../../../core/auctions/PriceCalculator.sol";
import {WAD} from "../../../core/utils/Math.sol";

import {DSToken} from "../../../test/utils/dapphub/DSToken.sol";

import {AuctionGuard} from "../../../guards/AuctionGuard.sol";

contract AuctionGuardTest is Test {
    Codex codex;
    Limes limes;
    NoLossCollateralAuction collateralAuction;

    AuctionGuard auctionGuard;

    function setUp() public {
        codex = new Codex();
        limes = new Limes(address(codex));
        collateralAuction = new NoLossCollateralAuction(address(codex), address(limes));

        auctionGuard = new AuctionGuard(address(this), address(this), 1, address(collateralAuction));
        collateralAuction.allowCaller(collateralAuction.ANY_SIG(), address(auctionGuard));

        LinearDecrease linearDecrease = new LinearDecrease();
        linearDecrease.allowCaller(linearDecrease.ANY_SIG(), address(auctionGuard));
        collateralAuction.setParam(address(1), "calculator", address(linearDecrease));
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
        auctionGuard.isGuard();

        collateralAuction.blockCaller(collateralAuction.ANY_SIG(), address(auctionGuard));
        assertTrue(!can_call(address(auctionGuard), abi.encodeWithSelector(auctionGuard.isGuard.selector)));
    }

    function test_setFeeTip() public {
        auctionGuard.setFeeTip(0);
        auctionGuard.setFeeTip(1 * WAD);
        assertEq(collateralAuction.feeTip(), 1 * WAD);

        assertTrue(
            !can_call(address(auctionGuard), abi.encodeWithSelector(auctionGuard.setFeeTip.selector, 1 * WAD + 1))
        );

        auctionGuard.setGuardian(address(0));
        assertTrue(!can_call(address(auctionGuard), abi.encodeWithSelector(auctionGuard.setFeeTip.selector, 1 * WAD)));
    }

    function test_setFlatTip() public {
        auctionGuard.setFlatTip(0);
        auctionGuard.setFlatTip(10_000 * WAD);
        assertEq(collateralAuction.flatTip(), 10_000 * WAD);

        assertTrue(
            !can_call(address(auctionGuard), abi.encodeWithSelector(auctionGuard.setFlatTip.selector, 10_000 * WAD + 1))
        );

        auctionGuard.setGuardian(address(0));
        assertTrue(
            !can_call(address(auctionGuard), abi.encodeWithSelector(auctionGuard.setFlatTip.selector, 10_000 * WAD))
        );
    }

    function test_setStopped() public {
        auctionGuard.setStopped(0);
        auctionGuard.setStopped(3);
        assertEq(collateralAuction.stopped(), 3);

        assertTrue(!can_call(address(auctionGuard), abi.encodeWithSelector(auctionGuard.setStopped.selector, 3 + 1)));

        auctionGuard.setGuardian(address(0));
        assertTrue(!can_call(address(auctionGuard), abi.encodeWithSelector(auctionGuard.setStopped.selector, 3)));
    }

    function test_setLimes() public {
        assertTrue(
            !can_call(address(auctionGuard), abi.encodeWithSelector(auctionGuard.setLimes.selector, address(1)))
        );

        bytes memory call = abi.encodeWithSelector(auctionGuard.setLimes.selector, address(1));
        auctionGuard.schedule(call);

        assertTrue(
            !can_call(
                address(auctionGuard),
                abi.encodeWithSelector(
                    auctionGuard.execute.selector,
                    address(auctionGuard),
                    call,
                    block.timestamp + auctionGuard.delay()
                )
            )
        );

        vm.warp(block.timestamp + auctionGuard.delay());
        auctionGuard.execute(address(auctionGuard), call, block.timestamp);
        assertEq(address(collateralAuction.limes()), address(1));
    }

    function test_setAer() public {
        assertTrue(!can_call(address(auctionGuard), abi.encodeWithSelector(auctionGuard.setAer.selector, address(1))));

        bytes memory call = abi.encodeWithSelector(auctionGuard.setAer.selector, address(1));
        auctionGuard.schedule(call);

        assertTrue(
            !can_call(
                address(auctionGuard),
                abi.encodeWithSelector(
                    auctionGuard.execute.selector,
                    address(auctionGuard),
                    call,
                    block.timestamp + auctionGuard.delay()
                )
            )
        );

        vm.warp(block.timestamp + auctionGuard.delay());
        auctionGuard.execute(address(auctionGuard), call, block.timestamp);
        assertEq(address(collateralAuction.aer()), address(1));
    }

    function test_setMultiplier() public {
        auctionGuard.setMultiplier(address(1), 0.9e18);
        auctionGuard.setMultiplier(address(1), 2 * WAD);
        (uint256 multiplier, , , , ) = collateralAuction.vaults(address(1));
        assertEq(multiplier, 2 * WAD);

        assertTrue(
            !can_call(
                address(auctionGuard),
                abi.encodeWithSelector(auctionGuard.setMultiplier.selector, address(1), 2 * WAD + 1)
            )
        );

        auctionGuard.setGuardian(address(0));
        assertTrue(
            !can_call(
                address(auctionGuard),
                abi.encodeWithSelector(auctionGuard.setMultiplier.selector, address(1), 2 * WAD)
            )
        );
    }

    function test_setMaxAuctionDuration() public {
        auctionGuard.setMaxAuctionDuration(address(1), 3 hours);
        auctionGuard.setMaxAuctionDuration(address(1), 30 days);
        (, uint256 maxAuctionDuration, , , ) = collateralAuction.vaults(address(1));
        assertEq(maxAuctionDuration, 30 days);

        assertTrue(
            !can_call(
                address(auctionGuard),
                abi.encodeWithSelector(auctionGuard.setMaxAuctionDuration.selector, address(1), 30 days + 1)
            )
        );

        auctionGuard.setGuardian(address(0));
        assertTrue(
            !can_call(
                address(auctionGuard),
                abi.encodeWithSelector(auctionGuard.setMaxAuctionDuration.selector, address(1), 30 days)
            )
        );
    }

    function test_setCollybus() public {
        assertTrue(
            !can_call(
                address(auctionGuard),
                abi.encodeWithSelector(auctionGuard.setCollybus.selector, address(1), address(1))
            )
        );

        bytes memory call = abi.encodeWithSelector(auctionGuard.setCollybus.selector, address(1), address(1));
        auctionGuard.schedule(call);

        assertTrue(
            !can_call(
                address(auctionGuard),
                abi.encodeWithSelector(
                    auctionGuard.execute.selector,
                    address(auctionGuard),
                    call,
                    block.timestamp + auctionGuard.delay()
                )
            )
        );

        vm.warp(block.timestamp + auctionGuard.delay());
        auctionGuard.execute(address(auctionGuard), call, block.timestamp);

        (, , , ICollybus collybus, ) = collateralAuction.vaults(address(1));
        assertEq(address(collybus), address(1));
    }

    function test_setCalculator() public {
        assertTrue(
            !can_call(
                address(auctionGuard),
                abi.encodeWithSelector(auctionGuard.setCalculator.selector, address(1), address(1))
            )
        );

        bytes memory call = abi.encodeWithSelector(auctionGuard.setCalculator.selector, address(1), address(1));
        auctionGuard.schedule(call);

        assertTrue(
            !can_call(
                address(auctionGuard),
                abi.encodeWithSelector(
                    auctionGuard.execute.selector,
                    address(auctionGuard),
                    call,
                    block.timestamp + auctionGuard.delay()
                )
            )
        );

        vm.warp(block.timestamp + auctionGuard.delay());
        auctionGuard.execute(address(auctionGuard), call, block.timestamp);

        (, , , , IPriceCalculator calculator) = collateralAuction.vaults(address(1));
        assertEq(address(calculator), address(1));
    }
}
