// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {DSToken} from "../../utils/dapphub/DSToken.sol";

import {Codex} from "../../../core/Codex.sol";
import {DebtAuction} from "../../../core/auctions/DebtAuction.sol";
import {WAD, sub} from "../../../core/utils/Math.sol";

contract Guy {
    DebtAuction debtAuction;

    constructor(DebtAuction debtAuction_) {
        debtAuction = debtAuction_;
        Codex(address(debtAuction.codex())).grantDelegate(address(debtAuction));
        DSToken(address(debtAuction.token())).approve(address(debtAuction));
    }

    function submitBid(
        uint256 id,
        uint256 tokensToSell,
        uint256 bid
    ) public {
        debtAuction.submitBid(id, tokensToSell, bid);
    }

    function closeAuction(uint256 id) public {
        debtAuction.closeAuction(id);
    }

    function try_submitBid(
        uint256 id,
        uint256 tokensToSell,
        uint256 bid
    ) public returns (bool ok) {
        string memory sig = "submitBid(uint256,uint256,uint256)";
        (ok, ) = address(debtAuction).call(abi.encodeWithSignature(sig, id, tokensToSell, bid));
    }

    function try_closeAuction(uint256 id) public returns (bool ok) {
        string memory sig = "closeAuction(uint256)";
        (ok, ) = address(debtAuction).call(abi.encodeWithSignature(sig, id));
    }

    function try_redoAuction(uint256 id) public returns (bool ok) {
        string memory sig = "redoAuction(uint256)";
        (ok, ) = address(debtAuction).call(abi.encodeWithSignature(sig, id));
    }
}

contract Gal {
    uint256 public debtOnAuction;

    function startAuction(
        DebtAuction debtAuction,
        uint256 tokensToSell,
        uint256 bid
    ) external returns (uint256) {
        debtOnAuction += bid;
        return debtAuction.startAuction(address(this), tokensToSell, bid);
    }

    function settleAuctionedDebt(uint256 debt) external {
        debtOnAuction = sub(debtOnAuction, debt);
    }

    function lock(DebtAuction debtAuction) external {
        debtAuction.lock();
    }
}

contract Codexish is DSToken("") {
    function grantDelegate(address user) public {
        approve(user, type(uint256).max);
    }

    function credit(address user) public view returns (uint256) {
        return balanceOf[user];
    }
}

contract DebtAuctionTest is Test {
    DebtAuction debtAuction;
    Codex codex;
    DSToken token;

    address ali;
    address bob;
    address recipient;

    function settleAuctionedDebt(uint256) public pure {} // arbitrary callback

    function setUp() public {
        vm.warp(604411200);

        codex = new Codex();
        token = new DSToken("");
        token.setOwner(address(this));

        debtAuction = new DebtAuction(address(codex), address(token));

        ali = address(new Guy(debtAuction));
        bob = address(new Guy(debtAuction));
        recipient = address(new Gal());

        debtAuction.allowCaller(keccak256("ANY_SIG"), recipient);
        debtAuction.blockCaller(keccak256("ANY_SIG"), address(this));

        codex.grantDelegate(address(debtAuction));
        codex.allowCaller(keccak256("ANY_SIG"), address(debtAuction));
        token.approve(address(debtAuction));

        codex.createUnbackedDebt(address(this), address(this), 1000 ether);

        codex.transferCredit(address(this), ali, 200 ether);
        codex.transferCredit(address(this), bob, 200 ether);
    }

    function test_startAuction() public {
        assertEq(codex.credit(recipient), 0);
        assertEq(token.balanceOf(recipient), 0 ether);
        uint256 id = Gal(recipient).startAuction(
            debtAuction,
            /*tokensToSell*/
            200 ether,
            /*bid*/
            5000 ether
        );
        // no value transferred
        assertEq(codex.credit(recipient), 0);
        assertEq(token.balanceOf(recipient), 0 ether);
        // auction created with appropriate values
        assertEq(debtAuction.auctionCounter(), id);
        (uint256 bid, uint256 tokensToSell, address recipient_, uint48 bidExpiry, uint48 auctionExpiry) = debtAuction
            .auctions(id);
        assertEq(bid, 5000 ether);
        assertEq(tokensToSell, 200 ether);
        assertTrue(recipient_ == recipient);
        assertEq(uint256(bidExpiry), 0);
        assertEq(uint256(auctionExpiry), block.timestamp + debtAuction.auctionDuration());
    }

    function test_submitBid() public {
        uint256 id = Gal(recipient).startAuction(
            debtAuction,
            /*tokensToSell*/
            200 ether,
            /*bid*/
            10 ether
        );

        Guy(ali).submitBid(id, 100 ether, 10 ether);
        // bid taken from bidder
        assertEq(codex.credit(ali), 190 ether);
        // recipient receives payment
        assertEq(codex.credit(recipient), 10 ether);
        assertEq(Gal(recipient).debtOnAuction(), 0 ether);

        Guy(bob).submitBid(id, 80 ether, 10 ether);
        // bid taken from bidder
        assertEq(codex.credit(bob), 190 ether);
        // prev bidder refunded
        assertEq(codex.credit(ali), 200 ether);
        // recipient receives no more
        assertEq(codex.credit(recipient), 10 ether);

        vm.warp(block.timestamp + 5 weeks);
        assertEq(token.totalSupply(), 0 ether);

        token.mint(address(debtAuction), 80 ether);

        Guy(bob).closeAuction(id);
        // tokens minted on demand
        assertEq(token.totalSupply(), 80 ether);
        // bob gets the winnings
        assertEq(token.balanceOf(bob), 80 ether);
    }

    function test_submitBid_debtOnAuction_less_than_bid() public {
        uint256 id = Gal(recipient).startAuction(
            debtAuction,
            /*tokensToSell*/
            200 ether,
            /*bid*/
            10 ether
        );
        assertEq(codex.credit(recipient), 0 ether);

        Gal(recipient).settleAuctionedDebt(1 ether);
        assertEq(Gal(recipient).debtOnAuction(), 9 ether);

        Guy(ali).submitBid(id, 100 ether, 10 ether);
        // bid taken from bidder
        assertEq(codex.credit(ali), 190 ether);
        // recipient receives payment
        assertEq(codex.credit(recipient), 10 ether);
        assertEq(Gal(recipient).debtOnAuction(), 0 ether);

        Guy(bob).submitBid(id, 80 ether, 10 ether);
        // bid taken from bidder
        assertEq(codex.credit(bob), 190 ether);
        // prev bidder refunded
        assertEq(codex.credit(ali), 200 ether);
        // recipient receives no more
        assertEq(codex.credit(recipient), 10 ether);

        vm.warp(block.timestamp + 5 weeks);
        assertEq(token.totalSupply(), 0 ether);

        token.mint(address(debtAuction), 80 ether);

        Guy(bob).closeAuction(id);
        // tokens minted on demand
        assertEq(token.totalSupply(), 80 ether);
        // bob gets the winnings
        assertEq(token.balanceOf(bob), 80 ether);
    }

    function test_submitBid_same_bidder() public {
        uint256 id = Gal(recipient).startAuction(
            debtAuction,
            /*tokensToSell*/
            200 ether,
            /*bid*/
            200 ether
        );

        Guy(ali).submitBid(id, 100 ether, 200 ether);
        assertEq(codex.credit(ali), 0);
        Guy(ali).submitBid(id, 50 ether, 200 ether);
    }

    function test_redoAuction() public {
        // start an auction
        uint256 id = Gal(recipient).startAuction(
            debtAuction,
            /*tokensToSell*/
            200 ether,
            /*bid*/
            10 ether
        );
        // check no redoAuction
        assertTrue(!Guy(ali).try_redoAuction(id));
        // run past the auctionExpiry
        vm.warp(block.timestamp + 2 weeks);
        // check not biddable
        assertTrue(!Guy(ali).try_submitBid(id, 100 ether, 10 ether));
        assertTrue(Guy(ali).try_redoAuction(id));
        // check biddable
        (, uint256 _tokensToSell, , , ) = debtAuction.auctions(id);
        // redoAuction should increase the tokensToSell by tokenToSellBump (50%) and restart the auction
        assertEq(_tokensToSell, 300 ether);
        assertTrue(Guy(ali).try_submitBid(id, 100 ether, 10 ether));
    }

    function test_no_closeAuction_after_end() public {
        // if there are no auctions and the auction ends, then it should not
        // be refundable to the creator. Rather, it redoAuctions indefinitely.
        uint256 id = Gal(recipient).startAuction(
            debtAuction,
            /*tokensToSell*/
            200 ether,
            /*bid*/
            10 ether
        );
        assertTrue(!Guy(ali).try_closeAuction(id));
        vm.warp(block.timestamp + 2 weeks);
        assertTrue(!Guy(ali).try_closeAuction(id));
        assertTrue(Guy(ali).try_redoAuction(id));
        assertTrue(!Guy(ali).try_closeAuction(id));
    }

    function test_cancelAuction() public {
        // cancelAuctioning the auction should refund the last bidder's credit, credit a
        // corresponding amount of unbackedDebt to the caller of lock, and delete the auction.
        // in practice, recipient == (caller of lock) == (aer address)
        uint256 id = Gal(recipient).startAuction(
            debtAuction,
            /*tokensToSell*/
            200 ether,
            /*bid*/
            10 ether
        );

        // confrim initial state expectations
        assertEq(codex.credit(ali), 200 ether);
        assertEq(codex.credit(bob), 200 ether);
        assertEq(codex.credit(recipient), 0);
        assertEq(codex.unbackedDebt(recipient), 0);

        Guy(ali).submitBid(id, 100 ether, 10 ether);
        Guy(bob).submitBid(id, 80 ether, 10 ether);

        // confirm the proper state updates have occurred
        assertEq(codex.credit(ali), 200 ether); // ali's credit balance is unchanged
        assertEq(codex.credit(bob), 190 ether);
        assertEq(codex.credit(recipient), 10 ether);
        assertEq(codex.unbackedDebt(address(this)), 1000 ether);

        Gal(recipient).lock(debtAuction);
        debtAuction.cancelAuction(id);

        // confirm final state
        assertEq(codex.credit(ali), 200 ether);
        assertEq(codex.credit(bob), 200 ether); // bob's bid has been refunded
        assertEq(codex.credit(recipient), 10 ether);
        assertEq(codex.unbackedDebt(recipient), 10 ether); // unbackedDebt assigned to caller of lock()
        (uint256 _bid, uint256 _tokensToSell, address _recipient, uint48 _bidExpiry, uint48 _end) = debtAuction
            .auctions(id);
        assertEq(_bid, 0);
        assertEq(_tokensToSell, 0);
        assertEq(_recipient, address(0));
        assertEq(uint256(_bidExpiry), 0);
        assertEq(uint256(_end), 0);
    }

    function test_cancelAuction_no_bids() public {
        // with no bidder to refund, cancelAuctioning the auction should simply create equal
        // amounts of credit (credited to the recipient) and unbackedDebt (credited to the caller of lock)
        // in practice, recipient == (caller of lock) == (aer address)
        uint256 id = Gal(recipient).startAuction(
            debtAuction,
            /*tokensToSell*/
            200 ether,
            /*bid*/
            10 ether
        );

        // confrim initial state expectations
        assertEq(codex.credit(ali), 200 ether);
        assertEq(codex.credit(bob), 200 ether);
        assertEq(codex.credit(recipient), 0);
        assertEq(codex.unbackedDebt(recipient), 0);

        Gal(recipient).lock(debtAuction);
        debtAuction.cancelAuction(id);

        // confirm final state
        assertEq(codex.credit(ali), 200 ether);
        assertEq(codex.credit(bob), 200 ether);
        assertEq(codex.credit(recipient), 10 ether);
        assertEq(codex.unbackedDebt(recipient), 10 ether); // unbackedDebt assigned to caller of lock()
        (uint256 _bid, uint256 _tokensToSell, address _recipient, uint48 _bidExpiry, uint48 _end) = debtAuction
            .auctions(id);
        assertEq(_bid, 0);
        assertEq(_tokensToSell, 0);
        assertEq(_recipient, address(0));
        assertEq(uint256(_bidExpiry), 0);
        assertEq(uint256(_end), 0);
    }
}
