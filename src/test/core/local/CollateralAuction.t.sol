// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {DSToken} from "../../utils/dapphub/DSToken.sol";
import {DSValue} from "../../utils/dapphub/DSValue.sol";

import {IVault} from "../../../interfaces/IVault.sol";

import {Codex} from "../../../core/Codex.sol";
import {CollateralAuction} from "../../../core/auctions/CollateralAuction.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {Aer} from "../../../core/Aer.sol";
import {Limes} from "../../../core/Limes.sol";
import {WAD, sub, mul} from "../../../core/utils/Math.sol";
import {Vault20} from "../../../vaults/Vault.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {StairstepExponentialDecrease, LinearDecrease} from "../../../core/auctions/PriceCalculator.sol";

uint256 constant tokenId = 0;

interface Hevm {
    function warp(uint256) external;

    function store(
        address,
        bytes32,
        bytes32
    ) external;
}

contract Exchange {
    DSToken gold;
    DSToken credit;
    uint256 goldPrice;

    constructor(
        DSToken gold_,
        DSToken credit_,
        uint256 goldPrice_
    ) {
        gold = gold_;
        credit = credit_;
        goldPrice = goldPrice_;
    }

    function sellGold(uint256 goldAmt) external {
        gold.transferFrom(msg.sender, address(this), goldAmt);
        uint256 creditAmt = (goldAmt * goldPrice) / 1e18;
        credit.transfer(msg.sender, creditAmt);
    }
}

contract Trader {
    CollateralAuction collateralAuction;
    Codex codex;
    DSToken gold;
    Vault20 goldVault;
    DSToken credit;
    Moneta moneta;
    Exchange exchange;

    constructor(
        CollateralAuction collateralAuction_,
        Codex codex_,
        DSToken gold_,
        Vault20 goldVault_,
        DSToken credit_,
        Moneta moneta_,
        Exchange exchange_
    ) {
        collateralAuction = collateralAuction_;
        codex = codex_;
        gold = gold_;
        goldVault = goldVault_;
        credit = credit_;
        moneta = moneta_;
        exchange = exchange_;
    }

    function takeCollateral(
        uint256 auctionId,
        uint256 collateralAmount,
        uint256 maxPrice,
        address recipient,
        bytes calldata data
    ) external {
        collateralAuction.takeCollateral({
            auctionId: auctionId,
            collateralAmount: collateralAmount,
            maxPrice: maxPrice,
            recipient: recipient,
            data: data
        });
    }

    function collateralAuctionCall(
        address sender,
        uint256 owe,
        uint256 collateralSlice,
        bytes calldata data
    ) external {
        data;
        goldVault.exit(0, address(this), collateralSlice);
        gold.approve(address(exchange));
        exchange.sellGold(collateralSlice);
        credit.approve(address(moneta));
        codex.grantDelegate(address(collateralAuction));
        moneta.enter(sender, owe);
    }
}

contract Guy {
    CollateralAuction collateralAuction;

    constructor(CollateralAuction collateralAuction_) {
        collateralAuction = collateralAuction_;
    }

    function grantDelegate(address user) public {
        Codex(address(collateralAuction.codex())).grantDelegate(user);
    }

    function takeCollateral(
        uint256 auctionId,
        uint256 collateralAmount,
        uint256 maxPrice,
        address recipient,
        bytes calldata data
    ) external {
        collateralAuction.takeCollateral({
            auctionId: auctionId,
            collateralAmount: collateralAmount,
            maxPrice: maxPrice,
            recipient: recipient,
            data: data
        });
    }

    function liquidate(
        Limes limes,
        address vault,
        uint256 tokenId_,
        address user,
        address keeper
    ) external {
        limes.liquidate(vault, tokenId_, user, keeper);
    }
}

contract BadGuy is Guy {
    constructor(CollateralAuction collateralAuction_) Guy(collateralAuction_) {}

    function collateralAuctionCall(
        address sender,
        uint256 owe,
        uint256 collateralSlice,
        bytes calldata data
    ) external {
        sender;
        owe;
        collateralSlice;
        data;
        collateralAuction.takeCollateral({ // attempt reentrancy
            auctionId: 1,
            collateralAmount: 25 ether,
            maxPrice: (5 ether * 10e18) / WAD,
            recipient: address(this),
            data: ""
        });
    }
}

contract RedoGuy is Guy {
    constructor(CollateralAuction collateralAuction_) Guy(collateralAuction_) {}

    function collateralAuctionCall(
        address sender,
        uint256 owe,
        uint256 collateralSlice,
        bytes calldata data
    ) external {
        owe;
        collateralSlice;
        data;
        collateralAuction.redoAuction(1, sender);
    }
}

contract StartGuy is Guy {
    address internal vault;

    constructor(CollateralAuction collateralAuction_, address vault_) Guy(collateralAuction_) {
        vault = vault_;
    }

    function collateralAuctionCall(
        address sender,
        uint256 owe,
        uint256 collateralSlice,
        bytes calldata data
    ) external {
        sender;
        owe;
        collateralSlice;
        data;
        collateralAuction.startAuction(1, 1, vault, tokenId, address(0), address(0));
    }
}

contract SetParamUintGuy is Guy {
    constructor(CollateralAuction collateralAuction_) Guy(collateralAuction_) {}

    function collateralAuctionCall(
        address sender,
        uint256 owe,
        uint256 collateralSlice,
        bytes calldata data
    ) external {
        sender;
        owe;
        collateralSlice;
        data;
        collateralAuction.setParam("stopped", 1);
    }
}

contract SetParamAddrGuy is Guy {
    constructor(CollateralAuction collateralAuction_) Guy(collateralAuction_) {}

    function collateralAuctionCall(
        address sender,
        uint256 owe,
        uint256 collateralSlice,
        bytes calldata data
    ) external {
        sender;
        owe;
        collateralSlice;
        data;
        collateralAuction.setParam("aer", address(123));
    }
}

contract YankGuy is Guy {
    constructor(CollateralAuction collateralAuction_) Guy(collateralAuction_) {}

    function collateralAuctionCall(
        address sender,
        uint256 owe,
        uint256 collateralSlice,
        bytes calldata data
    ) external {
        sender;
        owe;
        collateralSlice;
        data;
        collateralAuction.cancelAuction(1);
    }
}

contract PublicCollateralAuction is CollateralAuction {
    constructor(
        address codex,
        address collybus,
        address limes,
        address vault
    ) CollateralAuction(codex, limes) {}

    function addAuction() public returns (uint256 auctionId) {
        auctionId = ++auctionCounter;
        activeAuctions.push(auctionId);
        auctions[auctionId].index = activeAuctions.length - 1;
    }

    function removeAuction(uint256 auctionId) public {
        _remove(auctionId);
    }
}

contract CollateralAuctionTest is Test {
    Hevm hevm;

    Codex codex;
    Limes limes;
    Collybus collybus;
    Aer aer;
    DSToken gold;
    Vault20 goldVault;
    DSToken credit;
    Moneta moneta;

    CollateralAuction collateralAuction;

    address me;
    Exchange exchange;

    address ali;
    address bob;
    address che;

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant CHEAT_CODE = bytes20(uint160(uint256(keccak256("hevm cheat code"))));

    address vault;
    uint256 constant goldPrice = 5 ether;

    uint256 constant startTime = 604411200; // Used to avoid issues with `block.timestamp`

    function _collateral(
        address vault_,
        uint256 tokenId_,
        address user_
    ) internal view returns (uint256) {
        (uint256 collateral_, ) = codex.positions(vault_, tokenId_, user_);
        return collateral_;
    }

    function _normalDebt(
        address vault_,
        uint256 tokenId_,
        address user_
    ) internal view returns (uint256) {
        (, uint256 normalDebt_) = codex.positions(vault_, tokenId_, user_);
        return normalDebt_;
    }

    modifier takeCollateralSetup() {
        uint256 index;
        uint256 debt;
        uint256 collateralToSell;
        address user;
        uint96 startsAt;
        uint256 startPrice;
        uint256 collateral;
        uint256 normalDebt;

        StairstepExponentialDecrease calculator = new StairstepExponentialDecrease();
        calculator.setParam("factor", WAD - 0.01 ether); // 1% decrease
        calculator.setParam("step", 1); // Decrease every 1 second

        collateralAuction.setParam(vault, "multiplier", 1.25 ether); // 25% Initial price buffer
        collateralAuction.setParam(vault, "calculator", address(calculator)); // SetParam price contract
        collateralAuction.setParam(vault, "maxDiscount", 0.3 ether); // 70% drop before reset
        collateralAuction.setParam(vault, "maxAuctionDuration", 3600); // 1 hour before reset

        (collateral, normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 40 ether);
        assertEq(normalDebt, 100 ether);

        assertEq(collateralAuction.auctionCounter(), 0);
        limes.liquidate(vault, tokenId, me, address(this));
        assertEq(collateralAuction.auctionCounter(), 1);

        (collateral, normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);

        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 110 ether);
        assertEq(collateralToSell, 40 ether);
        assertEq(user, me);
        assertEq(uint256(startsAt), block.timestamp);
        assertEq(startPrice, 5 ether); // $4 plus 25%

        assertEq(codex.balances(vault, tokenId, ali), 0);
        assertEq(codex.credit(ali), 1000 ether);
        assertEq(codex.balances(vault, tokenId, bob), 0);
        assertEq(codex.credit(bob), 1000 ether);

        _;
    }

    function setUp() public {
        hevm = Hevm(address(CHEAT_CODE));
        hevm.warp(startTime);

        me = address(this);

        codex = new Codex();

        collybus = new Collybus();
        codex.allowCaller(keccak256("ANY_SIG"), address(collybus));

        aer = new Aer(address(codex), address(0), address(0));
        gold = new DSToken("GLD");
        goldVault = new Vault20(address(codex), address(gold), address(collybus));
        vault = address(goldVault);
        codex.allowCaller(keccak256("ANY_SIG"), address(goldVault));
        credit = new DSToken("Credit");
        moneta = new Moneta(address(codex), address(credit));
        codex.createUnbackedDebt(address(0), address(moneta), 1000 ether);
        exchange = new Exchange(gold, credit, (goldPrice * 11) / 10);

        credit.mint(1000 ether);
        credit.transfer(address(exchange), 1000 ether);
        credit.setOwner(address(moneta));
        gold.mint(1000 ether);
        gold.transfer(address(goldVault), 1000 ether);

        limes = new Limes(address(codex));
        limes.setParam("aer", address(aer));
        codex.allowCaller(keccak256("ANY_SIG"), address(limes));
        aer.allowCaller(keccak256("ANY_SIG"), address(limes));

        codex.init(vault);

        codex.modifyBalance(vault, tokenId, me, 1000 ether);

        collybus.updateSpot(address(gold), goldPrice); // Collybus = $2.5

        collybus.setParam(vault, "liquidationRatio", 2 ether); // 200% liquidation ratio for easier test calcs

        codex.setParam(vault, "debtFloor", 20 ether); // $20 debtFloor
        codex.setParam(vault, "debtCeiling", 10000 ether);
        codex.setParam("globalDebtCeiling", 10000 ether);

        limes.setParam(vault, "liquidationPenalty", 1.1 ether); // 10% liquidationPenalty
        limes.setParam(vault, "maxDebtOnAuction", 1000 ether);
        limes.setParam("globalMaxDebtOnAuction", 1000 ether);

        // debtFloor and liquidationPenalty set previously so collateralAuction.auctionDebtFloor will be set correctly
        collateralAuction = new CollateralAuction(address(codex), address(limes));
        collateralAuction.init(vault, address(collybus));
        collateralAuction.updateAuctionDebtFloor(vault);
        collateralAuction.allowCaller(keccak256("ANY_SIG"), address(limes));

        limes.setParam(vault, "collateralAuction", address(collateralAuction));
        limes.allowCaller(keccak256("ANY_SIG"), address(collateralAuction));
        codex.allowCaller(keccak256("ANY_SIG"), address(collateralAuction));

        assertEq(codex.balances(vault, tokenId, me), 1000 ether);
        assertEq(codex.credit(me), 0);
        codex.modifyCollateralAndDebt(vault, tokenId, me, me, me, 40 ether, 100 ether);
        assertEq(codex.balances(vault, tokenId, me), 960 ether);
        assertEq(codex.credit(me), 100 ether);

        collybus.updateSpot(address(gold), 4 ether); // Collybus = $2, now unsafe

        ali = address(new Guy(collateralAuction));
        bob = address(new Guy(collateralAuction));
        che = address(new Trader(collateralAuction, codex, gold, goldVault, credit, moneta, exchange));

        codex.grantDelegate(address(collateralAuction));
        Guy(ali).grantDelegate(address(collateralAuction));
        Guy(bob).grantDelegate(address(collateralAuction));

        codex.createUnbackedDebt(address(0), address(this), 1000 ether);
        codex.createUnbackedDebt(address(0), address(ali), 1000 ether);
        codex.createUnbackedDebt(address(0), address(bob), 1000 ether);
    }

    function test_change_limes() public {
        assertTrue(address(collateralAuction.limes()) != address(123));
        collateralAuction.setParam("limes", address(123));
        assertEq(address(collateralAuction.limes()), address(123));
    }

    function test_get_liquidationPenalty() public {
        uint256 liquidationPenalty = limes.liquidationPenalty(vault);
        (, uint256 liquidationPenalty2, , ) = limes.vaults(vault);
        assertEq(liquidationPenalty, liquidationPenalty2);
    }

    function test_startAuction() public {
        uint256 index;
        uint256 debt;
        uint256 collateralToSell;
        address user;
        uint96 startsAt;
        uint256 startPrice;
        uint256 collateral;
        uint256 normalDebt;

        collateralAuction.setParam("flatTip", 100 ether); // Flat fee of 100 Credit
        collateralAuction.setParam("feeTip", 0); // No linear increase

        assertEq(collateralAuction.auctionCounter(), 0);
        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0);
        assertEq(user, address(0));
        assertEq(uint256(startsAt), 0);
        assertEq(startPrice, 0);
        assertEq(codex.balances(vault, tokenId, me), 960 ether);
        assertEq(codex.credit(ali), 1000 ether);
        (collateral, normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 40 ether);
        assertEq(normalDebt, 100 ether);

        Guy(ali).liquidate(limes, vault, tokenId, me, address(ali));

        assertEq(collateralAuction.auctionCounter(), 1);
        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 110 ether);
        assertEq(collateralToSell, 40 ether);
        assertEq(user, me);
        assertEq(uint256(startsAt), block.timestamp);
        assertEq(startPrice, 4 ether);
        assertEq(codex.balances(vault, tokenId, me), 960 ether);
        assertEq(codex.credit(ali), 1100 ether); // Paid "flatTip" amount of Credit for calling liquidate()
        (collateral, normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 0 ether);
        assertEq(normalDebt, 0 ether);

        collybus.updateSpot(address(gold), goldPrice); // Collybus = $2.5, block.timestamp safe

        hevm.warp(startTime + 100);
        codex.modifyCollateralAndDebt(vault, tokenId, me, me, me, 40 ether, 100 ether);

        collybus.updateSpot(address(gold), 4 ether); // Collybus = $2, now unsafe

        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(2);
        assertEq(index, 0);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0);
        assertEq(user, address(0));
        assertEq(uint256(startsAt), 0);
        assertEq(startPrice, 0);
        assertEq(codex.balances(vault, tokenId, me), 920 ether);

        collateralAuction.setParam(vault, bytes32("multiplier"), 1.25 ether); // 25% Initial price buffer

        collateralAuction.setParam("flatTip", 100 ether); // Flat fee of 100 Credit
        collateralAuction.setParam("feeTip", 0.02 ether); // Linear increase of 2% of debt

        assertEq(codex.credit(bob), 1000 ether);

        Guy(bob).liquidate(limes, vault, tokenId, me, address(bob));

        assertEq(collateralAuction.auctionCounter(), 2);
        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(2);
        assertEq(index, 1);
        assertEq(debt, 110 ether);
        assertEq(collateralToSell, 40 ether);
        assertEq(user, me);
        assertEq(uint256(startsAt), block.timestamp);
        assertEq(startPrice, 5 ether);
        assertEq(codex.balances(vault, tokenId, me), 920 ether);
        (collateral, normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 0 ether);
        assertEq(normalDebt, 0 ether);

        assertEq(codex.credit(bob), 1000 ether + 100 ether + (debt * 0.02 ether) / WAD); // Paid (flatTip + due * feeTip) amount of Credit for calling liquidate()
    }

    function testFail_startAuction_zero_price() public {
        collybus.updateSpot(address(gold), 0);
        limes.liquidate(vault, tokenId, me, address(this));
    }

    function testFail_redoAuction_zero_price() public {
        auctionResetSetup(1 hours);

        collybus.updateSpot(address(gold), 0);

        hevm.warp(startTime + 1801 seconds);
        (bool needsRedo, , , ) = collateralAuction.getStatus(1);
        assertTrue(needsRedo);
        collateralAuction.redoAuction(1, address(this));
    }

    function try_startAuction(
        uint256 debt,
        uint256 collateralToSell,
        address vault_,
        uint256 tokenId_,
        address user,
        address keeper
    ) internal returns (bool ok) {
        string memory sig = "startAuction(uint256,uint256,address,uint256,address,address)";
        (ok, ) = address(collateralAuction).call(
            abi.encodeWithSignature(sig, debt, collateralToSell, vault_, tokenId_, user, keeper)
        );
    }

    function test_startAuction_basic() public {
        assertTrue(try_startAuction(1 ether, 2 ether, vault, tokenId, address(1), address(this)));
    }

    function test_startAuction_zero_debt() public {
        assertTrue(!try_startAuction(0, 2 ether, vault, tokenId, address(1), address(this)));
    }

    function test_startAuction_zero_collateralToSell() public {
        assertTrue(!try_startAuction(1 ether, 0, vault, tokenId, address(1), address(this)));
    }

    function test_startAuction_zero_user() public {
        assertTrue(!try_startAuction(1 ether, 2 ether, vault, tokenId, address(0), address(this)));
    }

    function try_liquidate(
        address vault_,
        uint256 tokenId_,
        address user_
    ) internal returns (bool ok) {
        string memory sig = "liquidate(address,uint256,address,address)";
        (ok, ) = address(limes).call(abi.encodeWithSignature(sig, vault_, tokenId_, user_, address(this)));
    }

    function test_liquidate_not_leaving_dust() public {
        uint256 index;
        uint256 debt;
        uint256 collateralToSell;
        address user;
        uint96 startsAt;
        uint256 startPrice;
        uint256 collateral;
        uint256 normalDebt;

        limes.setParam(vault, "maxDebtOnAuction", 80 ether); // Makes room = 80 WAD
        limes.setParam(vault, "liquidationPenalty", 1 ether); // 0% liquidationPenalty (for precise calculations)

        assertEq(collateralAuction.auctionCounter(), 0);
        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0);
        assertEq(user, address(0));
        assertEq(uint256(startsAt), 0);
        assertEq(startPrice, 0);
        assertEq(codex.balances(vault, tokenId, me), 960 ether);
        (collateral, normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 40 ether);
        assertEq(normalDebt, 100 ether);

        assertTrue(try_liquidate(vault, tokenId, me)); // normalDebt - deltaNormalDebt = 100 - 80 = debtFloor (= 20)

        assertEq(collateralAuction.auctionCounter(), 1);
        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 80 ether); // No liquidationPenalty
        assertEq(collateralToSell, 32 ether); // 80% of collateral, since only 80% of debt can be liquidated
        assertEq(user, me);
        assertEq(uint256(startsAt), block.timestamp);
        assertEq(startPrice, 4 ether);
        assertEq(codex.balances(vault, tokenId, me), 960 ether);
        (collateral, normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 8 ether);
        assertEq(normalDebt, 20 ether);
    }

    function test_liquidate_not_leaving_dust_over_maxDebtOnAuction() public {
        uint256 index;
        uint256 debt;
        uint256 collateralToSell;
        address user;
        uint96 startsAt;
        uint256 startPrice;
        uint256 collateral;
        uint256 normalDebt;

        limes.setParam(vault, "maxDebtOnAuction", 80 ether + 1 ether); // Makes room = 80 WAD + 1 wei
        limes.setParam(vault, "liquidationPenalty", 1 ether); // 0% liquidationPenalty (for precise calculations)

        assertEq(collateralAuction.auctionCounter(), 0);
        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0);
        assertEq(user, address(0));
        assertEq(uint256(startsAt), 0);
        assertEq(startPrice, 0);
        assertEq(codex.balances(vault, tokenId, me), 960 ether);
        (collateral, normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 40 ether);
        assertEq(normalDebt, 100 ether);

        assertTrue(try_liquidate(vault, tokenId, me)); // normalDebt - deltaNormalDebt = 100 - (80 + 1 wei) < debtFloor (= 20) then the whole debt is taken

        assertEq(collateralAuction.auctionCounter(), 1);
        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 100 ether); // No liquidationPenalty
        assertEq(collateralToSell, 40 ether); // 100% of collateral is liquidated to avoid dust
        assertEq(user, me);
        assertEq(uint256(startsAt), block.timestamp);
        assertEq(startPrice, 4 ether);
        assertEq(codex.balances(vault, tokenId, me), 960 ether);
        (collateral, normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 0 ether);
        assertEq(normalDebt, 0 ether);
    }

    function test_liquidate_not_leaving_dust_rate() public {
        uint256 index;
        uint256 debt;
        uint256 collateralToSell;
        address user;
        uint96 startsAt;
        uint256 startPrice;
        uint256 collateral;
        uint256 normalDebt;

        codex.modifyRate(vault, address(aer), int256(0.02 ether));
        (, uint256 rate, , ) = codex.vaults(vault);
        assertEq(rate, 1.02 ether);

        limes.setParam(vault, "maxDebtOnAuction", 100 * WAD); // Makes room = 100 WAD
        limes.setParam(vault, "liquidationPenalty", 1 ether); // 0% liquidationPenalty for precise calculations
        codex.setParam(vault, "debtFloor", 20 * WAD); // 20 Credit minimum Vault debt
        collateralAuction.updateAuctionDebtFloor(vault);

        assertEq(collateralAuction.auctionCounter(), 0);
        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0);
        assertEq(user, address(0));
        assertEq(uint256(startsAt), 0);
        assertEq(startPrice, 0);
        assertEq(codex.balances(vault, tokenId, me), 960 ether);
        (collateral, normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 40 ether);
        assertEq(normalDebt, 100 ether); // Full debt is 102 Credit since rate = 1.02 * WAD

        // (normalDebt - deltaNormalDebt) * rate ~= 2 WAD < debtFloor = 20 WAD
        //   => remnant would be dusty, so a full liquidation occurs.
        assertTrue(try_liquidate(vault, tokenId, me));

        assertEq(collateralAuction.auctionCounter(), 1);
        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, mul(100 ether, rate) / WAD); // No liquidationPenalty
        assertEq(collateralToSell, 40 ether);
        assertEq(user, me);
        assertEq(uint256(startsAt), block.timestamp);
        assertEq(startPrice, 4 ether);
        assertEq(codex.balances(vault, tokenId, me), 960 ether);
        (collateral, normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);
    }

    function test_liquidate_only_leaving_dust_over_maxDebtOnAuction_rate() public {
        uint256 index;
        uint256 debt;
        uint256 collateralToSell;
        address user;
        uint96 startsAt;
        uint256 startPrice;
        uint256 collateral;
        uint256 normalDebt;

        codex.modifyRate(vault, address(aer), int256(0.02 ether));
        (, uint256 rate, , ) = codex.vaults(vault);
        assertEq(rate, 1.02 ether);

        limes.setParam(vault, "maxDebtOnAuction", (816 * WAD) / 10); // Makes room = 81.6 WAD => deltaNormalDebt = 80
        limes.setParam(vault, "liquidationPenalty", 1 ether); // 0% liquidationPenalty for precise calculations
        codex.setParam(vault, "debtFloor", (204 * WAD) / 10); // 20.4 Credit debtFloor
        collateralAuction.updateAuctionDebtFloor(vault);

        assertEq(collateralAuction.auctionCounter(), 0);
        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0);
        assertEq(user, address(0));
        assertEq(uint256(startsAt), 0);
        assertEq(startPrice, 0);
        assertEq(codex.balances(vault, tokenId, me), 960 ether);
        (collateral, normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 40 ether);
        assertEq(normalDebt, 100 ether);

        // (normalDebt - deltaNormalDebt) * rate = 20.4 WAD == debtFloor
        //   => marginal threshold at which partial liquidation is acceptable
        assertTrue(try_liquidate(vault, tokenId, me));

        assertEq(collateralAuction.auctionCounter(), 1);
        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, (816 * WAD) / 10); // Equal to vault.maxDebtOnAuction
        assertEq(collateralToSell, 32 ether);
        assertEq(user, me);
        assertEq(uint256(startsAt), block.timestamp);
        assertEq(startPrice, 4 ether);
        assertEq(codex.balances(vault, tokenId, me), 960 ether);
        (collateral, normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 8 ether);
        assertEq(normalDebt, 20 ether);
        (, , , uint256 debtFloor) = codex.vaults(vault);
        assertEq((normalDebt * rate) / WAD, debtFloor);
    }

    function test_globalMaxDebtOnAuction_maxDebtOnAuction() public {
        assertEq(limes.globalDebtOnAuction(), 0);
        (, , , uint256 debtOnAuction) = limes.vaults(vault);
        assertEq(debtOnAuction, 0);

        limes.liquidate(vault, tokenId, me, address(this));

        (, uint256 debt, , , , , , ) = collateralAuction.auctions(1);

        assertEq(limes.globalDebtOnAuction(), debt);
        (, , , debtOnAuction) = limes.vaults(vault);
        assertEq(debtOnAuction, debt);

        address vault2 = address(new Vault20(address(codex), address(new DSToken("GOLD")), address(collybus)));
        CollateralAuction collateralAuction2 = new CollateralAuction(address(codex), address(limes));
        collateralAuction2.init(vault2, address(collybus));
        collateralAuction2.updateAuctionDebtFloor(vault2);
        collateralAuction2.allowCaller(keccak256("ANY_SIG"), address(limes));

        limes.setParam(vault2, "collateralAuction", address(collateralAuction2));
        limes.setParam(vault2, "liquidationPenalty", 1.1 ether);
        limes.setParam(vault2, "maxDebtOnAuction", 1000 ether);
        limes.allowCaller(keccak256("ANY_SIG"), address(collateralAuction2));

        codex.init(vault2);
        codex.allowCaller(keccak256("ANY_SIG"), address(collateralAuction2));
        codex.setParam(vault2, "debtCeiling", 100 ether);

        codex.modifyBalance(vault2, tokenId, me, 40 ether);

        collybus.updateSpot(address(IVault(vault2).token()), goldPrice); // fairPrice = $2.5

        collybus.setParam(vault2, "liquidationRatio", 2 ether);
        codex.modifyCollateralAndDebt(vault2, tokenId, me, me, me, 40 ether, 100 ether);
        collybus.updateSpot(address(IVault(vault2).token()), 4 ether); // fairPrice = $2

        limes.liquidate(vault2, tokenId, me, address(this));

        (, uint256 debt2, , , , , , ) = collateralAuction2.auctions(1);

        assertEq(limes.globalDebtOnAuction(), debt + debt2);
        (, , , debtOnAuction) = limes.vaults(vault);
        (, , , uint256 debtOnAuction2) = limes.vaults(vault2);
        assertEq(debtOnAuction, debt);
        assertEq(debtOnAuction2, debt2);
    }

    function test_partial_liquidation_globalMaxDebtOnAuction_limit() public {
        limes.setParam("globalMaxDebtOnAuction", 75 ether);

        assertEq(_collateral(vault, tokenId, me), 40 ether);
        assertEq(_normalDebt(vault, tokenId, me), 100 ether);

        assertEq(limes.globalDebtOnAuction(), 0);
        (, uint256 liquidationPenalty, , uint256 debtOnAuction) = limes.vaults(vault);
        assertEq(debtOnAuction, 0);

        limes.liquidate(vault, tokenId, me, address(this));

        (, uint256 debt, uint256 collateralToSell, , , , , ) = collateralAuction.auctions(1);

        (, uint256 rate, , ) = codex.vaults(vault);

        assertEq(collateralToSell - 1, (40 ether * ((((debt * WAD) / rate) * WAD) / liquidationPenalty)) / 100 ether);
        assertEq(debt + 1, 75 ether); // - 0.2 ether,  0.2 WAD rounding error

        assertEq(_collateral(vault, tokenId, me), 40 ether - collateralToSell);
        assertEq(_normalDebt(vault, tokenId, me) + 1, 100 ether - (((debt * WAD) / rate) * WAD) / liquidationPenalty);

        assertEq(limes.globalDebtOnAuction(), debt);
        (, , , debtOnAuction) = limes.vaults(vault);
        assertEq(debtOnAuction, debt);
    }

    function test_partial_liquidation_maxDebtOnAuction_limit() public {
        limes.setParam(vault, "maxDebtOnAuction", 75 ether);

        assertEq(_collateral(vault, tokenId, me), 40 ether);
        assertEq(_normalDebt(vault, tokenId, me), 100 ether);

        assertEq(limes.globalDebtOnAuction(), 0);
        (, uint256 liquidationPenalty, , uint256 debtOnAuction) = limes.vaults(vault);
        assertEq(debtOnAuction, 0);

        limes.liquidate(vault, tokenId, me, address(this));

        (, uint256 debt, uint256 collateralToSell, , , , , ) = collateralAuction.auctions(1);

        (, uint256 rate, , ) = codex.vaults(vault);

        assertEq(collateralToSell - 1, (40 ether * ((((debt * WAD) / rate) * WAD) / liquidationPenalty)) / 100 ether);
        assertEq(debt + 1, 75 ether); // - 0.2 ether, 0.2 WAD rounding error

        assertEq(_collateral(vault, tokenId, me), 40 ether - collateralToSell);
        assertEq(_normalDebt(vault, tokenId, me) + 1, 100 ether - (((debt * WAD) / rate) * WAD) / liquidationPenalty);

        assertEq(limes.globalDebtOnAuction(), debt);
        (, , , debtOnAuction) = limes.vaults(vault);
        assertEq(debtOnAuction, debt);
    }

    function try_takeCollateral(
        uint256 auctionId,
        uint256 collateralAmount,
        uint256 maxPrice,
        address recipient,
        bytes memory data
    ) internal returns (bool ok) {
        string memory sig = "takeCollateral(uint256,uint256,uint256,address,bytes)";
        (ok, ) = address(collateralAuction).call(
            abi.encodeWithSignature(sig, auctionId, collateralAmount, maxPrice, recipient, data)
        );
    }

    function test_takeCollateral_zero_user() public takeCollateralSetup {
        // Auction auctionId 2 is unpopulated.
        (, , , , , address user, , ) = collateralAuction.auctions(2);
        assertEq(user, address(0));
        assertTrue(!try_takeCollateral(2, 25 ether, 5 ether, address(ali), ""));
    }

    function test_takeCollateral_over_debt() public takeCollateralSetup {
        // Bid so owe (= 25 * 5 = 125 WAD) > debt (= 110 WAD)
        // Readjusts collateralSlice to be debt/startPrice = 25
        Guy(ali).takeCollateral({
            auctionId: 1,
            collateralAmount: 25 ether,
            maxPrice: 5 ether,
            recipient: address(ali),
            data: ""
        });

        assertEq(codex.balances(vault, tokenId, ali), 22 ether); // Didn't take whole collateralToSell
        assertEq(codex.credit(ali), 890 ether); // Didn't pay more than debt (110)
        assertEq(codex.balances(vault, tokenId, me), 978 ether); // 960 + (40 - 22) returned to user

        // Assert auction ends
        (
            uint256 index,
            uint256 debt,
            uint256 collateralToSell,
            ,
            ,
            address user,
            uint256 startsAt,
            uint256 startPrice
        ) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0);
        assertEq(user, address(0));
        assertEq(uint256(startsAt), 0);
        assertEq(startPrice, 0);

        assertEq(limes.globalDebtOnAuction(), 0);
        (, , , uint256 debtOnAuction) = limes.vaults(vault);
        assertEq(debtOnAuction, 0);
    }

    function test_takeCollateral_at_debt() public takeCollateralSetup {
        // Bid so owe (= 22 * 5 = 110 WAD) == debt (= 110 WAD)
        Guy(ali).takeCollateral({
            auctionId: 1,
            collateralAmount: 22 ether,
            maxPrice: 5 ether,
            recipient: address(ali),
            data: ""
        });

        assertEq(codex.balances(vault, tokenId, ali), 22 ether); // Didn't take whole collateralToSell
        assertEq(codex.credit(ali), 890 ether); // Paid full debt (110)
        assertEq(codex.balances(vault, tokenId, me), 978 ether); // 960 + (40 - 22) returned to user

        // Assert auction ends
        (
            uint256 index,
            uint256 debt,
            uint256 collateralToSell,
            ,
            ,
            address user,
            uint256 startsAt,
            uint256 startPrice
        ) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0);
        assertEq(user, address(0));
        assertEq(uint256(startsAt), 0);
        assertEq(startPrice, 0);

        assertEq(limes.globalDebtOnAuction(), 0);
        (, , , uint256 debtOnAuction) = limes.vaults(vault);
        assertEq(debtOnAuction, 0);
    }

    function test_takeCollateral_under_debt() public takeCollateralSetup {
        // Bid so owe (= 11 * 5 = 55 WAD) < debt (= 110 WAD)
        Guy(ali).takeCollateral({
            auctionId: 1,
            collateralAmount: 11 ether, // Half of debt at $110
            maxPrice: 5 ether,
            recipient: address(ali),
            data: ""
        });

        assertEq(codex.balances(vault, tokenId, ali), 11 ether); // Didn't take whole collateralToSell
        assertEq(codex.credit(ali), 945 ether); // Paid half debt (55)
        assertEq(codex.balances(vault, tokenId, me), 960 ether); // Collateral not returned (yet)

        // Assert auction DOES NOT end
        (
            uint256 index,
            uint256 debt,
            uint256 collateralToSell,
            ,
            ,
            address user,
            uint256 startsAt,
            uint256 startPrice
        ) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 55 ether); // 110 - 5 * 11
        assertEq(collateralToSell, 29 ether); // 40 - 11
        assertEq(user, me);
        assertEq(uint256(startsAt), block.timestamp);
        assertEq(startPrice, 5 ether);

        assertEq(limes.globalDebtOnAuction(), debt);
        (, , , uint256 debtOnAuction) = limes.vaults(vault);
        assertEq(debtOnAuction, debt);
    }

    function test_takeCollateral_full_collateralToSell_partial_debt() public takeCollateralSetup {
        hevm.warp(block.timestamp + 69); // approx 50% price decline
        // Bid to purchase entire collateralToSell less than debt (~2.5 * 40 ~= 100 < 110)
        Guy(ali).takeCollateral({
            auctionId: 1,
            collateralAmount: 40 ether, // purchase all collateral
            maxPrice: 2.5 ether,
            recipient: address(ali),
            data: ""
        });

        assertEq(codex.balances(vault, tokenId, ali), 40 ether); // Took entire collateralToSell
        assertTrue(sub(codex.credit(ali), uint256(900 ether)) < 0.1 ether); // Paid about 100 ether
        assertEq(codex.balances(vault, tokenId, me), 960 ether); // Collateral not returned

        // Assert auction ends
        (
            uint256 index,
            uint256 debt,
            uint256 collateralToSell,
            ,
            ,
            address user,
            uint256 startsAt,
            uint256 startPrice
        ) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0);
        assertEq(user, address(0));
        assertEq(uint256(startsAt), 0);
        assertEq(startPrice, 0);

        // All debtOnAuction should be cleared, since the auction has ended, even though < 100% of debt was collected
        assertEq(limes.globalDebtOnAuction(), 0);
        (, , , uint256 debtOnAuction) = limes.vaults(vault);
        assertEq(debtOnAuction, 0);
    }

    function testFail_takeCollateral_bid_too_low() public takeCollateralSetup {
        // Bid so maxPrice (= 4) < price (= startPrice = 5) (fails with "CollateralAuction/too-expensive")
        Guy(ali).takeCollateral({
            auctionId: 1,
            collateralAmount: 22 ether,
            maxPrice: 4 ether,
            recipient: address(ali),
            data: ""
        });
    }

    function test_takeCollateral_bid_recalculates_due_to_chost_check() public takeCollateralSetup {
        (, uint256 debt, uint256 collateralToSell, , , , , ) = collateralAuction.auctions(1);
        assertEq(debt, 110 ether);
        assertEq(collateralToSell, 40 ether);

        (, uint256 price, uint256 _collateralToSell, uint256 _debt) = collateralAuction.getStatus(1);
        assertEq(_collateralToSell, collateralToSell);
        assertEq(_debt, debt);
        assertEq(price, 5 ether);

        // Bid for an amount that would leave less than auctionDebtFloor remaining debt--bid will be decreased
        // to leave debt == auctionDebtFloor post-exefactorion.
        Guy(ali).takeCollateral({
            auctionId: 1,
            collateralAmount: 18 * WAD, // Costs 90 Credit at current price; 110 - 90 == 20 < 22 == auctionDebtFloor
            maxPrice: 5 ether,
            recipient: address(ali),
            data: ""
        });

        (, debt, collateralToSell, , , , , ) = collateralAuction.auctions(1);
        (, , , uint256 auctionDebtFloor, , ) = collateralAuction.vaults(vault);
        assertEq(debt, auctionDebtFloor);
        assertEq(collateralToSell, 40 ether - (((110 * WAD - auctionDebtFloor)) * WAD) / price);
    }

    function test_takeCollateral_bid_avoids_recalculate_due_no_more_collateralToSell() public takeCollateralSetup {
        hevm.warp(block.timestamp + 60); // Reducing the price

        (, uint256 debt, uint256 collateralToSell, , , , , ) = collateralAuction.auctions(1);
        assertEq(debt, 110 ether);
        assertEq(collateralToSell, 40 ether);

        (, uint256 price, , ) = collateralAuction.getStatus(1);
        assertEq(price, 2735783211953807385); // 2.73 WAD, 2735783211953807380973706855

        // Bid so owe (= (22 - 1wei) * 5 = 110 WAD - 1) < debt (= 110 WAD)
        // 1 < 20 WAD => owe = 110 WAD - 20 WAD
        Guy(ali).takeCollateral({
            auctionId: 1,
            collateralAmount: 40 ether,
            maxPrice: 2.8 ether,
            recipient: address(ali),
            data: ""
        });

        // 40 * 2.73 = 109.42...
        // It means a very low amount of debt (< debtFloor) would remain but doesn't matter
        // as the auction is finished because there isn't more collateralToSell
        (, debt, collateralToSell, , , , , ) = collateralAuction.auctions(1);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0);
    }

    function test_takeCollateral_bid_fails_no_partial_allowed() public takeCollateralSetup {
        (, uint256 price, , ) = collateralAuction.getStatus(1);
        assertEq(price, 5 ether);

        collateralAuction.takeCollateral({
            auctionId: 1,
            collateralAmount: 17.6 ether,
            maxPrice: 5 ether,
            recipient: address(this),
            data: ""
        });

        (, uint256 debt, uint256 collateralToSell, address _vault, , , , ) = collateralAuction.auctions(1);
        (, , , uint256 auctionDebtFloor, , ) = collateralAuction.vaults(_vault);
        assertEq(debt, 22 ether);
        assertEq(collateralToSell, 22.4 ether);
        assertTrue(!(debt > auctionDebtFloor));

        assertTrue(
            !try_takeCollateral({
                auctionId: 1,
                collateralAmount: 1 ether, // partial purchase attempt when !(debt > auctionDebtFloor)
                maxPrice: 5 ether,
                recipient: address(this),
                data: ""
            })
        );

        collateralAuction.takeCollateral({
            auctionId: 1,
            collateralAmount: (debt * WAD) / price, // This time take the whole debt
            maxPrice: 5 ether,
            recipient: address(this),
            data: ""
        });
    }

    function test_takeCollateral_multiple_bids_different_prices() public takeCollateralSetup {
        uint256 index;
        uint256 debt;
        uint256 collateralToSell;
        address user;
        uint96 startsAt;
        uint256 startPrice;

        // Bid so owe (= 10 * 5 = 50 WAD) < debt (= 110 WAD)
        Guy(ali).takeCollateral({
            auctionId: 1,
            collateralAmount: 10 ether,
            maxPrice: 5 ether,
            recipient: address(ali),
            data: ""
        });

        assertEq(codex.balances(vault, tokenId, ali), 10 ether); // Didn't take whole collateralToSell
        assertEq(codex.credit(ali), 950 ether); // Paid some debt (50)
        assertEq(codex.balances(vault, tokenId, me), 960 ether); // Collateral not returned (yet)

        // Assert auction DOES NOT end
        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 60 ether); // 110 - 5 * 10
        assertEq(collateralToSell, 30 ether); // 40 - 10
        assertEq(user, me);
        assertEq(uint256(startsAt), block.timestamp);
        assertEq(startPrice, 5 ether);

        hevm.warp(block.timestamp + 30);

        (, uint256 _price, uint256 _collateralToSell, ) = collateralAuction.getStatus(1);
        Guy(bob).takeCollateral({
            auctionId: 1,
            collateralAmount: _collateralToSell, // Buy the rest of the collateralToSell
            maxPrice: _price, // 5 * 0.99 ** 30 = 3.698501866941401 WAD => maxPrice > price
            recipient: address(bob),
            data: ""
        });

        // Assert auction is over
        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0 * WAD);
        assertEq(user, address(0));
        assertEq(uint256(startsAt), 0);
        assertEq(startPrice, 0);

        uint256 expectedToken = (WAD * 60 ether) / _price; // debt / price
        assertEq(codex.balances(vault, tokenId, bob), expectedToken); // Didn't take whole collateralToSell
        assertEq(codex.credit(bob), 940 ether); // Paid rest of debt (60)

        uint256 collateralReturn = 30 ether - expectedToken; // collateralToSell - loaf.debt / maxPrice = 15
        assertEq(codex.balances(vault, tokenId, me), 960 ether + collateralReturn); // Collateral returned (10 WAD)
    }

    function auctionResetSetup(uint256 duration) internal {
        LinearDecrease calculator = new LinearDecrease();
        calculator.setParam(bytes32("duration"), duration); // duration hours till zero is reached (used to test maxAuctionDuration)

        codex.setParam(vault, "debtFloor", 20 ether); // $20 debtFloor

        collateralAuction.setParam(vault, "multiplier", 1.25 ether); // 25% Initial price buffer
        collateralAuction.setParam(vault, "calculator", address(calculator)); // SetParam price contract
        collateralAuction.setParam(vault, "maxDiscount", 0.5 ether); // 50% drop before reset
        collateralAuction.setParam(vault, "maxAuctionDuration", 3600); // 1 hour before reset

        assertEq(collateralAuction.auctionCounter(), 0);
        limes.liquidate(vault, tokenId, me, address(this));
        assertEq(collateralAuction.auctionCounter(), 1);
    }

    function try_redoAuction(uint256 auctionId, address keeper) internal returns (bool ok) {
        string memory sig = "redoAuction(uint256,address)";
        (ok, ) = address(collateralAuction).call(abi.encodeWithSignature(sig, auctionId, keeper));
    }

    function test_auction_reset_tail() public {
        auctionResetSetup(10 hours); // 10 hours till zero is reached (used to test maxAuctionDuration)

        collybus.updateSpot(address(gold), 3 ether); // Collybus = $1.50 (update price before reset is called)

        (, , , , , , uint96 startAtBefore, uint256 startPriceBefore) = collateralAuction.auctions(1);
        assertEq(uint256(startAtBefore), startTime);
        assertEq(startPriceBefore, 5 ether); // $4 collybus + 25% buffer = $5 (wasn't affected by spot update)

        hevm.warp(startTime + 3600 seconds);
        (bool needsRedo, , , ) = collateralAuction.getStatus(1);
        assertTrue(!needsRedo);
        assertTrue(!try_redoAuction(1, address(this)));
        hevm.warp(startTime + 3601 seconds);
        (needsRedo, , , ) = collateralAuction.getStatus(1);
        assertTrue(needsRedo);
        assertTrue(try_redoAuction(1, address(this)));

        (, , , , , , uint96 startAtAfter, uint256 startPriceAfter) = collateralAuction.auctions(1);
        assertEq(uint256(startAtAfter), startTime + 3601 seconds); // (block.timestamp)
        assertEq(startPriceAfter, 3.75 ether); // $3 collybus + 25% buffer = $5 (used most recent OSM price)
    }

    function test_auction_reset_maxDiscount() public {
        auctionResetSetup(1 hours); // 1 hour till zero is reached (used to test maxDiscount)

        collybus.updateSpot(address(gold), 3 ether); // Collybus = $1.50 (update price before reset is called)

        (, , , , , , uint96 startAtBefore, uint256 startPriceBefore) = collateralAuction.auctions(1);
        assertEq(uint256(startAtBefore), startTime);
        assertEq(startPriceBefore, 5 ether); // $4 collybus + 25% buffer = $5 (wasn't affected by spot update)

        hevm.warp(startTime + 1800 seconds);
        (bool needsRedo, , , ) = collateralAuction.getStatus(1);
        assertTrue(!needsRedo);
        assertTrue(!try_redoAuction(1, address(this)));
        hevm.warp(startTime + 1801 seconds);
        (needsRedo, , , ) = collateralAuction.getStatus(1);
        assertTrue(needsRedo);
        assertTrue(try_redoAuction(1, address(this)));

        (, , , , , , uint96 startAtAfter, uint256 startPriceAfter) = collateralAuction.auctions(1);
        assertEq(uint256(startAtAfter), startTime + 1801 seconds); // (block.timestamp)
        assertEq(startPriceAfter, 3.75 ether); // $3 collybus + 25% buffer = $3.75 (used most recent OSM price)
    }

    function test_auction_reset_tail_twice() public {
        auctionResetSetup(10 hours); // 10 hours till zero is reached (used to test maxAuctionDuration)

        hevm.warp(startTime + 3601 seconds);
        collateralAuction.redoAuction(1, address(this));

        assertTrue(!try_redoAuction(1, address(this)));
    }

    function test_auction_reset_maxDiscount_twice() public {
        auctionResetSetup(1 hours); // 1 hour till zero is reached (used to test maxDiscount)

        hevm.warp(startTime + 1801 seconds); // Price goes below 50% "maxDiscount" after 30min01sec
        collateralAuction.redoAuction(1, address(this));

        assertTrue(!try_redoAuction(1, address(this)));
    }

    function test_redoAuction_zero_user() public {
        // Can't reset a non-existent auction.
        assertTrue(!try_redoAuction(1, address(this)));
    }

    function test_setBreaker() public {
        collateralAuction.setParam("stopped", 1);
        assertEq(collateralAuction.stopped(), 1);
        collateralAuction.setParam("stopped", 2);
        assertEq(collateralAuction.stopped(), 2);
        collateralAuction.setParam("stopped", 3);
        assertEq(collateralAuction.stopped(), 3);
        collateralAuction.setParam("stopped", 0);
        assertEq(collateralAuction.stopped(), 0);
    }

    function test_stopped_startAuction() public {
        uint256 index;
        uint256 debt;
        uint256 collateralToSell;
        address user;
        uint96 startsAt;
        uint256 startPrice;
        uint256 collateral;
        uint256 normalDebt;

        assertEq(collateralAuction.auctionCounter(), 0);
        (index, debt, collateralToSell, , , user, startsAt, startPrice) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0);
        assertEq(user, address(0));
        assertEq(uint256(startsAt), 0);
        assertEq(startPrice, 0);
        assertEq(codex.balances(vault, tokenId, me), 960 ether);
        (collateral, normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 40 ether);
        assertEq(normalDebt, 100 ether);

        // Any level of stoppage prevents startAuctioning.
        collateralAuction.setParam("stopped", 1);
        assertTrue(!try_liquidate(vault, tokenId, me));

        collateralAuction.setParam("stopped", 2);
        assertTrue(!try_liquidate(vault, tokenId, me));

        collateralAuction.setParam("stopped", 3);
        assertTrue(!try_liquidate(vault, tokenId, me));

        collateralAuction.setParam("stopped", 0);
        assertTrue(try_liquidate(vault, tokenId, me));
    }

    // At a stopped == 1 we are ok to takeCollateral
    function test_stopped_1_takeCollateral() public takeCollateralSetup {
        collateralAuction.setParam("stopped", 1);
        // Bid so owe (= 25 * 5 = 125 WAD) > debt (= 110 WAD)
        // Readjusts collateralSlice to be debt/startPrice = 25
        Guy(ali).takeCollateral({
            auctionId: 1,
            collateralAmount: 25 ether,
            maxPrice: 5 ether,
            recipient: address(ali),
            data: ""
        });
    }

    function test_stopped_2_takeCollateral() public takeCollateralSetup {
        collateralAuction.setParam("stopped", 2);
        // Bid so owe (= 25 * 5 = 125 WAD) > debt (= 110 WAD)
        // Readjusts collateralSlice to be debt/startPrice = 25
        Guy(ali).takeCollateral({
            auctionId: 1,
            collateralAmount: 25 ether,
            maxPrice: 5 ether,
            recipient: address(ali),
            data: ""
        });
    }

    function testFail_stopped_3_takeCollateral() public takeCollateralSetup {
        collateralAuction.setParam("stopped", 3);
        // Bid so owe (= 25 * 5 = 125 WAD) > debt (= 110 WAD)
        // Readjusts collateralSlice to be debt/startPrice = 25
        Guy(ali).takeCollateral({
            auctionId: 1,
            collateralAmount: 25 ether,
            maxPrice: 5 ether,
            recipient: address(ali),
            data: ""
        });
    }

    function test_stopped_1_auction_reset_tail() public {
        auctionResetSetup(10 hours); // 10 hours till zero is reached (used to test maxAuctionDuration)

        collateralAuction.setParam("stopped", 1);

        collybus.updateSpot(address(gold), 3 ether); // Collybus = $1.50 (update price before reset is called)

        (, , , , , , uint96 startAtBefore, uint256 startPriceBefore) = collateralAuction.auctions(1);
        assertEq(uint256(startAtBefore), startTime);
        assertEq(startPriceBefore, 5 ether); // $4 collybus + 25% buffer = $5 (wasn't affected by spot update)

        hevm.warp(startTime + 3600 seconds);
        assertTrue(!try_redoAuction(1, address(this)));
        hevm.warp(startTime + 3601 seconds);
        assertTrue(try_redoAuction(1, address(this)));

        (, , , , , , uint96 startAtAfter, uint256 startPriceAfter) = collateralAuction.auctions(1);
        assertEq(uint256(startAtAfter), startTime + 3601 seconds); // (block.timestamp)
        assertEq(startPriceAfter, 3.75 ether); // $3 collybus + 25% buffer = $5 (used most recent OSM price)
    }

    function test_stopped_2_auction_reset_tail() public {
        auctionResetSetup(10 hours); // 10 hours till zero is reached (used to test maxAuctionDuration)

        collateralAuction.setParam("stopped", 2);

        collybus.updateSpot(address(gold), 3 ether); // Collybus = $1.50 (update price before reset is called)

        (, , , , , , uint96 startAtBefore, uint256 startPriceBefore) = collateralAuction.auctions(1);
        assertEq(uint256(startAtBefore), startTime);
        assertEq(startPriceBefore, 5 ether); // $4 collybus + 25% buffer = $5 (wasn't affected by spot update)

        hevm.warp(startTime + 3601 seconds);
        (bool needsRedo, , , ) = collateralAuction.getStatus(1);
        assertTrue(needsRedo); // RedoAuction possible if circuit breaker not set
        assertTrue(!try_redoAuction(1, address(this))); // RedoAuction fails because of circuit breaker
    }

    function test_stopped_3_auction_reset_tail() public {
        auctionResetSetup(10 hours); // 10 hours till zero is reached (used to test maxAuctionDuration)

        collateralAuction.setParam("stopped", 3);

        collybus.updateSpot(address(gold), 3 ether); // Collybus = $1.50 (update price before reset is called)

        (, , , , , , uint96 startAtBefore, uint256 startPriceBefore) = collateralAuction.auctions(1);
        assertEq(uint256(startAtBefore), startTime);
        assertEq(startPriceBefore, 5 ether); // $4 collybus + 25% buffer = $5 (wasn't affected by spot update)

        hevm.warp(startTime + 3601 seconds);
        (bool needsRedo, , , ) = collateralAuction.getStatus(1);
        assertTrue(needsRedo); // RedoAuction possible if circuit breaker not set
        assertTrue(!try_redoAuction(1, address(this))); // RedoAuction fails because of circuit breaker
    }

    function test_redoAuction_incentive() public takeCollateralSetup {
        collateralAuction.setParam("flatTip", 100 ether); // Flat fee of 100 Credit
        collateralAuction.setParam("feeTip", 0); // No linear increase

        (, uint256 debt, uint256 collateralToSell, address _vault, , , , ) = collateralAuction.auctions(1);
        (, , , uint256 auctionDebtFloor, , ) = collateralAuction.vaults(_vault);

        assertEq(debt, 110 ether);
        assertEq(collateralToSell, 40 ether);

        hevm.warp(block.timestamp + 300);
        collateralAuction.redoAuction(1, address(123));
        assertEq(codex.credit(address(123)), collateralAuction.flatTip());

        collateralAuction.setParam("feeTip", 0.02 ether); // Reward 2% of debt
        hevm.warp(block.timestamp + 300);
        collateralAuction.redoAuction(1, address(234));
        assertEq(codex.credit(address(234)), collateralAuction.flatTip() + (collateralAuction.feeTip() * debt) / WAD);

        collateralAuction.setParam("flatTip", 0); // No more flat fee
        hevm.warp(block.timestamp + 300);
        collateralAuction.redoAuction(1, address(345));
        assertEq(codex.credit(address(345)), (collateralAuction.feeTip() * debt) / WAD);

        codex.setParam(vault, "debtFloor", 100 ether + 1); // ensure wmul(debtFloor, liquidationPenalty) > 110 Credit (debt)
        collateralAuction.updateAuctionDebtFloor(vault);
        (, , , auctionDebtFloor, , ) = collateralAuction.vaults(_vault);
        assertEq(auctionDebtFloor, 110 * WAD + 1);

        hevm.warp(block.timestamp + 300);
        collateralAuction.redoAuction(1, address(456));
        assertEq(codex.credit(address(456)), 0);

        // Set debtFloor so that wmul(debtFloor, liquidationPenalty) is well below debt to check the dusty collateralToSell case.
        codex.setParam(vault, "debtFloor", 20 ether); // $20 debtFloor
        collateralAuction.updateAuctionDebtFloor(vault);
        (, , , auctionDebtFloor, , ) = collateralAuction.vaults(_vault);
        assertEq(auctionDebtFloor, 22 * WAD);

        hevm.warp(block.timestamp + 100); // Reducing the price

        (, uint256 price, , ) = collateralAuction.getStatus(1);
        assertEq(price, 1830161706366147530); // 1830161706366147524653080130, 1.83 WAD

        collateralAuction.takeCollateral({
            auctionId: 1,
            collateralAmount: 38 ether,
            maxPrice: 5 ether,
            recipient: address(this),
            data: ""
        });

        (, debt, collateralToSell, , , , , ) = collateralAuction.auctions(1);

        assertEq(debt, 110 ether - (38 ether * price) / WAD); // > 22 Credit auctionDebtFloor
        // When auction is reset the current price of collateralToSell
        // is calculated from oracle price ($4) to see if dusty
        assertEq(collateralToSell, 2 ether); // (2 * $4) < $20 quivalent (dusty collateral)

        hevm.warp(block.timestamp + 300);
        collateralAuction.redoAuction(1, address(567));
        assertEq(codex.credit(address(567)), 0);
    }

    function test_incentive_max_values() public {
        collateralAuction.setParam("feeTip", 2**64 - 1);
        collateralAuction.setParam("flatTip", 2**192 - 1);

        assertEq(uint256(collateralAuction.feeTip()), uint256(18.446744073709551615 * 10**18));
        assertEq(
            uint256(collateralAuction.flatTip()),
            uint256(6277101735386.680763835789423207666416102355444464034512895 * 10**45)
        );

        collateralAuction.setParam("feeTip", 2**64);
        collateralAuction.setParam("flatTip", 2**192);

        assertEq(uint256(collateralAuction.feeTip()), 0);
        assertEq(uint256(collateralAuction.flatTip()), 0);
    }

    function test_collateralAuction_cancelAuction() public takeCollateralSetup {
        uint256 preTokenBalance = codex.balances(vault, tokenId, address(this));
        (, , uint256 origCollateralToSell, , , , , ) = collateralAuction.auctions(1);

        uint256 startGas = gasleft();
        collateralAuction.cancelAuction(1);
        uint256 endGas = gasleft();
        emit log_named_uint("cancelAuction gas", startGas - endGas);

        // Assert that the auction was deleted.
        (
            uint256 index,
            uint256 debt,
            uint256 collateralToSell,
            ,
            ,
            address user,
            uint256 startsAt,
            uint256 startPrice
        ) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0);
        assertEq(user, address(0));
        assertEq(uint256(startsAt), 0);
        assertEq(startPrice, 0);

        // Assert that callback to clear debtOnAuction was successful.
        assertEq(limes.globalDebtOnAuction(), 0);
        (, , , uint256 debtOnAuction) = limes.vaults(vault);
        assertEq(debtOnAuction, 0);

        // Assert transfer of token.
        assertEq(codex.balances(vault, tokenId, address(this)), preTokenBalance + origCollateralToSell);
    }

    function test_remove_id() public {
        PublicCollateralAuction pAuction = new PublicCollateralAuction(
            address(codex),
            address(collybus),
            address(limes),
            address(vault)
        );
        uint256 index;

        pAuction.addAuction();
        pAuction.addAuction();
        uint256 auctionId = pAuction.addAuction();
        pAuction.addAuction();
        pAuction.addAuction();

        // [1,2,3,4,5]
        assertEq(pAuction.count(), 5); // 5 elements added
        assertEq(pAuction.activeAuctions(0), 1);
        assertEq(pAuction.activeAuctions(1), 2);
        assertEq(pAuction.activeAuctions(2), 3);
        assertEq(pAuction.activeAuctions(3), 4);
        assertEq(pAuction.activeAuctions(4), 5);

        pAuction.removeAuction(auctionId);

        // [1,2,5,4]
        assertEq(pAuction.count(), 4);
        assertEq(pAuction.activeAuctions(0), 1);
        assertEq(pAuction.activeAuctions(1), 2);
        assertEq(pAuction.activeAuctions(2), 5); // Swapped last for middle
        (index, , , , , , , ) = pAuction.auctions(5);
        assertEq(index, 2);
        assertEq(pAuction.activeAuctions(3), 4);

        pAuction.removeAuction(4);

        // [1,2,5]
        assertEq(pAuction.count(), 3);

        (index, , , , , , , ) = pAuction.auctions(1);
        assertEq(index, 0); // Auction 1 in slot 0
        assertEq(pAuction.activeAuctions(0), 1);

        (index, , , , , , , ) = pAuction.auctions(2);
        assertEq(index, 1); // Auction 2 in slot 1
        assertEq(pAuction.activeAuctions(1), 2);

        (index, , , , , , , ) = pAuction.auctions(5);
        assertEq(index, 2); // Auction 5 in slot 2
        assertEq(pAuction.activeAuctions(2), 5); // Final element removed

        (index, , , , , , , ) = pAuction.auctions(4);
        assertEq(index, 0); // Auction 4 was deleted. Returns 0
    }

    function testFail_id_out_of_range() public {
        PublicCollateralAuction pAuction = new PublicCollateralAuction(
            address(codex),
            address(collybus),
            address(limes),
            address(vault)
        );

        pAuction.addAuction();
        pAuction.addAuction();

        pAuction.activeAuctions(9); // Fail because auctionId is out of range
    }

    function testFail_not_enough_credit() public takeCollateralSetup {
        Guy(che).takeCollateral({
            auctionId: 1,
            collateralAmount: 25 ether,
            maxPrice: 5 ether,
            recipient: address(che),
            data: ""
        });
    }

    function test_flashauction() public takeCollateralSetup {
        assertEq(codex.credit(che), 0);
        assertEq(credit.balanceOf(che), 0);
        Guy(che).takeCollateral({
            auctionId: 1,
            collateralAmount: 25 ether,
            maxPrice: 5 ether,
            recipient: address(che),
            data: "hey"
        });
        assertEq(codex.credit(che), 0);
        assertTrue(credit.balanceOf(che) > 0); // Che turned a profit
    }

    function testFail_reentrancy_takeCollateral() public takeCollateralSetup {
        BadGuy user = new BadGuy(collateralAuction);
        user.grantDelegate(address(collateralAuction));
        codex.createUnbackedDebt(address(0), address(user), 1000 ether);

        user.takeCollateral({
            auctionId: 1,
            collateralAmount: 25 ether,
            maxPrice: 5 ether,
            recipient: address(user),
            data: "hey"
        });
    }

    function testFail_reentrancy_redoAuction() public takeCollateralSetup {
        RedoGuy user = new RedoGuy(collateralAuction);
        user.grantDelegate(address(collateralAuction));
        codex.createUnbackedDebt(address(0), address(user), 1000 ether);

        user.takeCollateral({
            auctionId: 1,
            collateralAmount: 25 ether,
            maxPrice: 5 ether,
            recipient: address(user),
            data: "hey"
        });
    }

    function testFail_reentrancy_startAuction() public takeCollateralSetup {
        StartGuy user = new StartGuy(collateralAuction, vault);
        user.grantDelegate(address(collateralAuction));
        codex.createUnbackedDebt(address(0), address(user), 1000 ether);
        collateralAuction.allowCaller(keccak256("ANY_SIG"), address(user));

        user.takeCollateral({
            auctionId: 1,
            collateralAmount: 25 ether,
            maxPrice: 5 ether,
            recipient: address(user),
            data: "hey"
        });
    }

    function testFail_reentrancy_setParam_uint() public takeCollateralSetup {
        SetParamUintGuy user = new SetParamUintGuy(collateralAuction);
        user.grantDelegate(address(collateralAuction));
        codex.createUnbackedDebt(address(0), address(user), 1000 ether);
        collateralAuction.allowCaller(keccak256("ANY_SIG"), address(user));

        user.takeCollateral({
            auctionId: 1,
            collateralAmount: 25 ether,
            maxPrice: 5 ether,
            recipient: address(user),
            data: "hey"
        });
    }

    function testFail_reentrancy_setParam_addr() public takeCollateralSetup {
        SetParamAddrGuy user = new SetParamAddrGuy(collateralAuction);
        user.grantDelegate(address(collateralAuction));
        codex.createUnbackedDebt(address(0), address(user), 1000 ether);
        collateralAuction.allowCaller(keccak256("ANY_SIG"), address(user));

        user.takeCollateral({
            auctionId: 1,
            collateralAmount: 25 ether,
            maxPrice: 5 ether,
            recipient: address(user),
            data: "hey"
        });
    }

    function testFail_reentrancy_cancelAuction() public takeCollateralSetup {
        YankGuy user = new YankGuy(collateralAuction);
        user.grantDelegate(address(collateralAuction));
        codex.createUnbackedDebt(address(0), address(user), 1000 ether);
        collateralAuction.allowCaller(keccak256("ANY_SIG"), address(user));

        user.takeCollateral({
            auctionId: 1,
            collateralAmount: 25 ether,
            maxPrice: 5 ether,
            recipient: address(user),
            data: "hey"
        });
    }

    function testFail_takeCollateral_impersonation() public takeCollateralSetup {
        // should fail, but works
        Guy user = new Guy(collateralAuction);
        user.takeCollateral({
            auctionId: 1,
            collateralAmount: 99999999999999 ether,
            maxPrice: 99999999999999 ether,
            recipient: address(ali),
            data: ""
        });
    }

    function test_gas_liquidate_startAuction() public {
        // Assertions to make sure setup is as expected.
        assertEq(collateralAuction.auctionCounter(), 0);
        (
            uint256 index,
            uint256 debt,
            uint256 collateralToSell,
            ,
            ,
            address user,
            uint256 startsAt,
            uint256 startPrice
        ) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0);
        assertEq(user, address(0));
        assertEq(uint256(startsAt), 0);
        assertEq(startPrice, 0);
        assertEq(codex.balances(vault, tokenId, me), 960 ether);
        assertEq(codex.credit(ali), 1000 ether);
        (uint256 collateral, uint256 normalDebt) = codex.positions(vault, tokenId, me);
        assertEq(collateral, 40 ether);
        assertEq(normalDebt, 100 ether);

        uint256 preGas = gasleft();
        Guy(ali).liquidate(limes, vault, tokenId, me, address(ali));
        uint256 diffGas = preGas - gasleft();
        emit log_named_uint("liquidate with startAuction gas", diffGas);
    }

    function test_gas_partial_takeCollateral() public takeCollateralSetup {
        uint256 preGas = gasleft();
        // Bid so owe (= 11 * 5 = 55 WAD) < debt (= 110 WAD)
        Guy(ali).takeCollateral({
            auctionId: 1,
            collateralAmount: 11 ether, // Half of debt at $110
            maxPrice: 5 ether,
            recipient: address(ali),
            data: ""
        });
        uint256 diffGas = preGas - gasleft();
        emit log_named_uint("partial takeCollateral gas", diffGas);

        assertEq(codex.balances(vault, tokenId, ali), 11 ether); // Didn't take whole collateralToSell
        assertEq(codex.credit(ali), 945 ether); // Paid half debt (55)
        assertEq(codex.balances(vault, tokenId, me), 960 ether); // Collateral not returned (yet)

        // Assert auction DOES NOT end
        (
            uint256 index,
            uint256 debt,
            uint256 collateralToSell,
            ,
            ,
            address user,
            uint256 startsAt,
            uint256 startPrice
        ) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 55 ether); // 110 - 5 * 11
        assertEq(collateralToSell, 29 ether); // 40 - 11
        assertEq(user, me);
        assertEq(uint256(startsAt), block.timestamp);
        assertEq(startPrice, 5 ether);
    }

    function test_gas_full_takeCollateral() public takeCollateralSetup {
        uint256 preGas = gasleft();
        // Bid so owe (= 25 * 5 = 125 WAD) > debt (= 110 WAD)
        // Readjusts collateralSlice to be debt/startPrice = 25
        Guy(ali).takeCollateral({
            auctionId: 1,
            collateralAmount: 25 ether,
            maxPrice: 5 ether,
            recipient: address(ali),
            data: ""
        });
        uint256 diffGas = preGas - gasleft();
        emit log_named_uint("full takeCollateral gas", diffGas);

        assertEq(codex.balances(vault, tokenId, ali), 22 ether); // Didn't take whole collateralToSell
        assertEq(codex.credit(ali), 890 ether); // Didn't pay more than debt (110)
        assertEq(codex.balances(vault, tokenId, me), 978 ether); // 960 + (40 - 22) returned to user

        // Assert auction ends
        (
            uint256 index,
            uint256 debt,
            uint256 collateralToSell,
            ,
            ,
            address user,
            uint256 startsAt,
            uint256 startPrice
        ) = collateralAuction.auctions(1);
        assertEq(index, 0);
        assertEq(debt, 0);
        assertEq(collateralToSell, 0);
        assertEq(user, address(0));
        assertEq(uint256(startsAt), 0);
        assertEq(startPrice, 0);
    }
}
