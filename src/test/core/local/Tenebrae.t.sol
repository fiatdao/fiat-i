// SPDX-License-Identifier: AGPL-3.0-or-later
// Copyright (C) 2018 Rain <rainbreak@riseup.net>
// Copyright (C) 2018 Lev Livnev <lev@liv.nev.org.uk>
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {DSToken} from "../../utils/dapphub/DSToken.sol";
import {DSValue} from "../../utils/dapphub/DSValue.sol";

import {Codex} from "../../../core/Codex.sol";
import {CollateralAuction} from "../../../core/auctions/CollateralAuction.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {DebtAuction} from "../../../core/auctions/DebtAuction.sol";
import {Aer} from "../../../core/Aer.sol";
import {Limes} from "../../../core/Limes.sol";
import {WAD, wmul} from "../../../core/utils/Math.sol";
import {Vault20} from "../../../vaults/Vault.sol";
import {SurplusAuction} from "../../../core/auctions/SurplusAuction.sol";
import {Tenebrae} from "../../../core/Tenebrae.sol";

uint256 constant tokenId = 0;

interface Hevm {
    function warp(uint256) external;
}

contract User {
    Codex public codex;
    Tenebrae public tenebrae;

    constructor(Codex codex_, Tenebrae tenebrae_) {
        codex = codex_;
        tenebrae = tenebrae_;
    }

    function modifyCollateralAndDebt(
        address vault,
        uint256 tokenId_,
        address u,
        address v,
        address w,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    ) public {
        codex.modifyCollateralAndDebt(vault, tokenId_, u, v, w, deltaCollateral, deltaNormalDebt);
    }

    function transferBalance(
        address vault,
        uint256 tokenId_,
        address src,
        address dst,
        uint256 amount
    ) public {
        codex.transferBalance(vault, tokenId_, src, dst, amount);
    }

    function transferCredit(
        address src,
        address dst,
        uint256 amount
    ) public {
        codex.transferCredit(src, dst, amount);
    }

    function grantDelegate(address user) public {
        codex.grantDelegate(user);
    }

    function exit(
        Vault20 vaultA,
        address user,
        uint256 amount
    ) public {
        vaultA.exit(0, user, amount);
    }

    function closePosition(address vault, uint256 tokenId_) public {
        tenebrae.closePosition(vault, tokenId_);
    }

    function redeem(
        address vault,
        uint256 tokenId_,
        uint256 credit
    ) public {
        tenebrae.redeem(vault, tokenId_, credit);
    }
}

contract TenebraeTest is Test {
    Hevm hevm;

    Codex codex;
    Tenebrae tenebrae;
    Aer aer;
    Limes limes;

    Collybus collybus;

    struct Vault {
        DSValue priceFeed;
        DSToken token;
        Vault20 vaultA;
        CollateralAuction collateralAuction;
    }

    mapping(address => Vault) vaults;

    SurplusAuction surplusAuction;
    DebtAuction debtAuction;

    function credit(address position) internal view returns (uint256) {
        return codex.credit(position) / WAD;
    }

    function token(
        address vault,
        uint256 tokenId_,
        address position
    ) internal view returns (uint256) {
        return codex.balances(vault, tokenId_, position);
    }

    function collateral(
        address vault,
        uint256 tokenId_,
        address position
    ) internal view returns (uint256) {
        (uint256 collateral_, uint256 normalDebt_) = codex.positions(vault, tokenId_, position);
        normalDebt_;
        return collateral_;
    }

    function normalDebt(
        address vault,
        uint256 tokenId_,
        address position
    ) internal view returns (uint256) {
        (uint256 collateral_, uint256 normalDebt_) = codex.positions(vault, tokenId_, position);
        collateral_;
        return normalDebt_;
    }

    function balanceOf(address vault, address user) internal view returns (uint256) {
        return vaults[vault].token.balanceOf(user);
    }

    function init_collateral() internal returns (Vault memory) {
        DSToken coin = new DSToken("");
        Vault20 vaultA = new Vault20(address(codex), address(coin), address(collybus));
        coin.mint(500_000 ether);

        collybus.setParam(address(vaultA), "liquidationRatio", 2 ether);
        // initial collateral price of 6
        collybus.updateSpot(address(coin), 6 * WAD);

        codex.init(address(vaultA));
        codex.setParam(address(vaultA), "debtCeiling", 1_000_000 ether);

        coin.approve(address(vaultA));
        coin.approve(address(codex));

        codex.allowCaller(keccak256("ANY_SIG"), address(vaultA));

        CollateralAuction collateralAuction = new CollateralAuction(address(codex), address(limes));
        collateralAuction.init(address(vaultA), address(collybus));
        codex.allowCaller(keccak256("ANY_SIG"), address(collateralAuction));
        codex.grantDelegate(address(collateralAuction));
        collateralAuction.allowCaller(keccak256("ANY_SIG"), address(tenebrae));
        collateralAuction.allowCaller(keccak256("ANY_SIG"), address(limes));
        limes.allowCaller(keccak256("ANY_SIG"), address(collateralAuction));
        limes.setParam(address(vaultA), "collateralAuction", address(collateralAuction));
        limes.setParam(address(vaultA), "liquidationPenalty", 1.1 ether);
        limes.setParam(address(vaultA), "maxDebtOnAuction", 25000 ether);
        limes.setParam("globalMaxDebtOnAuction", 25000 ether);

        vaults[address(vaultA)].token = coin;
        vaults[address(vaultA)].vaultA = vaultA;
        vaults[address(vaultA)].collateralAuction = collateralAuction;

        return vaults[address(vaultA)];
    }

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(604411200);

        codex = new Codex();
        DSToken gov = new DSToken("GOV");

        surplusAuction = new SurplusAuction(address(codex), address(gov));
        debtAuction = new DebtAuction(address(codex), address(gov));
        gov.setOwner(address(debtAuction));

        aer = new Aer(address(codex), address(surplusAuction), address(debtAuction));

        limes = new Limes(address(codex));
        limes.setParam("aer", address(aer));
        codex.allowCaller(keccak256("ANY_SIG"), address(limes));
        aer.allowCaller(keccak256("ANY_SIG"), address(limes));

        collybus = new Collybus();
        codex.setParam("globalDebtCeiling", 1_000_000 ether);
        codex.allowCaller(keccak256("ANY_SIG"), address(collybus));

        tenebrae = new Tenebrae();
        tenebrae.setParam("codex", address(codex));
        tenebrae.setParam("limes", address(limes));
        tenebrae.setParam("aer", address(aer));
        tenebrae.setParam("collybus", address(collybus));
        tenebrae.setParam("cooldownDuration", 1 hours);
        codex.allowCaller(keccak256("ANY_SIG"), address(tenebrae));
        aer.allowCaller(keccak256("ANY_SIG"), address(tenebrae));
        collybus.allowCaller(keccak256("ANY_SIG"), address(tenebrae));
        limes.allowCaller(keccak256("ANY_SIG"), address(tenebrae));
        surplusAuction.allowCaller(keccak256("ANY_SIG"), address(aer));
        debtAuction.allowCaller(keccak256("ANY_SIG"), address(aer));
    }

    function test_lock_basic() public {
        assertEq(tenebrae.live(), 1);
        assertEq(codex.live(), 1);
        assertEq(aer.live(), 1);
        assertEq(aer.debtAuction().live(), 1);
        assertEq(aer.surplusAuction().live(), 1);
        tenebrae.lock();
        assertEq(tenebrae.live(), 0);
        assertEq(codex.live(), 0);
        assertEq(aer.live(), 0);
        assertEq(aer.debtAuction().live(), 0);
        assertEq(aer.surplusAuction().live(), 0);
    }

    // -- Scenario where there is one over-collateralised Position
    // -- and there is no Aer deficit or surplus
    function test_lock_collateralised() public {
        Vault memory gold = init_collateral();

        User ali = new User(codex, tenebrae);

        // create a Position:
        address user1 = address(ali);
        gold.vaultA.enter(0, user1, 10 ether);
        ali.modifyCollateralAndDebt(address(gold.vaultA), tokenId, user1, user1, user1, 10 ether, 15 ether);
        // ali's position has 0 token, 10 collateral, 15 debt, 15 credit

        // global checks:
        assertEq(codex.globalDebt(), 15 ether);
        assertEq(codex.globalUnbackedDebt(), 0);

        // collateral price is 5
        collybus.updateSpot(address(gold.token), 5 * WAD);
        tenebrae.lock();
        tenebrae.offsetPosition(address(gold.vaultA), tokenId, user1);

        // local checks:
        assertEq(normalDebt(address(gold.vaultA), tokenId, user1), 0);
        assertEq(collateral(address(gold.vaultA), tokenId, user1), 7 ether);
        assertEq(codex.unbackedDebt(address(aer)), 15 ether);

        // global checks:
        assertEq(codex.globalDebt(), 15 ether);
        assertEq(codex.globalUnbackedDebt(), 15 ether);

        // Positions closing
        ali.closePosition(address(gold.vaultA), tokenId);
        assertEq(collateral(address(gold.vaultA), tokenId, user1), 0);
        assertEq(token(address(gold.vaultA), tokenId, user1), 7 ether);
        ali.exit(gold.vaultA, address(this), 7 ether);

        hevm.warp(block.timestamp + 1 hours);
        tenebrae.fixGlobalDebt();
        assertEq(tenebrae.debt(), 15 ether);
        assertTrue(tenebrae.redemptionPrice(address(gold.vaultA), tokenId) != 0);

        // credit redemption
        ali.grantDelegate(address(tenebrae));
        ali.redeem(address(gold.vaultA), tokenId, 15 ether);

        // global checks:
        assertEq(codex.globalDebt(), 0);
        assertEq(codex.globalUnbackedDebt(), 0);

        // local checks:
        assertEq(credit(user1), 0);
        assertEq(token(address(gold.vaultA), tokenId, user1), 3 ether);
        ali.exit(gold.vaultA, address(this), 3 ether);

        assertEq(token(address(gold.vaultA), tokenId, address(tenebrae)), 0);
        assertEq(balanceOf(address(gold.vaultA), address(gold.vaultA)), 0);
    }

    // -- Scenario where there is one over-collateralised and one
    // -- under-collateralised Position, and no Aer deficit or surplus
    function test_lock_undercollateralised() public {
        Vault memory gold = init_collateral();

        User ali = new User(codex, tenebrae);
        User bob = new User(codex, tenebrae);

        // create a Position:
        address user1 = address(ali);
        gold.vaultA.enter(0, user1, 10 ether);
        ali.modifyCollateralAndDebt(address(gold.vaultA), tokenId, user1, user1, user1, 10 ether, 15 ether);
        // ali's position has 0 token, 10 collateral, 15 debt, 15 credit

        // create a second Position:
        address user2 = address(bob);
        gold.vaultA.enter(0, user2, 1 ether);
        bob.modifyCollateralAndDebt(address(gold.vaultA), tokenId, user2, user2, user2, 1 ether, 3 ether);
        // bob's position has 0 token, 1 collateral, 3 debt, 3 credit

        // global checks:
        assertEq(codex.globalDebt(), 18 ether);
        assertEq(codex.globalUnbackedDebt(), 0);

        // collateral price is 2
        collybus.updateSpot(address(gold.token), 2 * WAD);
        tenebrae.lock();
        tenebrae.offsetPosition(address(gold.vaultA), tokenId, user1); // over-collateralised
        tenebrae.offsetPosition(address(gold.vaultA), tokenId, user2); // under-collateralised

        // local checks
        assertEq(normalDebt(address(gold.vaultA), tokenId, user1), 0);
        assertEq(collateral(address(gold.vaultA), tokenId, user1), 2.5 ether);
        assertEq(normalDebt(address(gold.vaultA), tokenId, user2), 0);
        assertEq(collateral(address(gold.vaultA), tokenId, user2), 0);
        assertEq(codex.unbackedDebt(address(aer)), 18 ether);

        // global checks
        assertEq(codex.globalDebt(), 18 ether);
        assertEq(codex.globalUnbackedDebt(), 18 ether);

        // Position closing
        ali.closePosition(address(gold.vaultA), tokenId);
        assertEq(collateral(address(gold.vaultA), tokenId, user1), 0);
        assertEq(token(address(gold.vaultA), tokenId, user1), 2.5 ether);
        ali.exit(gold.vaultA, address(this), 2.5 ether);

        hevm.warp(block.timestamp + 1 hours);
        tenebrae.fixGlobalDebt();
        assertTrue(tenebrae.redemptionPrice(address(gold.vaultA), tokenId) != 0);

        // first credit redemption
        ali.grantDelegate(address(tenebrae));
        ali.redeem(address(gold.vaultA), tokenId, 15 ether);

        // global checks:
        assertEq(codex.globalDebt(), 3 ether);
        assertEq(codex.globalUnbackedDebt(), 3 ether);

        // local checks:
        assertEq(credit(user1), 0);
        uint256 redemptionPrice = tenebrae.redemptionPrice(address(gold.vaultA), tokenId);
        assertEq(token(address(gold.vaultA), tokenId, user1), wmul(redemptionPrice, uint256(15 ether)));
        ali.exit(gold.vaultA, address(this), wmul(redemptionPrice, uint256(15 ether)));

        // second credit redemption
        bob.grantDelegate(address(tenebrae));
        bob.redeem(address(gold.vaultA), tokenId, 3 ether);

        // global checks:
        assertEq(codex.globalDebt(), 0);
        assertEq(codex.globalUnbackedDebt(), 0);

        // local checks:
        assertEq(credit(user2), 0);
        assertEq(token(address(gold.vaultA), tokenId, user2), wmul(redemptionPrice, uint256(3 ether)));
        bob.exit(gold.vaultA, address(this), wmul(redemptionPrice, uint256(3 ether)));

        // some debtFloor remains in when Tenebrae is triggered because of rounding:
        assertEq(token(address(gold.vaultA), tokenId, address(tenebrae)), 4);
        assertEq(balanceOf(address(gold.vaultA), address(gold.vaultA)), 4);
    }

    // -- Scenario where there is one collateralised Position
    // -- undergoing auction at the time of lock
    function test_lock_skipAuctions() public {
        Vault memory gold = init_collateral();

        User ali = new User(codex, tenebrae);

        codex.modifyRate(address(gold.vaultA), address(aer), int256(0.25 ether));

        // Make a Position:
        address user1 = address(ali);
        gold.vaultA.enter(0, user1, 10 ether);
        ali.modifyCollateralAndDebt(address(gold.vaultA), tokenId, user1, user1, user1, 10 ether, 15 ether);
        (uint256 collateral1, uint256 normalDebt1) = codex.positions(address(gold.vaultA), tokenId, user1); // Position before liquidation
        (, uint256 rate, , ) = codex.vaults(address(gold.vaultA));

        assertEq(codex.balances(address(gold.vaultA), tokenId, user1), 0);
        assertEq(rate, 1.25 ether);
        assertEq(collateral1, 10 ether);
        assertEq(normalDebt1, 15 ether);

        collybus.updateSpot(address(gold.token), 1 ether); // now unsafe

        uint256 id = limes.liquidate(address(gold.vaultA), tokenId, user1, address(this));

        uint256 debt1;
        uint256 collateralToSell1;
        {
            uint256 index1;
            address user1_;
            uint96 startsAt1;
            uint256 startPrice1;
            (index1, debt1, collateralToSell1, , , user1_, startsAt1, startPrice1) = gold.collateralAuction.auctions(
                id
            );
            assertEq(index1, 0);
            assertEq(debt1, (((normalDebt1 * rate) / WAD) * 1.1 ether) / WAD); // debt uses liquidationPenalty
            assertEq(collateralToSell1, collateral1);
            assertEq(user1_, address(ali));
            assertEq(uint256(startsAt1), block.timestamp);
            assertEq(uint256(startPrice1), 1 ether);
        }

        assertEq(limes.globalDebtOnAuction(), debt1);

        {
            (uint256 collateral2, uint256 normalDebt2) = codex.positions(address(gold.vaultA), tokenId, user1); // Position after liquidation
            assertEq(collateral2, 0);
            assertEq(normalDebt2, 0);
        }

        // Collateral price is $5
        collybus.updateSpot(address(gold.token), 5 * WAD);
        tenebrae.lock();
        assertEq(tenebrae.lockPrice(address(gold.vaultA), tokenId), 0.2 ether); // redemptionPrice / price = collateral per Credit

        assertEq(codex.balances(address(gold.vaultA), tokenId, address(gold.collateralAuction)), collateralToSell1); // From confiscateCollateralAndDebt in limes.liquidate()
        assertEq(codex.unbackedDebt(address(aer)), (normalDebt1 * rate) / WAD); // From confiscateCollateralAndDebt in limes.liquidate()
        assertEq(codex.globalUnbackedDebt(), (normalDebt1 * rate) / WAD); // From confiscateCollateralAndDebt in limes.liquidate()
        assertEq(codex.globalDebt(), (normalDebt1 * rate) / WAD); // From modifyCollateralAndDebt
        assertEq(codex.credit(address(aer)), 0); // codex.createUnbackedDebt() hasn't been called

        tenebrae.skipAuction(address(gold.vaultA), id);

        {
            uint256 index2;
            uint256 debt2;
            uint256 collateralToSell2;
            address user2;
            uint96 startsAt2;
            uint256 startPrice2;
            (index2, debt2, collateralToSell2, , , user2, startsAt2, startPrice2) = gold.collateralAuction.auctions(id);
            assertEq(index2, 0);
            assertEq(debt2, 0);
            assertEq(collateralToSell2, 0);
            assertEq(user2, address(0));
            assertEq(uint256(startsAt2), 0);
            assertEq(uint256(startPrice2), 0);
        }

        assertEq(limes.globalDebtOnAuction(), 0); // From collateralAuction.cancelAuction()
        assertEq(codex.balances(address(gold.vaultA), tokenId, address(gold.collateralAuction)), 0); // From collateralAuction.cancelAuction()
        assertEq(codex.balances(address(gold.vaultA), tokenId, address(tenebrae)), 0); // From confiscateCollateralAndDebt in tenebrae.skipAuctions()
        assertEq(codex.unbackedDebt(address(aer)), (normalDebt1 * rate) / WAD); // From confiscateCollateralAndDebt in limes.liquidate()
        assertEq(codex.globalUnbackedDebt(), (normalDebt1 * rate) / WAD); // From confiscateCollateralAndDebt in limes.liquidate()
        assertEq(codex.globalDebt(), debt1 + (normalDebt1 * rate) / WAD); // From modifyCollateralAndDebt and createUnbackedDebt
        assertEq(codex.credit(address(aer)), debt1); // From codex.createUnbackedDebt()

        (uint256 collateral3, uint256 normalDebt3) = codex.positions(address(gold.vaultA), tokenId, user1); // Position after skipAuctions
        assertEq(collateral3, 10 ether); // All collateral returned to Position
        assertEq(normalDebt3, (debt1 * WAD) / rate); // Compounded debt amount of normalized debt transferred back into Position

        tenebrae.offsetPosition(address(gold.vaultA), tokenId, user1);
        assertEq((tenebrae.normalDebtByTokenId(address(gold.vaultA), tokenId) * rate) / WAD, debt1); // Incrementing total normalDebtByTokenId in Tenebrae
    }

    // -- Scenario where there is one over-collateralised Position
    // -- and there is a deficit in the Aer
    function test_lock_collateralised_deficit() public {
        Vault memory gold = init_collateral();

        User ali = new User(codex, tenebrae);

        // make a Position:
        address user1 = address(ali);
        gold.vaultA.enter(0, user1, 10 ether);
        ali.modifyCollateralAndDebt(address(gold.vaultA), tokenId, user1, user1, user1, 10 ether, 15 ether);
        // ali's position has 0 token, 10 collateral, 15 debt, 15 credit
        // createUnbackedDebt 1 credit and give to ali
        codex.createUnbackedDebt(address(aer), address(ali), 1 ether);

        // global checks:
        assertEq(codex.globalDebt(), 16 ether);
        assertEq(codex.globalUnbackedDebt(), 1 ether);

        // collateral price is 5
        collybus.updateSpot(address(gold.token), 5 * WAD);
        tenebrae.lock();
        tenebrae.offsetPosition(address(gold.vaultA), tokenId, user1);

        // local checks:
        assertEq(normalDebt(address(gold.vaultA), tokenId, user1), 0);
        assertEq(collateral(address(gold.vaultA), tokenId, user1), 7 ether);
        assertEq(codex.unbackedDebt(address(aer)), 16 ether);

        // global checks:
        assertEq(codex.globalDebt(), 16 ether);
        assertEq(codex.globalUnbackedDebt(), 16 ether);

        // Position closing
        ali.closePosition(address(gold.vaultA), tokenId);
        assertEq(collateral(address(gold.vaultA), tokenId, user1), 0);
        assertEq(token(address(gold.vaultA), tokenId, user1), 7 ether);
        ali.exit(gold.vaultA, address(this), 7 ether);

        hevm.warp(block.timestamp + 1 hours);
        tenebrae.fixGlobalDebt();
        assertTrue(tenebrae.redemptionPrice(address(gold.vaultA), tokenId) != 0);

        // credit redemption
        ali.grantDelegate(address(tenebrae));
        ali.redeem(address(gold.vaultA), tokenId, 16 ether);

        // global checks:
        assertEq(codex.globalDebt(), 0);
        assertEq(codex.globalUnbackedDebt(), 0);

        // local checks:
        assertEq(credit(user1), 0);
        assertEq(token(address(gold.vaultA), tokenId, user1), 3 ether);
        ali.exit(gold.vaultA, address(this), 3 ether);

        assertEq(token(address(gold.vaultA), tokenId, address(tenebrae)), 0);
        assertEq(balanceOf(address(gold.vaultA), address(gold.vaultA)), 0);
    }

    // -- Scenario where there is one over-collateralised Position
    // -- and one under-collateralised Position and there is a
    // -- surplus in the Aer
    function test_lock_undercollateralised_surplus() public {
        Vault memory gold = init_collateral();

        User ali = new User(codex, tenebrae);
        User bob = new User(codex, tenebrae);

        // make a Position:
        address user1 = address(ali);
        gold.vaultA.enter(0, user1, 10 ether);
        ali.modifyCollateralAndDebt(address(gold.vaultA), tokenId, user1, user1, user1, 10 ether, 15 ether);
        // ali's position has 0 token, 10 collateral, 15 debt, 15 credit
        // alive gives one credit to the aer, creating surplus
        ali.transferCredit(address(ali), address(aer), 1 ether);

        // make a second Position:
        address user2 = address(bob);
        gold.vaultA.enter(0, user2, 1 ether);
        bob.modifyCollateralAndDebt(address(gold.vaultA), tokenId, user2, user2, user2, 1 ether, 3 ether);
        // bob's position has 0 token, 1 collateral, 3 debt, 3 credit

        // global checks:
        assertEq(codex.globalDebt(), 18 ether);
        assertEq(codex.globalUnbackedDebt(), 0);

        // collateral price is 2
        collybus.updateSpot(address(gold.token), 2 * WAD);
        tenebrae.lock();
        // tenebrae.lock(address(gold.vaultA), tokenId);
        tenebrae.offsetPosition(address(gold.vaultA), tokenId, user1); // over-collateralised
        tenebrae.offsetPosition(address(gold.vaultA), tokenId, user2); // under-collateralised

        // local checks
        assertEq(normalDebt(address(gold.vaultA), tokenId, user1), 0);
        assertEq(collateral(address(gold.vaultA), tokenId, user1), 2.5 ether);
        assertEq(normalDebt(address(gold.vaultA), tokenId, user2), 0);
        assertEq(collateral(address(gold.vaultA), tokenId, user2), 0);
        assertEq(codex.unbackedDebt(address(aer)), 18 ether);

        // global checks
        assertEq(codex.globalDebt(), 18 ether);
        assertEq(codex.globalUnbackedDebt(), 18 ether);

        // Position closing
        ali.closePosition(address(gold.vaultA), tokenId);
        assertEq(collateral(address(gold.vaultA), tokenId, user1), 0);
        assertEq(token(address(gold.vaultA), tokenId, user1), 2.5 ether);
        ali.exit(gold.vaultA, address(this), 2.5 ether);

        hevm.warp(block.timestamp + 1 hours);
        // balance the aer
        aer.settleDebtWithSurplus(1 ether);
        tenebrae.fixGlobalDebt();
        assertTrue(tenebrae.redemptionPrice(address(gold.vaultA), tokenId) != 0);

        // first credit redemption
        ali.grantDelegate(address(tenebrae));
        ali.redeem(address(gold.vaultA), tokenId, 14 ether);

        // global checks:
        assertEq(codex.globalDebt(), 3 ether);
        assertEq(codex.globalUnbackedDebt(), 3 ether);

        // local checks:
        assertEq(credit(user1), 0);
        uint256 redemptionPrice = tenebrae.redemptionPrice(address(gold.vaultA), tokenId);
        assertEq(token(address(gold.vaultA), tokenId, user1), wmul(redemptionPrice, uint256(14 ether)));
        ali.exit(gold.vaultA, address(this), wmul(redemptionPrice, uint256(14 ether)));

        // second credit redemption
        bob.grantDelegate(address(tenebrae));
        bob.redeem(address(gold.vaultA), tokenId, 3 ether);

        // global checks:
        assertEq(codex.globalDebt(), 0);
        assertEq(codex.globalUnbackedDebt(), 0);

        // local checks:
        assertEq(credit(user2), 0);
        assertEq(token(address(gold.vaultA), tokenId, user2), wmul(redemptionPrice, uint256(3 ether)));
        bob.exit(gold.vaultA, address(this), wmul(redemptionPrice, uint256(3 ether)));

        // nothing left in after Tenebrae is triggered
        assertEq(token(address(gold.vaultA), tokenId, address(tenebrae)), 0);
        assertEq(balanceOf(address(gold.vaultA), address(gold.vaultA)), 0);
    }

    // -- Scenario where there is one over-collateralised and one
    // -- under-collateralised Position of different collateral types
    // -- and no Aer deficit or surplus
    function test_lock_net_undercollateralised_multiple_vaults() public {
        Vault memory gold = init_collateral();
        Vault memory coal = init_collateral();

        User ali = new User(codex, tenebrae);
        User bob = new User(codex, tenebrae);

        // make a Position:
        address user1 = address(ali);
        gold.vaultA.enter(0, user1, 10 ether);
        ali.modifyCollateralAndDebt(address(gold.vaultA), tokenId, user1, user1, user1, 10 ether, 15 ether);
        // ali's position has 0 token, 10 collateral, 15 debt

        // make a second Position:
        address user2 = address(bob);
        coal.vaultA.enter(0, user2, 1 ether);
        collybus.updateSpot(address(coal.token), 5 * WAD * 2); // account for liquidation threshold
        bob.modifyCollateralAndDebt(address(coal.vaultA), tokenId, user2, user2, user2, 1 ether, 5 ether);
        // bob's position has 0 token, 1 collateral, 5 debt

        collybus.updateSpot(address(gold.token), 2 * WAD);
        // user1 has 20 credit of collateral and 15 credit of debt
        collybus.updateSpot(address(coal.token), 2 * WAD);
        // user2 has 2 credit of collateral and 5 credit of debt
        tenebrae.lock();
        tenebrae.offsetPosition(address(gold.vaultA), tokenId, user1); // over-collateralised
        tenebrae.offsetPosition(address(coal.vaultA), tokenId, user2); // under-collateralised

        hevm.warp(block.timestamp + 1 hours);
        tenebrae.fixGlobalDebt();

        ali.grantDelegate(address(tenebrae));
        bob.grantDelegate(address(tenebrae));

        assertEq(codex.globalDebt(), 20 ether);
        assertEq(codex.globalUnbackedDebt(), 20 ether);
        assertEq(codex.unbackedDebt(address(aer)), 20 ether);

        assertEq(tenebrae.normalDebtByTokenId(address(gold.vaultA), tokenId), 15 ether);
        assertEq(tenebrae.normalDebtByTokenId(address(coal.vaultA), tokenId), 5 ether);

        assertEq(tenebrae.lostCollateral(address(gold.vaultA), tokenId), 0.0 ether);
        assertEq(tenebrae.lostCollateral(address(coal.vaultA), tokenId), 1.5 ether);

        // there are 7.5 gold and 1 coal
        // the gold is worth 15 credit and the coal is worth 2 credit
        // the total collateral pool is worth 17 credit
        // the total outstanding debt is 20 credit
        // each credit should get (15/2)/20 gold and (2/2)/20 coal
        assertEq(tenebrae.redemptionPrice(address(gold.vaultA), tokenId), 0.375 ether);
        assertEq(tenebrae.redemptionPrice(address(coal.vaultA), tokenId), 0.050 ether);

        assertEq(token(address(gold.vaultA), tokenId, address(ali)), 0 ether);
        ali.redeem(address(gold.vaultA), tokenId, 1 ether);
        assertEq(token(address(gold.vaultA), tokenId, address(ali)), 0.375 ether);

        bob.redeem(address(coal.vaultA), tokenId, 1 ether);
        assertEq(token(address(coal.vaultA), tokenId, address(bob)), 0.05 ether);

        ali.exit(gold.vaultA, address(ali), 0.375 ether);
        bob.exit(coal.vaultA, address(bob), 0.05 ether);
        ali.redeem(address(gold.vaultA), tokenId, 1 ether);
        ali.redeem(address(coal.vaultA), tokenId, 1 ether);
        assertEq(token(address(gold.vaultA), tokenId, address(ali)), 0.375 ether);
        assertEq(token(address(coal.vaultA), tokenId, address(ali)), 0.05 ether);

        ali.exit(gold.vaultA, address(ali), 0.375 ether);
        ali.exit(coal.vaultA, address(ali), 0.05 ether);

        ali.redeem(address(gold.vaultA), tokenId, 1 ether);
        assertEq(tenebrae.claimed(address(gold.vaultA), tokenId, address(ali)), 3 ether);
        assertEq(tenebrae.claimed(address(coal.vaultA), tokenId, address(ali)), 1 ether);
        ali.redeem(address(coal.vaultA), tokenId, 1 ether);
        assertEq(tenebrae.claimed(address(gold.vaultA), tokenId, address(ali)), 3 ether);
        assertEq(tenebrae.claimed(address(coal.vaultA), tokenId, address(ali)), 2 ether);
        assertEq(token(address(gold.vaultA), tokenId, address(ali)), 0.375 ether);
        assertEq(token(address(coal.vaultA), tokenId, address(ali)), 0.05 ether);
    }

    // -- Scenario where fixPrice() used to overflow
    function test_overflow() public {
        Vault memory gold = init_collateral();

        User ali = new User(codex, tenebrae);

        // make a Position:
        address user1 = address(ali);
        gold.vaultA.enter(0, user1, 500_000 ether);
        ali.modifyCollateralAndDebt(address(gold.vaultA), tokenId, user1, user1, user1, 500_000 ether, 1_000_000 ether);
        // ali's position has 500_000 collateral, 10^6 normalDebt (and 10^6 credit since rate == WAD)

        // global checks:
        assertEq(codex.globalDebt(), 1_000_000 ether);
        assertEq(codex.globalUnbackedDebt(), 0);

        // collateral price is 5
        collybus.updateSpot(address(gold.token), 5 * WAD);
        tenebrae.lock();
        tenebrae.offsetPosition(address(gold.vaultA), tokenId, user1);

        // local checks:
        assertEq(normalDebt(address(gold.vaultA), tokenId, user1), 0);
        assertEq(collateral(address(gold.vaultA), tokenId, user1), 300_000 ether);
        assertEq(codex.unbackedDebt(address(aer)), 1_000_000 ether);

        // global checks:
        assertEq(codex.globalDebt(), 1_000_000 ether);
        assertEq(codex.globalUnbackedDebt(), 1_000_000 ether);

        // Position closing
        ali.closePosition(address(gold.vaultA), tokenId);
        assertEq(collateral(address(gold.vaultA), tokenId, user1), 0);
        assertEq(token(address(gold.vaultA), tokenId, user1), 300_000 ether);
        ali.exit(gold.vaultA, address(this), 300_000 ether);

        hevm.warp(block.timestamp + 1 hours);
        tenebrae.fixGlobalDebt();
    }
}
