// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {Aer} from "../../../core/Aer.sol";
import {Codex} from "../../../core/Codex.sol";
import {SurplusAuction} from "../../../core/auctions/SurplusAuction.sol";
import {DebtAuction} from "../../../core/auctions/DebtAuction.sol";
import {WAD} from "../../../core/utils/Math.sol";

import {DSToken} from "../../../test/utils/dapphub/DSToken.sol";

import {AerGuard} from "../../../guards/AerGuard.sol";

contract AerGuardTest is Test {
    Codex codex;
    Aer aer;
    DebtAuction debtAuction;
    SurplusAuction surplusAuction;

    AerGuard aerGuard;

    function setUp() public {
        codex = new Codex();
        debtAuction = new DebtAuction(address(codex), address(new DSToken("")));
        surplusAuction = new SurplusAuction(address(codex), address(new DSToken("")));
        aer = new Aer(address(codex), address(surplusAuction), address(debtAuction));

        aerGuard = new AerGuard(address(this), address(this), 1, address(aer));
        aer.allowCaller(aer.ANY_SIG(), address(aerGuard));
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
        aerGuard.isGuard();

        aer.blockCaller(aer.ANY_SIG(), address(aerGuard));
        assertTrue(!can_call(address(aerGuard), abi.encodeWithSelector(aerGuard.isGuard.selector)));
    }

    function test_setAuctionDelay() public {
        aerGuard.setAuctionDelay(0);
        aerGuard.setAuctionDelay(7 days);
        assertEq(aer.auctionDelay(), 7 days);

        assertTrue(!can_call(address(aerGuard), abi.encodeWithSelector(aerGuard.setAuctionDelay.selector, 8 days)));

        aerGuard.setGuardian(address(0));
        assertTrue(!can_call(address(aerGuard), abi.encodeWithSelector(aerGuard.setAuctionDelay.selector, 7 days)));
    }

    function test_setSurplusAuctionSellSize() public {
        aerGuard.setSurplusAuctionSellSize(0);
        aerGuard.setSurplusAuctionSellSize(200_000 * WAD);
        assertEq(aer.surplusAuctionSellSize(), 200_000 * WAD);

        assertTrue(
            !can_call(
                address(aerGuard),
                abi.encodeWithSelector(aerGuard.setSurplusAuctionSellSize.selector, 200_000 * WAD + 1)
            )
        );

        aerGuard.setGuardian(address(0));
        assertTrue(
            !can_call(
                address(aerGuard),
                abi.encodeWithSelector(aerGuard.setSurplusAuctionSellSize.selector, 200_000 * WAD)
            )
        );
    }

    function test_setDebtAuctionBidSize() public {
        aerGuard.setDebtAuctionBidSize(0);
        aerGuard.setDebtAuctionBidSize(200_000 * WAD);
        assertEq(aer.debtAuctionBidSize(), 200_000 * WAD);

        assertTrue(
            !can_call(
                address(aerGuard),
                abi.encodeWithSelector(aerGuard.setDebtAuctionBidSize.selector, 200_000 * WAD + 1)
            )
        );

        aerGuard.setGuardian(address(0));
        assertTrue(
            !can_call(address(aerGuard), abi.encodeWithSelector(aerGuard.setDebtAuctionBidSize.selector, 200_000 * WAD))
        );
    }

    function test_setDebtAuctionSellSize() public {
        aerGuard.setDebtAuctionSellSize(0);
        aerGuard.setDebtAuctionSellSize(200_000 * WAD);
        assertEq(aer.debtAuctionSellSize(), 200_000 * WAD);

        assertTrue(
            !can_call(
                address(aerGuard),
                abi.encodeWithSelector(aerGuard.setDebtAuctionSellSize.selector, 200_000 * WAD + 1)
            )
        );

        aerGuard.setGuardian(address(0));
        assertTrue(
            !can_call(
                address(aerGuard),
                abi.encodeWithSelector(aerGuard.setDebtAuctionSellSize.selector, 200_000 * WAD)
            )
        );
    }

    function test_setSurplusBuffer() public {
        aerGuard.setSurplusBuffer(0);
        aerGuard.setSurplusBuffer(1_000_000 * WAD);
        assertEq(aer.surplusBuffer(), 1_000_000 * WAD);

        assertTrue(
            !can_call(
                address(aerGuard),
                abi.encodeWithSelector(aerGuard.setSurplusBuffer.selector, 1_000_000 * WAD + 1)
            )
        );

        aerGuard.setGuardian(address(0));
        assertTrue(
            !can_call(address(aerGuard), abi.encodeWithSelector(aerGuard.setSurplusBuffer.selector, 1_000_000 * WAD))
        );
    }

    function test_setSurplusAuction() public {
        assertTrue(
            !can_call(address(aerGuard), abi.encodeWithSelector(aerGuard.setSurplusAuction.selector, address(1)))
        );

        bytes memory call = abi.encodeWithSelector(aerGuard.setSurplusAuction.selector, address(1));
        aerGuard.schedule(call);

        assertTrue(
            !can_call(
                address(aerGuard),
                abi.encodeWithSelector(
                    aerGuard.execute.selector,
                    address(aerGuard),
                    call,
                    block.timestamp + aerGuard.delay()
                )
            )
        );

        vm.warp(block.timestamp + aerGuard.delay());
        aerGuard.execute(address(aerGuard), call, block.timestamp);
        assertEq(address(aer.surplusAuction()), address(1));
    }

    function test_setDebtAuction() public {
        assertTrue(!can_call(address(aerGuard), abi.encodeWithSelector(aerGuard.setDebtAuction.selector, address(1))));

        bytes memory call = abi.encodeWithSelector(aerGuard.setDebtAuction.selector, address(1));
        aerGuard.schedule(call);

        assertTrue(
            !can_call(
                address(aerGuard),
                abi.encodeWithSelector(
                    aerGuard.execute.selector,
                    address(aerGuard),
                    call,
                    block.timestamp + aerGuard.delay()
                )
            )
        );

        vm.warp(block.timestamp + aerGuard.delay());
        aerGuard.execute(address(aerGuard), call, block.timestamp);
        assertEq(address(aer.debtAuction()), address(1));
    }
}
