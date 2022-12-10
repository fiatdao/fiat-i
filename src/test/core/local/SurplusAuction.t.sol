// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {DSToken} from "../../utils/dapphub/DSToken.sol";
import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";

import {Codex} from "../../../core/Codex.sol";
import {SurplusAuction} from "../../../core/auctions/SurplusAuction.sol";

interface Hevm {
    function warp(uint256) external;
}

contract Guy {
    SurplusAuction surplusAuction;

    constructor(SurplusAuction surplusAuction_) {
        surplusAuction = surplusAuction_;
        Codex(address(surplusAuction.codex())).grantDelegate(address(surplusAuction));
        DSToken(address(surplusAuction.token())).approve(address(surplusAuction));
    }

    function submitBid(
        uint256 id,
        uint256 creditToSell,
        uint256 bid
    ) public {
        surplusAuction.submitBid(id, creditToSell, bid);
    }

    function closeAuction(uint256 id) public {
        surplusAuction.closeAuction(id);
    }

    function try_submitBid(
        uint256 id,
        uint256 creditToSell,
        uint256 bid
    ) public returns (bool ok) {
        string memory sig = "submitBid(uint256,uint256,uint256)";
        (ok, ) = address(surplusAuction).call(abi.encodeWithSignature(sig, id, creditToSell, bid));
    }

    function try_closeAuction(uint256 id) public returns (bool ok) {
        string memory sig = "closeAuction(uint256)";
        (ok, ) = address(surplusAuction).call(abi.encodeWithSignature(sig, id));
    }

    function try_redoAuction(uint256 id) public returns (bool ok) {
        string memory sig = "redoAuction(uint256)";
        (ok, ) = address(surplusAuction).call(abi.encodeWithSignature(sig, id));
    }
}

contract OZToken is ERC20("OZ ERC20", "0Z20") {
    function mint(address to, uint value) external {
        _mint(to, value);
    }
}
contract SurplusAuctionTest is Test {
    Hevm hevm;

    SurplusAuction surplusAuction;
    Codex codex;
    DSToken token;
    OZToken ozToken;

    address ali;
    address bob;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        codex = new Codex();
        token = new DSToken("");
        ozToken = new OZToken();

        surplusAuction = new SurplusAuction(address(codex), address(token));
        
        ali = address(new Guy(surplusAuction));
        bob = address(new Guy(surplusAuction));

        codex.grantDelegate(address(surplusAuction));
        token.approve(address(surplusAuction));

        codex.createUnbackedDebt(address(this), address(this), 1000 ether);

        token.mint(1000 ether);
        token.setOwner(address(surplusAuction));

        token.push(ali, 200 ether);
        token.push(bob, 200 ether);
        
        ozToken.mint(address(this), 1000 ether);
    }

    function test_startAuction() public {
        assertEq(codex.credit(address(this)), 1000 ether);
        assertEq(codex.credit(address(surplusAuction)), 0 ether);
        surplusAuction.startAuction({creditToSell: 100 ether, bid: 0});
        assertEq(codex.credit(address(this)), 900 ether);
        assertEq(codex.credit(address(surplusAuction)), 100 ether);
    }

    function test_submitBid() public {
        uint256 id = surplusAuction.startAuction({creditToSell: 100 ether, bid: 0});
        // creditToSell taken from creator
        assertEq(codex.credit(address(this)), 900 ether);

        Guy(ali).submitBid(id, 100 ether, 1 ether);
        // bid taken from bidder
        assertEq(token.balanceOf(ali), 199 ether);
        // payment remains in auction
        assertEq(token.balanceOf(address(surplusAuction)), 1 ether);

        Guy(bob).submitBid(id, 100 ether, 2 ether);
        // bid taken from bidder
        assertEq(token.balanceOf(bob), 198 ether);
        // prev bidder refunded
        assertEq(token.balanceOf(ali), 200 ether);
        // excess remains in auction
        assertEq(token.balanceOf(address(surplusAuction)), 2 ether);

        hevm.warp(block.timestamp + 5 weeks);
        Guy(bob).closeAuction(id);
        // high bidder gets the creditToSell
        assertEq(codex.credit(address(surplusAuction)), 0 ether);
        assertEq(codex.credit(bob), 100 ether);
        // income is burned
        assertEq(token.balanceOf(address(surplusAuction)), 0 ether);
    }

    function test_submitBid_same_bidder() public {
        uint256 id = surplusAuction.startAuction({creditToSell: 100 ether, bid: 0});
        Guy(ali).submitBid(id, 100 ether, 190 ether);
        assertEq(token.balanceOf(ali), 10 ether);
        Guy(ali).submitBid(id, 100 ether, 200 ether);
        assertEq(token.balanceOf(ali), 0);
    }

    function test_minBidBump() public {
        uint256 id = surplusAuction.startAuction({creditToSell: 100 ether, bid: 0});
        assertTrue(Guy(ali).try_submitBid(id, 100 ether, 1.00 ether));
        assertTrue(!Guy(bob).try_submitBid(id, 100 ether, 1.01 ether));
        // high bidder is subject to minBidBump
        assertTrue(!Guy(ali).try_submitBid(id, 100 ether, 1.01 ether));
        assertTrue(Guy(bob).try_submitBid(id, 100 ether, 1.07 ether));
    }

    function test_redoAuction() public {
        // start an auction
        uint256 id = surplusAuction.startAuction({creditToSell: 100 ether, bid: 0});
        // check no redoAuction
        assertTrue(!Guy(ali).try_redoAuction(id));
        // run past the auctionExpiry
        hevm.warp(block.timestamp + 2 weeks);
        // check not biddable
        assertTrue(!Guy(ali).try_submitBid(id, 100 ether, 1 ether));
        assertTrue(Guy(ali).try_redoAuction(id));
        // check biddable
        assertTrue(Guy(ali).try_submitBid(id, 100 ether, 1 ether));
    }

    function test_cancelAuction() public {
        // start an auction
        uint256 id = surplusAuction.startAuction({creditToSell: 100 ether, bid: 0});
        surplusAuction.lock(0);
        surplusAuction.cancelAuction(id);
    }
    
    function testFail_OZ_transferFrom() public {
        ozToken.transferFrom(address(this), address(2), 1000 ether); 
    }

    function test_transferFrom() public {
        token.transferFrom(address(this), address(2), 600 ether);    
        assertEq(token.balanceOf(address(2)), 600 ether);  
        assertEq(token.balanceOf(address(this)), 0);  
    }

    function testFail_OZ_transfer_to_ZERO_address() public {
        ozToken.transfer(address(0), 600 ether);    
    }

    function test_transfer_to_ZERO_address() public {
        token.transfer(address(0), 600 ether); 
        assertEq(token.balanceOf(address(0)), 600 ether);
        assertEq(token.balanceOf(address(this)), 0);     
    }
    
    
}
