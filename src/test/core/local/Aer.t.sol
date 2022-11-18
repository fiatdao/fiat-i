// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {DebtAuction} from "./DebtAuction.t.sol";
import {SurplusAuction} from "./SurplusAuction.t.sol";
import {TestCodex as Codex} from "./Codex.t.sol";

import {Aer} from "../../../core/Aer.sol";
import {WAD} from "../../../core/utils/Math.sol";

contract Token {
    mapping(address => uint256) public balanceOf;

    function mint(address user, uint256 amount) public {
        balanceOf[user] += amount;
    }
}

contract AerTest is Test {
    Codex codex;
    Aer aer;
    DebtAuction debtAuction;
    SurplusAuction surplusAuction;
    Token gov;

    function setUp() public {
        vm.warp(604411200);

        codex = new Codex();

        gov = new Token();
        debtAuction = new DebtAuction(address(codex), address(gov));
        surplusAuction = new SurplusAuction(address(codex), address(gov));

        aer = new Aer(address(codex), address(surplusAuction), address(debtAuction));
        surplusAuction.allowCaller(keccak256("ANY_SIG"), address(aer));
        debtAuction.allowCaller(keccak256("ANY_SIG"), address(aer));

        aer.setParam("surplusAuctionSellSize", 100 ether);
        aer.setParam("debtAuctionBidSize", 100 ether);
        aer.setParam("debtAuctionSellSize", 200 ether);

        aer.allowCaller(aer.startSurplusAuction.selector, aer.ANY_CALLER());
        aer.allowCaller(aer.startDebtAuction.selector, aer.ANY_CALLER());

        codex.grantDelegate(address(debtAuction));
    }

    function try_unqueueDebt(uint256 queuedAt) internal returns (bool ok) {
        string memory sig = "unqueueDebt(uint256)";
        (ok, ) = address(aer).call(abi.encodeWithSignature(sig, queuedAt));
    }

    function try_submitBid(
        uint256 id,
        uint256 tokensToSell,
        uint256 bid
    ) internal returns (bool ok) {
        string memory sig = "submitBid(uint256,uint256,uint256)";
        (ok, ) = address(debtAuction).call(abi.encodeWithSignature(sig, id, tokensToSell, bid));
    }

    function try_settleDebtWithSurplus(uint256 debt) internal returns (bool ok) {
        string memory sig = "settleDebtWithSurplus(uint256)";
        (ok, ) = address(aer).call(abi.encodeWithSignature(sig, debt));
    }

    function try_call(address addr, bytes calldata data) external returns (bool) {
        bytes memory _data = data;
        assembly {
            let ok := call(gas(), addr, 0, add(_data, 0x20), mload(_data), 0, 0)
            let free := mload(0x40)
            mstore(free, ok)
            mstore(0x40, add(free, 32))
            revert(free, 32)
        }
    }

    function can_surplusAuction() public returns (bool) {
        string memory sig = "startSurplusAuction()";
        bytes memory data = abi.encodeWithSignature(sig);

        bytes memory can_call = abi.encodeWithSignature("try_call(address,bytes)", aer, data);
        (bool ok, bytes memory success) = address(this).call(can_call);

        ok = abi.decode(success, (bool));
        if (ok) return true;
        return false;
    }

    function can_debtAuction() public returns (bool) {
        string memory sig = "startDebtAuction()";
        bytes memory data = abi.encodeWithSignature(sig);

        bytes memory can_call = abi.encodeWithSignature("try_call(address,bytes)", aer, data);
        (bool ok, bytes memory success) = address(this).call(can_call);

        ok = abi.decode(success, (bool));
        if (ok) return true;
        return false;
    }

    function createUnbackedDebt(address who, uint256 debt) internal {
        aer.queueDebt(debt);
        codex.init(address(0));
        codex.createUnbackedDebt(address(aer), who, debt);
    }

    function unqueueDebt(uint256 debt) internal {
        createUnbackedDebt(address(0), debt); // createUnbackedDebt credit into the zero address
        aer.unqueueDebt(block.timestamp);
    }

    function settleUnbackedDebt(uint256 debt) internal {
        aer.settleDebtWithSurplus(debt);
    }

    function test_change_surplusAuction_debtAuction() public {
        SurplusAuction newFlap = new SurplusAuction(address(codex), address(gov));
        DebtAuction newFlop = new DebtAuction(address(codex), address(gov));

        newFlap.allowCaller(keccak256("ANY_SIG"), address(aer));
        newFlop.allowCaller(keccak256("ANY_SIG"), address(aer));

        assertEq(codex.delegates(address(aer), address(surplusAuction)), 1);
        assertEq(codex.delegates(address(aer), address(newFlap)), 0);

        aer.setParam("surplusAuction", address(newFlap));
        aer.setParam("debtAuction", address(newFlop));

        assertEq(address(aer.surplusAuction()), address(newFlap));
        assertEq(address(aer.debtAuction()), address(newFlop));

        assertEq(codex.delegates(address(aer), address(surplusAuction)), 0);
        assertEq(codex.delegates(address(aer), address(newFlap)), 1);
    }

    function test_unqueueDebt_auctionDelay() public {
        assertEq(aer.auctionDelay(), 0);
        aer.setParam("auctionDelay", uint256(100 seconds));
        assertEq(aer.auctionDelay(), 100 seconds);

        uint256 queuedAt = block.timestamp;
        aer.queueDebt(100 ether);
        vm.warp(queuedAt + 99 seconds);
        assertTrue(!try_unqueueDebt(queuedAt));
        vm.warp(queuedAt + 100 seconds);
        assertTrue(try_unqueueDebt(queuedAt));
    }

    function test_no_redebtAuction() public {
        unqueueDebt(100 ether);
        assertTrue(can_debtAuction());
        aer.startDebtAuction();
        assertTrue(!can_debtAuction());
    }

    function test_no_debtAuction_pending_joy() public {
        unqueueDebt(200 ether);

        codex.mint(address(aer), 100 ether);
        assertTrue(!can_debtAuction());

        settleUnbackedDebt(100 ether);
        assertTrue(can_debtAuction());
    }

    function test_surplusAuction() public {
        codex.mint(address(aer), 100 ether);
        assertTrue(can_surplusAuction());
    }

    function test_no_surplusAuction_pending_unbackedDebt() public {
        aer.setParam("surplusAuctionSellSize", uint256(0 ether));
        unqueueDebt(100 ether);

        codex.mint(address(aer), 50 ether);
        assertTrue(!can_surplusAuction());
    }

    function test_no_surplusAuction_nonzero_woe() public {
        aer.setParam("surplusAuctionSellSize", uint256(0 ether));
        unqueueDebt(100 ether);
        codex.mint(address(aer), 50 ether);
        assertTrue(!can_surplusAuction());
    }

    function test_no_surplusAuction_pending_debtAuction() public {
        unqueueDebt(100 ether);
        aer.startDebtAuction();

        codex.mint(address(aer), 100 ether);

        assertTrue(!can_surplusAuction());
    }

    function test_no_surplusAuction_pending_settleUnbackedDebt() public {
        unqueueDebt(100 ether);
        uint256 id = aer.startDebtAuction();

        codex.mint(address(this), 100 ether);
        debtAuction.submitBid(id, 0 ether, 100 ether);

        assertTrue(!can_surplusAuction());
    }

    function test_no_surplus_after_good_debtAuction() public {
        unqueueDebt(100 ether);
        uint256 id = aer.startDebtAuction();
        codex.mint(address(this), 100 ether);

        debtAuction.submitBid(id, 0 ether, 100 ether); // debtAuction succeeds..

        assertTrue(!can_surplusAuction());
    }

    function test_multiple_debtAuction_submitBids() public {
        unqueueDebt(100 ether);
        uint256 id = aer.startDebtAuction();

        codex.mint(address(this), 100 ether);
        assertTrue(try_submitBid(id, 2 ether, 100 ether));

        codex.mint(address(this), 100 ether);
        assertTrue(try_submitBid(id, 1 ether, 100 ether));
    }

    function test_restricted_surplusAuction_startSurplusAuction() public {
        codex.mint(address(aer), 100 ether);
        aer.blockCaller(aer.startSurplusAuction.selector, aer.ANY_CALLER());
        aer.blockCaller(aer.ANY_SIG(), address(this));
        assertTrue(!can_surplusAuction());
    }

    function test_restricted_surplusAuction_settleDebtWithSurplus() public {
        codex.mint(address(aer), 100 ether);
        aer.blockCaller(aer.startSurplusAuction.selector, aer.ANY_CALLER());
        aer.blockCaller(aer.ANY_SIG(), address(this));
        assertTrue(!try_settleDebtWithSurplus(100 ether));
    }

    function test_restricted_debtAuction_startDebtAuction() public {
        unqueueDebt(100 ether);
        aer.blockCaller(aer.startDebtAuction.selector, aer.ANY_CALLER());
        aer.blockCaller(aer.ANY_SIG(), address(this));
        assertTrue(!can_debtAuction());
    }

    function test_restricted_debtAuction_settleAuctionedDebt() public {
        unqueueDebt(100 ether);
        uint256 id = aer.startDebtAuction();

        codex.mint(address(this), 100 ether);
        aer.blockCaller(aer.startDebtAuction.selector, aer.ANY_CALLER());
        aer.blockCaller(aer.ANY_SIG(), address(this));
        debtAuction.submitBid(id, 0 ether, 100 ether); // debtAuction succeeds..
    }

    function test_transferCredit() public {
        vm.store(address(codex), keccak256(abi.encode(address(aer), uint256(5))), bytes32(uint256(10 ether)));
        assertTrue(!try_settleDebtWithSurplus(10 ether));
        aer.transferCredit(address(1), 10 ether);
        assertEq(codex.credit(address(1)), 10 ether);
    }

    function testFail_transferCredit_noSurplus() public {
        codex.createUnbackedDebt(address(aer), address(aer), 10 ether);
        aer.transferCredit(address(1), 10 ether);
    }
}
