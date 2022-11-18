// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2015-2019  DappHub, LLC
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {FIAT} from "../../../core/FIAT.sol";

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

contract FIATTest is Test {
    uint256 constant initialBalanceThis = 1000;
    uint256 constant initialBalanceCal = 100;

    FIAT token;
    address user1;
    address user2;
    address self;

    uint256 amount = 2;
    uint256 fee = 1;
    uint256 nonce = 0;
    uint256 deadline = 0;
    address cal = 0xcfDFCdf4e30Cf2C9CAa2C239677C8d42Ad7D67DE;
    address del = 0x0D1d31abea2384b0D5add552E3a9b9F66d57e141;
    bytes32 r = 0x748703fa9efcb5ee2d6a139b95d97b3b09425af631cb8f655de82290b71cdf6f;
    bytes32 s = 0x13841519f7fb9b5a7ef44890b2a72881ade66a8b5e0938faf0c50ef722976c46;
    uint8 v = 28;
    bytes32 _r = 0xce0a22140b7337647fadd3edd4d259b4ba9bc1ddaac6b01ccd32fb819110fb8e;
    bytes32 _s = 0x6e7042e66108e942443bbdc9a2e44ade57076e0a6a439e776f408bb62b1d1fde;
    uint8 _v = 27;

    function setUp() public {
        vm.warp(604411200);
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
        token.transfer(address(1), 10);
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
        assertEq(address(token), address(0xf925e7d14E89736700B73CA27ECceeB0A088383f));
    }

    // function testTypehash() public {
    //     assertEq(token.PERMIT_TYPEHASH(), 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9);
    // }

    function testDomain_Separator() public {
        assertEq(token.DOMAIN_SEPARATOR(), 0x8673d444f3cdb44a6bb79630d783d242b053179e888b428d52db9d29e0e76ba9);
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
        vm.warp(block.timestamp + 2 hours);
        assertEq(block.timestamp, 604411200 + 2 hours);
        token.permit(cal, del, type(uint256).max, 1, _v, _r, _s);
    }

    function testFailReplay() public {
        token.permit(cal, del, type(uint256).max, type(uint256).max, v, r, s);
        token.permit(cal, del, type(uint256).max, type(uint256).max, v, r, s);
    }
}
