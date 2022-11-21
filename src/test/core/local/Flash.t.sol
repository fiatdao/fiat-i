// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2021 FIAT Foundation
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {DSToken} from "../../utils/dapphub/DSToken.sol";
import {DSValue} from "../../utils/dapphub/DSValue.sol";

import {Aer} from "../../../core/Aer.sol";
import {Codex} from "../../../core/Codex.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {IVault, Vault20} from "../../../vaults/Vault.sol";
import "../../../core/Flash.sol";

contract TestCodex is Codex {
    function mint(address usr, uint256 wad) public {
        credit[usr] += wad;
    }
}

contract TestAer is Aer {
    constructor(
        address codex,
        address surplusAuction,
        address debtAuction
    ) Aer(codex, surplusAuction, debtAuction) {}
}

contract TestImmediatePaybackReceiver is FlashLoanReceiverBase {
    constructor(address flash) FlashLoanReceiverBase(flash) {}

    function onFlashLoan(
        address _sender,
        address _token,
        uint256 _amount,
        uint256 _fee,
        bytes calldata
    ) external override returns (bytes32) {
        _sender;
        _token;
        // Just pay back the original amount
        approvePayback(add(_amount, _fee));

        return CALLBACK_SUCCESS;
    }

    function onCreditFlashLoan(
        address _sender,
        uint256 _amount,
        uint256 _fee,
        bytes calldata
    ) external override returns (bytes32) {
        _sender;
        // Just pay back the original amount
        payBackCredit(add(_amount, _fee));

        return CALLBACK_SUCCESS_CREDIT;
    }
}

contract TestReentrancyReceiver is FlashLoanReceiverBase {
    TestImmediatePaybackReceiver public immediatePaybackReceiver;

    constructor(address flash) FlashLoanReceiverBase(flash) {
        immediatePaybackReceiver = new TestImmediatePaybackReceiver(flash);
    }

    function onFlashLoan(
        address _sender,
        address _token,
        uint256 _amount,
        uint256 _fee,
        bytes calldata _data
    ) external override returns (bytes32) {
        _sender;
        flash.flashLoan(immediatePaybackReceiver, _token, _amount + _fee, _data);

        approvePayback(add(_amount, _fee));

        return CALLBACK_SUCCESS;
    }

    function onCreditFlashLoan(
        address _sender,
        uint256 _amount,
        uint256 _fee,
        bytes calldata _data
    ) external override returns (bytes32) {
        _sender;
        flash.creditFlashLoan(immediatePaybackReceiver, _amount + _fee, _data);

        payBackCredit(add(_amount, _fee));

        return CALLBACK_SUCCESS_CREDIT;
    }
}

contract TestDEXTradeReceiver is FlashLoanReceiverBase {
    FIAT public fiat;
    Moneta public moneta;
    DSToken public token;
    IVault public vaultA;

    constructor(
        address flash,
        address fiat_,
        address moneta_,
        address token_,
        address vaultA_
    ) FlashLoanReceiverBase(flash) {
        fiat = FIAT(fiat_);
        moneta = Moneta(moneta_);
        token = DSToken(token_);
        vaultA = IVault(vaultA_);
    }

    function onFlashLoan(
        address _sender,
        address _token,
        uint256 _amount,
        uint256 _fee,
        bytes calldata
    ) external override returns (bytes32) {
        _sender;
        _token;
        address me = address(this);
        uint256 totalDebt = _amount + _fee;
        uint256 tokenAmount = totalDebt * 3;

        // Perform a "trade"
        fiat.burn(me, _amount);
        token.mint(me, tokenAmount);

        // Mint some more fiat to repay the original loan
        token.approve(address(vaultA));
        vaultA.enter(0, me, tokenAmount);
        Codex(address(flash.codex())).modifyCollateralAndDebt(
            address(vaultA),
            0,
            me,
            me,
            me,
            int256(tokenAmount),
            int256(totalDebt)
        );
        flash.codex().grantDelegate(address(flash.moneta()));
        flash.moneta().exit(me, totalDebt);

        approvePayback(add(_amount, _fee));

        return CALLBACK_SUCCESS;
    }

    function onCreditFlashLoan(
        address _sender,
        uint256 _amount,
        uint256 _fee,
        bytes calldata _data
    ) external pure override returns (bytes32) {
        _sender;
        _amount;
        _fee;
        _data;
        return CALLBACK_SUCCESS_CREDIT;
    }
}

contract TestBadReturn is FlashLoanReceiverBase {
    bytes32 public constant BAD_HASH = keccak256("my bad hash");

    constructor(address flash) FlashLoanReceiverBase(flash) {}

    function onFlashLoan(
        address _sender,
        address _token,
        uint256 _amount,
        uint256 _fee,
        bytes calldata
    ) external override returns (bytes32) {
        _sender;
        _token;
        approvePayback(add(_amount, _fee));

        return BAD_HASH;
    }

    function onCreditFlashLoan(
        address _sender,
        uint256 _amount,
        uint256 _fee,
        bytes calldata
    ) external override returns (bytes32) {
        _sender;
        payBackCredit(add(_amount, _fee));

        return BAD_HASH;
    }
}

contract TestNoCallbacks {}

contract FlashTest is Test {
    address public me;

    TestCodex public codex;
    Collybus public collybus;
    TestAer public aer;
    IVault public vaultA;
    DSToken public token;
    Moneta public moneta;
    FIAT public fiat;

    Flash public flash;

    TestImmediatePaybackReceiver public immediatePaybackReceiver;
    TestReentrancyReceiver public reentrancyReceiver;
    TestDEXTradeReceiver public dexTradeReceiver;
    TestBadReturn public badReturn;
    TestNoCallbacks public noCallbacks;

    function setUp() public {
        me = address(this);

        codex = new TestCodex();
        codex = codex;

        collybus = new Collybus();
        codex.allowCaller(codex.ANY_SIG(), address(collybus));

        aer = new TestAer(address(codex), address(0), address(0));

        token = new DSToken("Token");
        token.mint(1000 ether);

        vaultA = new Vault20(address(codex), address(token), address(collybus));
        codex.init(address(vaultA));
        codex.allowCaller(codex.ANY_SIG(), address(vaultA));
        token.approve(address(vaultA));
        vaultA.enter(0, me, 1000 ether);

        fiat = new FIAT();
        moneta = new Moneta(address(codex), address(fiat));
        codex.allowCaller(codex.ANY_SIG(), address(moneta));
        fiat.allowCaller(fiat.ANY_SIG(), address(moneta));

        flash = new Flash(address(moneta));

        collybus.setParam(address(vaultA), bytes32("liquidationRatio"), 2 ether);

        collybus.updateSpot(address(token), 5 ether);

        codex.setParam(address(vaultA), "debtCeiling", 1000 ether);
        codex.setParam("globalDebtCeiling", 1000 ether);

        token.approve(address(codex));

        assertEq(codex.balances(address(vaultA), 0, me), 1000 ether);
        assertEq(codex.credit(me), 0);
        codex.modifyCollateralAndDebt(address(vaultA), 0, me, me, me, 40 ether, 100 ether);
        assertEq(codex.balances(address(vaultA), 0, me), 960 ether);
        assertEq(codex.credit(me), 100 ether);

        // Basic auth and 1000 fiat debt ceiling
        flash.setParam("max", 1000 ether);
        codex.allowCaller(codex.ANY_SIG(), address(flash));

        immediatePaybackReceiver = new TestImmediatePaybackReceiver(address(flash));
        reentrancyReceiver = new TestReentrancyReceiver(address(flash));
        dexTradeReceiver = new TestDEXTradeReceiver(
            address(flash),
            address(fiat),
            address(moneta),
            address(token),
            address(vaultA)
        );
        badReturn = new TestBadReturn(address(flash));
        noCallbacks = new TestNoCallbacks();
        fiat.allowCaller(fiat.ANY_SIG(), address(dexTradeReceiver));
    }

    function test_mint_payback() public {
        flash.creditFlashLoan(immediatePaybackReceiver, 10 ether, "");
        flash.flashLoan(immediatePaybackReceiver, address(fiat), 10 ether, "");

        assertEq(codex.credit(address(immediatePaybackReceiver)), 0);
        assertEq(codex.unbackedDebt(address(immediatePaybackReceiver)), 0);
        assertEq(codex.credit(address(flash)), 0);
        assertEq(codex.unbackedDebt(address(flash)), 0);
    }

    function testFail_flash_codex_not_live() public {
        codex.lock();
        flash.creditFlashLoan(immediatePaybackReceiver, 10 ether, "");
    }

    function testFail_codex_flash_codex_not_live() public {
        codex.lock();
        flash.flashLoan(immediatePaybackReceiver, address(fiat), 10 ether, "");
    }

    // test mint() for _amount == 0
    function test_mint_zero_amount() public {
        flash.creditFlashLoan(immediatePaybackReceiver, 0, "");
        flash.flashLoan(immediatePaybackReceiver, address(fiat), 0, "");
    }

    // test mint() for _amount > max borrowable amount
    function testFail_mint_amount_over_max1() public {
        flash.creditFlashLoan(immediatePaybackReceiver, 1001 ether, "");
    }

    function testFail_mint_amount_over_max2() public {
        flash.flashLoan(immediatePaybackReceiver, address(fiat), 1001 ether, "");
    }

    // test max == 0 means flash minting is halted
    function testFail_mint_max_zero1() public {
        flash.setParam("max", 0);

        flash.creditFlashLoan(immediatePaybackReceiver, 10 ether, "");
    }

    function testFail_mint_max_zero2() public {
        flash.setParam("max", 0);

        flash.flashLoan(immediatePaybackReceiver, address(fiat), 10 ether, "");
    }

    // test unauthorized createUnbackedDebt() reverts
    function testFail_mint_unauthorized_createUnbackedDebt1() public {
        codex.blockCaller(codex.ANY_SIG(), address(flash));

        flash.creditFlashLoan(immediatePaybackReceiver, 10 ether, "");
    }

    function testFail_mint_unauthorized_createUnbackedDebt2() public {
        codex.blockCaller(codex.ANY_SIG(), address(flash));

        flash.flashLoan(immediatePaybackReceiver, address(fiat), 10 ether, "");
    }

    // test reentrancy disallowed
    function testFail_mint_reentrancy1() public {
        flash.creditFlashLoan(reentrancyReceiver, 100 ether, "");
    }

    function testFail_mint_reentrancy2() public {
        flash.flashLoan(reentrancyReceiver, address(fiat), 100 ether, "");
    }

    // test trading flash minted fiat for token and minting more fiat
    function test_dex_trade() public {
        // Set the owner temporarily to allow the receiver to mint
        token.setOwner(address(dexTradeReceiver));
        flash.flashLoan(dexTradeReceiver, address(fiat), 100 ether, "");
    }

    // test excessive max borrowable amount
    function testFail_max_limit() public {
        flash.setParam("max", 10**45 + 1);
    }

    function test_max_flash_loan() public {
        assertEq(flash.maxFlashLoan(address(fiat)), 1000 ether);
        assertEq(flash.maxFlashLoan(address(moneta)), 0); // Any other address should be 0 as per the spec
    }

    function test_flash_fee() public {
        assertEq(flash.flashFee(address(fiat), 100 ether), 0);
    }

    function testFail_flash_fee() public view {
        flash.flashFee(address(moneta), 100 ether); // Any other address should fail
    }

    function testFail_bad_token() public {
        flash.flashLoan(immediatePaybackReceiver, address(moneta), 100 ether, "");
    }

    function testFail_bad_return_hash1() public {
        flash.creditFlashLoan(badReturn, 100 ether, "");
    }

    function testFail_bad_return_hash2() public {
        flash.flashLoan(badReturn, address(fiat), 100 ether, "");
    }

    function testFail_no_callbacks1() public {
        flash.creditFlashLoan(ICreditFlashBorrower(address(noCallbacks)), 100 ether, "");
    }

    function testFail_no_callbacks2() public {
        flash.flashLoan(IERC3156FlashBorrower(address(noCallbacks)), address(fiat), 100 ether, "");
    }
}
