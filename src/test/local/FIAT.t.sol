// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2015-2019  DappHub, LLC
pragma solidity ^0.8.4;

import {DSTest} from "ds-test/test.sol";

import {FIAT} from "../../FIAT.sol";

contract TokenUser {
    FIAT token;

    constructor(FIAT token_) {
        token = token_;
    }

    function doTransferFrom(
        address from,
        address to,
        uint256 amount
    ) public returns (bool) {
        return token.transferFrom(from, to, amount);
    }

    function doTransfer(address to, uint256 amount) public returns (bool) {
        return token.transfer(to, amount);
    }

    function doApprove(address recipient, uint256 amount) public returns (bool) {
        return token.approve(recipient, amount);
    }

    function doAllowance(address owner, address spender) public view returns (uint256) {
        return token.allowance(owner, spender);
    }

    function doBalanceOf(address user) public view returns (uint256) {
        return token.balanceOf(user);
    }

    function doApprove(address spender) public returns (bool) {
        return token.approve(spender, type(uint256).max);
    }

    function doMint(uint256 amount) public {
        token.mint(address(this), amount);
    }

    function doBurn(uint256 amount) public {
        token.burn(address(this), amount);
    }

    function doMint(address to, uint256 amount) public {
        token.mint(to, amount);
    }

    function doBurn(address guy, uint256 amount) public {
        token.burn(guy, amount);
    }
}

interface Hevm {
    function warp(uint256) external;
}

contract FIATTest is DSTest {
    uint256 constant initialBalanceThis = 1000;
    uint256 constant initialBalanceCal = 100;

    FIAT token;
    Hevm hevm;
    address user1;
    address user2;
    address self;

    uint256 amount = 2;
    uint256 fee = 1;
    uint256 nonce = 0;
    uint256 deadline = 0;
    address cal = 0xcfDFCdf4e30Cf2C9CAa2C239677C8d42Ad7D67DE;
    address del = 0x0D1d31abea2384b0D5add552E3a9b9F66d57e141;
    bytes32 r = 0xbd9e56f723dae1735e8810e4896abe0c163137e26514f5d065c024a0edb574e0;
    bytes32 s = 0x27ce44662fb1886dd3533eac9b9ff307d6a38f917e510db3addeef265028e241;
    uint8 v = 27;
    bytes32 _r = 0x02e0fc3b8b48ac6c7f90e9639b1da5307956f506f472b6e280618e8c83c411e2;
    bytes32 _s = 0x06f719b9e0623bc3b05c31100fb70c520eaecc8ec12cb2ef1ea781a23fc45735;
    uint8 _v = 28;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);
        token = createToken();
        token.mint(address(this), initialBalanceThis);
        token.mint(cal, initialBalanceCal);
        user1 = address(new TokenUser(token));
        user2 = address(new TokenUser(token));
        self = address(this);
    }

    function createToken() internal returns (FIAT) {
        return new FIAT();
    }

    function testSetupPrecondition() public {
        assertEq(token.balanceOf(self), initialBalanceThis);
    }

    function testTransferCost() public logs_gas {
        token.transfer(address(0), 10);
    }

    function testAllowanceStartsAtZero() public logs_gas {
        assertEq(token.allowance(user1, user2), 0);
    }

    function testValidTransfers() public logs_gas {
        uint256 sentAmount = 250;
        emit log_named_address("token11111", address(token));
        token.transfer(user2, sentAmount);
        assertEq(token.balanceOf(user2), sentAmount);
        assertEq(token.balanceOf(self), initialBalanceThis - sentAmount);
    }

    function testFailWrongAccountTransfers() public logs_gas {
        uint256 sentAmount = 250;
        token.transferFrom(user2, self, sentAmount);
    }

    function testFailInsufficientFundsTransfers() public logs_gas {
        uint256 sentAmount = 250;
        token.transfer(user1, initialBalanceThis - sentAmount);
        token.transfer(user2, sentAmount + 1);
    }

    function testApproveSetsAllowance() public logs_gas {
        emit log_named_address("Test", self);
        emit log_named_address("Token", address(token));
        emit log_named_address("Me", self);
        emit log_named_address("User 2", user2);
        token.approve(user2, 25);
        assertEq(token.allowance(self, user2), 25);
    }

    function testChargesAmountApproved() public logs_gas {
        uint256 amountApproved = 20;
        token.approve(user2, amountApproved);
        assertTrue(TokenUser(user2).doTransferFrom(self, user2, amountApproved));
        assertEq(token.balanceOf(self), initialBalanceThis - amountApproved);
    }

    function testFailTransferWithoutApproval() public logs_gas {
        token.transfer(user1, 50);
        token.transferFrom(user1, self, 1);
    }

    function testFailChargeMoreThanApproved() public logs_gas {
        token.transfer(user1, 50);
        TokenUser(user1).doApprove(self, 20);
        token.transferFrom(user1, self, 21);
    }

    function testTransferFromSelf() public {
        token.transferFrom(self, user1, 50);
        assertEq(token.balanceOf(user1), 50);
    }

    function testFailTransferFromSelfNonArbitrarySize() public {
        // you shouldn't be able to evade balance checks by transferring
        // to yourself
        token.transferFrom(self, self, token.balanceOf(self) + 1);
    }

    function testMintself() public {
        uint256 mintAmount = 10;
        token.mint(address(this), mintAmount);
        assertEq(token.balanceOf(self), initialBalanceThis + mintAmount);
    }

    function testMintGuy() public {
        uint256 mintAmount = 10;
        token.mint(user1, mintAmount);
        assertEq(token.balanceOf(user1), mintAmount);
    }

    function testFailMintGuyNoAuth() public {
        TokenUser(user1).doMint(user2, 10);
    }

    function testMintGuyAuth() public {
        token.allowCaller(keccak256("ANY_SIG"), user1);
        TokenUser(user1).doMint(user2, 10);
    }

    function testBurn() public {
        uint256 burnAmount = 10;
        token.burn(address(this), burnAmount);
        assertEq(token.totalSupply(), initialBalanceThis + initialBalanceCal - burnAmount);
    }

    function testBurnself() public {
        uint256 burnAmount = 10;
        token.burn(address(this), burnAmount);
        assertEq(token.balanceOf(self), initialBalanceThis - burnAmount);
    }

    function testBurnGuyWithTrust() public {
        uint256 burnAmount = 10;
        token.transfer(user1, burnAmount);
        assertEq(token.balanceOf(user1), burnAmount);

        TokenUser(user1).doApprove(self);
        token.burn(user1, burnAmount);
        assertEq(token.balanceOf(user1), 0);
    }

    function testBurnAuth() public {
        token.transfer(user1, 10);
        token.allowCaller(keccak256("ANY_SIG"), user1);
        TokenUser(user1).doBurn(10);
    }

    function testBurnGuyAuth() public {
        token.transfer(user2, 10);
        //        token.allowCaller(keccak256("ANY_SIG"), user1);
        TokenUser(user2).doApprove(user1);
        TokenUser(user1).doBurn(user2, 10);
    }

    function testFailUntrustedTransferFrom() public {
        assertEq(token.allowance(self, user2), 0);
        TokenUser(user1).doTransferFrom(self, user2, 200);
    }

    function testTrusting() public {
        assertEq(token.allowance(self, user2), 0);
        token.approve(user2, type(uint256).max);
        assertEq(token.allowance(self, user2), type(uint256).max);
        token.approve(user2, 0);
        assertEq(token.allowance(self, user2), 0);
    }

    function testTrustedTransferFrom() public {
        token.approve(user1, type(uint256).max);
        TokenUser(user1).doTransferFrom(self, user2, 200);
        assertEq(token.balanceOf(user2), 200);
    }

    function testApproveWillModifyAllowance() public {
        assertEq(token.allowance(self, user1), 0);
        assertEq(token.balanceOf(user1), 0);
        token.approve(user1, 1000);
        assertEq(token.allowance(self, user1), 1000);
        TokenUser(user1).doTransferFrom(self, user1, 500);
        assertEq(token.balanceOf(user1), 500);
        assertEq(token.allowance(self, user1), 500);
    }

    function testApproveWillNotModifyAllowance() public {
        assertEq(token.allowance(self, user1), 0);
        assertEq(token.balanceOf(user1), 0);
        token.approve(user1, type(uint256).max);
        assertEq(token.allowance(self, user1), type(uint256).max);
        TokenUser(user1).doTransferFrom(self, user1, 1000);
        assertEq(token.balanceOf(user1), 1000);
        assertEq(token.allowance(self, user1), type(uint256).max);
    }

    function testFIATAddress() public {
        //The credit address generated by hevm
        //used for signature generation testing
        assertEq(address(token), address(0x2e0F3B1C5444c0225c74fb17446065f136AC87C6));
    }

    function testTypehash() public {
        assertEq(token.PERMIT_TYPEHASH(), 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9);
    }

    function testDomain_Separator() public {
        assertEq(token.DOMAIN_SEPARATOR(), 0xb39b3fd4d9ebbdfd9d7dc59bb1c912ea4e454d7b7fd5f1089dd02a16e034595c);
    }

    function testPermit() public {
        assertEq(token.nonces(cal), 0);
        assertEq(token.allowance(cal, del), 0);
        token.permit(cal, del, type(uint256).max, type(uint256).max, v, r, s);
        assertEq(token.allowance(cal, del), type(uint256).max);
        assertEq(token.nonces(cal), 1);
    }

    function testFailPermitAddress0() public {
        v = 0;
        token.permit(address(0), del, type(uint256).max, type(uint256).max, v, r, s);
    }

    function testPermitWithExpiry() public {
        assertEq(block.timestamp, 604411200);
        token.permit(cal, del, type(uint256).max, 604411200 + 1 hours, _v, _r, _s);
        assertEq(token.allowance(cal, del), type(uint256).max);
        assertEq(token.nonces(cal), 1);
    }

    function testFailPermitWithExpiry() public {
        hevm.warp(block.timestamp + 2 hours);
        assertEq(block.timestamp, 604411200 + 2 hours);
        token.permit(cal, del, type(uint256).max, 1, _v, _r, _s);
    }

    function testFailReplay() public {
        token.permit(cal, del, type(uint256).max, type(uint256).max, v, r, s);
        token.permit(cal, del, type(uint256).max, type(uint256).max, v, r, s);
    }
}