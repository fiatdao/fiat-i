// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2021 FIAT Foundation
pragma solidity ^0.8.4;

import "ds-test/test.sol";

import {DSToken} from "../utils/dapphub/DSToken.sol";
import {DSValue} from "../utils/dapphub/DSValue.sol";

import {Aer} from "../../Aer.sol";
import {Codex} from "../../Codex.sol";
import {Collybus} from "../../Collybus.sol";
import {FIAT} from "../../FIAT.sol";
import {Moneta} from "../../Moneta.sol";
import {IVault, Vault20} from "../../Vault.sol";

import "../../Flash.sol";

interface Hevm {
    function warp(uint256) external;
    function store(address,bytes32,bytes32) external;
}

contract TestCodex is Codex {
    function mint(address usr, uint256 wad) public {
        credit[usr] += wad;
    }
}

contract TestAer is Aer {
    
    constructor(address codex, address surplusAuction, address debtAuction) Aer(codex, surplusAuction, debtAuction) {}

    // Total deficit
    function Awe() public view returns (uint256) {
        return codex.unbackedDebt(address(this));
    }
    // Total surplus
    function Joy() public view returns (uint256) {
        return codex.credit(address(this));
    }
    // Unqueued, pre-auction debt
    function Woe() public view returns (uint256) {
        return sub(sub(Awe(), queuedDebt), debtOnAuction);
    }
}

contract TestDoNothingReceiver is FlashLoanReceiverBase {

    constructor(address flash) FlashLoanReceiverBase(flash) {
    }

    function onFlashLoan(
        address _sender, address _token, uint256 _amount, uint256 _fee, bytes calldata
    ) external pure override returns (bytes32) {
        _sender; _token; _amount; _fee;
        // Don't do anything
        return CALLBACK_SUCCESS;
    }

    function onCreditFlashLoan(
        address _sender, uint256 _amount, uint256 _fee, bytes calldata
    ) external pure override returns (bytes32) {
        _sender; _amount; _fee;
        // Don't do anything
        return CALLBACK_SUCCESS_CREDIT;
    }
}

contract TestImmediatePaybackReceiver is FlashLoanReceiverBase {

    constructor(address flash) FlashLoanReceiverBase(flash) {}

    function onFlashLoan(
        address _sender, address _token, uint256 _amount, uint256 _fee, bytes calldata
    ) external override returns (bytes32) {
        _sender; _token;
        // Just pay back the original amount
        approvePayback(add(_amount, _fee));

        return CALLBACK_SUCCESS;
    }

    function onCreditFlashLoan(
        address _sender, uint256 _amount, uint256 _fee, bytes calldata
    ) external override returns (bytes32) {
        _sender;
        // Just pay back the original amount
        payBackCredit(add(_amount, _fee));

        return CALLBACK_SUCCESS_CREDIT;
    }
}

contract TestLoanAndPaybackReceiver is FlashLoanReceiverBase {

    uint256 public mint;

    constructor(address _flash) FlashLoanReceiverBase(_flash) {}

    function setMint(uint256 _mint) public {
        mint = _mint;
    }

    function onFlashLoan(
        address _sender, address _token, uint256 _amount, uint256 _fee, bytes calldata
    ) external override returns (bytes32) {
        _sender; _token;
        TestCodex(address(flash.codex())).mint(address(this), mint);
        flash.codex().grantDelegate(address(flash.moneta()));
        flash.moneta().exit(address(this), mint);

        approvePayback(add(_amount, _fee));

        return CALLBACK_SUCCESS;
    }

    function onCreditFlashLoan(
        address _sender, uint256 _amount, uint256 _fee, bytes calldata
    ) external override returns (bytes32) {
        _sender;
        TestCodex(address(flash.codex())).mint(address(this), mint);

        payBackCredit(add(_amount, _fee));

        return CALLBACK_SUCCESS_CREDIT;
    }
}

contract TestLoanAndPaybackAllReceiver is FlashLoanReceiverBase {

    uint256 public mint;

    constructor(address _flash) FlashLoanReceiverBase(_flash) {}

    function setMint(uint256 _mint) public {
        mint = _mint;
    }

    function onFlashLoan(
        address _sender, address _token, uint256 _amount, uint256 _fee, bytes calldata
    ) external override returns (bytes32) {
        _sender; _token; _fee;
        TestCodex(address(flash.codex())).mint(address(this), mint);
        flash.codex().grantDelegate(address(flash.moneta()));
        flash.moneta().exit(address(this), mint);

        approvePayback(add(_amount, mint));

        return CALLBACK_SUCCESS;
    }

    function onCreditFlashLoan(
        address _sender, uint256 _amount, uint256 _fee, bytes calldata
    ) external override returns (bytes32) {
        _sender; _fee;
        TestCodex(address(flash.codex())).mint(address(this), mint);

        payBackCredit(add(_amount, mint));

        return CALLBACK_SUCCESS_CREDIT;
    }
}

contract TestLoanAndPaybackDataReceiver is FlashLoanReceiverBase {

    constructor(address flash) FlashLoanReceiverBase(flash) {}

    function onFlashLoan(
        address _sender, address _token, uint256 _amount, uint256 _fee, bytes calldata _data
    ) external override returns (bytes32) {
        _sender; _token;
        (uint256 mint) = abi.decode(_data, (uint256));
        TestCodex(address(flash.codex())).mint(address(this), mint);
        flash.codex().grantDelegate(address(flash.moneta()));
        flash.moneta().exit(address(this), mint);

        approvePayback(add(_amount, _fee));

        return CALLBACK_SUCCESS;
    }

    function onCreditFlashLoan(
        address _sender, uint256 _amount, uint256 _fee, bytes calldata _data
    ) external override returns (bytes32) {
        _sender;
        (uint256 mint) = abi.decode(_data, (uint256));
        TestCodex(address(flash.codex())).mint(address(this), mint);

        payBackCredit(add(_amount, _fee));

        return CALLBACK_SUCCESS_CREDIT;
    }
}

contract TestReentrancyReceiver is FlashLoanReceiverBase {

    TestImmediatePaybackReceiver public immediatePaybackReceiver;

    // --- Init ---
    constructor(address flash) FlashLoanReceiverBase(flash) {
        immediatePaybackReceiver = new TestImmediatePaybackReceiver(flash);
    }

    function onFlashLoan(
        address _sender, address _token, uint256 _amount, uint256 _fee, bytes calldata _data
    ) external override returns (bytes32) {
        _sender;
        flash.flashLoan(immediatePaybackReceiver, _token, _amount + _fee, _data);

        approvePayback(add(_amount, _fee));

        return CALLBACK_SUCCESS;
    }

    function onCreditFlashLoan(
        address _sender, uint256 _amount, uint256 _fee, bytes calldata _data
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
    DSToken public gold;
    IVault public gemA;

    constructor(
        address flash, address fiat_, address moneta_, address gold_, address gemA_
    ) FlashLoanReceiverBase(flash) {
        fiat = FIAT(fiat_);
        moneta = Moneta(moneta_);
        gold = DSToken(gold_);
        gemA = IVault(gemA_);
    }

    function onFlashLoan(
        address _sender, address _token, uint256 _amount, uint256 _fee, bytes calldata
    ) external override returns (bytes32) {
        _sender; _token;
        address me = address(this);
        uint256 totalDebt = _amount + _fee;
        uint256 goldAmount = totalDebt * 3;

        // Perform a "trade"
        fiat.burn(me, _amount);
        gold.mint(me, goldAmount);

        // Mint some more fiat to repay the original loan
        gold.approve(address(gemA));
        gemA.enter(0, me, goldAmount);
        Codex(address(flash.codex())).modifyCollateralAndDebt(
            address(gemA), 0, me, me, me, int256(goldAmount), int256(totalDebt)
        );
        flash.codex().grantDelegate(address(flash.moneta()));
        flash.moneta().exit(me, totalDebt);

        approvePayback(add(_amount, _fee));

        return CALLBACK_SUCCESS;
    }

    function onCreditFlashLoan(
        address _sender, uint256 _amount, uint256 _fee, bytes calldata _data
    ) external pure override returns (bytes32) {
        _sender; _amount; _fee; _data;
        return CALLBACK_SUCCESS_CREDIT;
    }
}

contract TestBadReturn is FlashLoanReceiverBase {

    bytes32 constant public BAD_HASH = keccak256("my bad hash");

    constructor(address flash) FlashLoanReceiverBase(flash) {}

    function onFlashLoan(
        address _sender, address _token, uint256 _amount, uint256 _fee, bytes calldata
    ) external override returns (bytes32) {
        _sender; _token;
        approvePayback(add(_amount, _fee));

        return BAD_HASH;
    }

    function onCreditFlashLoan(
        address _sender, uint256 _amount, uint256 _fee, bytes calldata
    ) external override returns (bytes32) {
        _sender;
        payBackCredit(add(_amount, _fee));

        return BAD_HASH;
    }
}

contract TestNoCallbacks {}

contract FlashTest is DSTest {
    Hevm internal hevm;

    address public me;

    TestCodex public codex;
    Collybus public collybus;
    TestAer public aer;
    DSValue public pip;
    IVault public gemA;
    DSToken public gold;
    Moneta public moneta;
    FIAT public fiat;

    Flash public flash;

    TestDoNothingReceiver public doNothingReceiver;
    TestImmediatePaybackReceiver public immediatePaybackReceiver;
    TestLoanAndPaybackReceiver public mintAndPaybackReceiver;
    TestLoanAndPaybackAllReceiver public mintAndPaybackAllReceiver;
    TestLoanAndPaybackDataReceiver public mintAndPaybackDataReceiver;
    TestReentrancyReceiver public reentrancyReceiver;
    TestDEXTradeReceiver public dexTradeReceiver;
    TestBadReturn public badReturn;
    TestNoCallbacks public noCallbacks;

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant public CHEAT_CODE = bytes20(uint160(uint256(keccak256("hevm cheat code"))));

    function setUp() public {
        hevm = Hevm(address(CHEAT_CODE));

        me = address(this);

        codex = new TestCodex();
        codex = codex;

        collybus = new Collybus();
        codex.allowCaller(codex.ANY_SIG(), address(collybus));

        aer = new TestAer(address(codex), address(0), address(0));

        gold = new DSToken("GEM");
        gold.mint(1000 ether);

        gemA = new Vault20(address(codex), address(gold), address(collybus));
        codex.init(address(gemA));
        codex.allowCaller(codex.ANY_SIG(), address(gemA));
        gold.approve(address(gemA));
        gemA.enter(0, me, 1000 ether);

        fiat = new FIAT();
        moneta = new Moneta(address(codex), address(fiat));
        codex.allowCaller(codex.ANY_SIG(), address(moneta));
        fiat.allowCaller(fiat.ANY_SIG(), address(moneta));

        flash = new Flash(address(moneta));

        pip = new DSValue();
        // pip.poke(bytes32(uint256(5 ether))); // Spot = $2.5

        collybus.setParam(address(gemA), bytes32("liquidationRatio"), 2 ether);

        collybus.updateSpot(address(gold), 5 ether);

        codex.setParam(address(gemA), "debtCeiling", 1000 ether);
        codex.setParam("globalDebtCeiling", 1000 ether);

        gold.approve(address(codex));

        assertEq(codex.balances(address(gemA), 0, me), 1000 ether);
        assertEq(codex.credit(me), 0);
        codex.modifyCollateralAndDebt(address(gemA), 0, me, me, me, 40 ether, 100 ether);
        assertEq(codex.balances(address(gemA), 0, me), 960 ether);
        assertEq(codex.credit(me), 100 ether);

        // Basic auth and 1000 fiat debt ceiling
        flash.setParam("max", 1000 ether);
        codex.allowCaller(codex.ANY_SIG(), address(flash));

        doNothingReceiver = new TestDoNothingReceiver(address(flash));
        immediatePaybackReceiver = new TestImmediatePaybackReceiver(address(flash));
        mintAndPaybackReceiver = new TestLoanAndPaybackReceiver(address(flash));
        mintAndPaybackAllReceiver = new TestLoanAndPaybackAllReceiver(address(flash));
        mintAndPaybackDataReceiver = new TestLoanAndPaybackDataReceiver(address(flash));
        reentrancyReceiver = new TestReentrancyReceiver(address(flash));
        dexTradeReceiver = new TestDEXTradeReceiver(
            address(flash), address(fiat), address(moneta), address(gold), address(gemA)
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

    function testFail_flash_vat_not_live() public {
        codex.lock();
        flash.creditFlashLoan(immediatePaybackReceiver, 10 ether, "");
    }

    function testFail_vat_flash_vat_not_live() public {
        codex.lock();
        flash.flashLoan(immediatePaybackReceiver, address(fiat), 10 ether, "");
    }

    // test mint() for _amount == 0
    function test_mint_zero_amount() public {
        flash.creditFlashLoan(immediatePaybackReceiver, 0, "");
        flash.flashLoan(immediatePaybackReceiver, address(fiat), 0, "");
    }

    // test mint() for _amount > line
    function testFail_mint_amount_over_line1() public {
        flash.creditFlashLoan(immediatePaybackReceiver, 1001 ether, "");
    }

    function testFail_mint_amount_over_line2() public {
        flash.flashLoan(immediatePaybackReceiver, address(fiat), 1001 ether, "");
    }

    // test line == 0 means flash minting is halted
    function testFail_mint_line_zero1() public {
        flash.setParam("max", 0);

        flash.creditFlashLoan(immediatePaybackReceiver, 10 ether, "");
    }

    function testFail_mint_line_zero2() public {
        flash.setParam("max", 0);

        flash.flashLoan(immediatePaybackReceiver, address(fiat), 10 ether, "");
    }

    // test unauthorized suck() reverts
    function testFail_mint_unauthorized_suck1() public {
        codex.blockCaller(codex.ANY_SIG(), address(flash));

        flash.creditFlashLoan(immediatePaybackReceiver, 10 ether, "");
    }

    function testFail_mint_unauthorized_suck2() public {
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

    // test trading flash minted fiat for gold and minting more fiat
    function test_dex_trade() public {
        // Set the owner temporarily to allow the receiver to mint
        gold.setOwner(address(dexTradeReceiver));

        flash.flashLoan(dexTradeReceiver, address(fiat), 100 ether, "");
    }

    // test excessive max debt ceiling
    function testFail_line_limit() public {
        flash.setParam("max", 10 ** 45 + 1);
    }

    function test_max_flash_loan() public {
        assertEq(flash.maxFlashLoan(address(fiat)), 1000 ether);
        assertEq(flash.maxFlashLoan(address(moneta)), 0);  // Any other address should be 0 as per the spec
    }

    function test_flash_fee() public {
        assertEq(flash.flashFee(address(fiat), 100 ether), 0);
    }

    function testFail_flash_fee() public view {
        flash.flashFee(address(moneta), 100 ether);  // Any other address should fail
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
