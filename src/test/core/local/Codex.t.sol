// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {DSToken} from "../../utils/dapphub/DSToken.sol";

import {IVault} from "../../../interfaces/IVault.sol";

import {WAD, sub} from "../../../core/utils/Math.sol";
import {Codex} from "../../../core/Codex.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {Aer} from "../../../core/Aer.sol";
import {Publican} from "../../../core/Publican.sol";
import {Vault20} from "../../../vaults/Vault.sol";
import {Moneta} from "../../../core/Moneta.sol";

import {DebtAuction} from "./DebtAuction.t.sol";
import {SurplusAuction} from "./SurplusAuction.t.sol";

uint256 constant tokenId = 0;

contract TestCodex is Codex {
    function mint(address user, uint256 amount) public {
        credit[user] += amount;
        globalDebt += amount;
    }
}

contract TestAer is Aer {
    constructor(
        address codex,
        address surplusAuction,
        address debtAuction
    ) Aer(codex, surplusAuction, debtAuction) {}

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

contract User {
    Codex public codex;

    constructor(Codex codex_) {
        codex = codex_;
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

    function can_modifyCollateralAndDebt(
        address vault,
        uint256 tokenId_,
        address u,
        address v,
        address w,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    ) public returns (bool) {
        string memory sig = "modifyCollateralAndDebt(address,uint256,address,address,address,int256,int256)";
        bytes memory data = abi.encodeWithSignature(sig, vault, tokenId_, u, v, w, deltaCollateral, deltaNormalDebt);

        bytes memory can_call = abi.encodeWithSignature("try_call(address,bytes)", codex, data);
        (bool ok, bytes memory success) = address(this).call(can_call);

        ok = abi.decode(success, (bool));
        if (ok) return true;
        return false;
    }

    function can_transferCollateralAndDebt(
        address vault,
        uint256 tokenId_,
        address src,
        address dst,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    ) public returns (bool) {
        string memory sig = "transferCollateralAndDebt(address,uint256,address,address,int256,int256)";
        bytes memory data = abi.encodeWithSignature(sig, vault, tokenId_, src, dst, deltaCollateral, deltaNormalDebt);

        bytes memory can_call = abi.encodeWithSignature("try_call(address,bytes)", codex, data);
        (bool ok, bytes memory success) = address(this).call(can_call);

        ok = abi.decode(success, (bool));
        if (ok) return true;
        return false;
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

    function transferCollateralAndDebt(
        address vault,
        uint256 tokenId_,
        address src,
        address dst,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    ) public {
        codex.transferCollateralAndDebt(vault, tokenId_, src, dst, deltaCollateral, deltaNormalDebt);
    }

    function grantDelegate(address user) public {
        codex.grantDelegate(user);
    }
}

contract ModifyCollateralAndDebtTest is Test {
    TestCodex codex;
    DSToken gold;
    Publican publican;
    Collybus collybus;
    Vault20 vaultA;
    address me;

    function try_modifyCollateralAndDebt(
        address vault,
        uint256 tokenId_,
        int256 collateral_,
        int256 normalDebt_
    ) public returns (bool ok) {
        string memory sig = "modifyCollateralAndDebt(address,uint256,address,address,address,int256,int256)";
        address self = address(this);
        (ok, ) = address(codex).call(
            abi.encodeWithSignature(sig, vault, tokenId_, self, self, self, collateral_, normalDebt_)
        );
    }

    function setUp() public {
        codex = new TestCodex();

        gold = new DSToken("TOKEN");
        gold.mint(1000 ether);

        collybus = new Collybus();

        vaultA = new Vault20(address(codex), address(gold), address(collybus));
        codex.init(address(vaultA));

        publican = new Publican(address(codex));
        publican.init(address(vaultA));
        publican.allowCaller(keccak256("ANY_SIG"), address(publican));

        collybus.setParam(address(vaultA), "liquidationRatio", 1 ether);
        collybus.updateSpot(address(gold), 1 ether);

        codex.setParam(address(vaultA), "debtCeiling", 1000 ether);
        codex.setParam("globalDebtCeiling", 1000 ether);

        gold.approve(address(vaultA));
        gold.approve(address(codex));

        codex.allowCaller(keccak256("ANY_SIG"), address(codex));
        codex.allowCaller(keccak256("ANY_SIG"), address(vaultA));

        vaultA.enter(0, address(this), 1000 ether);

        me = address(this);
    }

    function token(
        address vault,
        uint256 tokenId_,
        address user
    ) internal view returns (uint256) {
        return codex.balances(vault, tokenId_, user);
    }

    function collateral(
        address vault,
        uint256 tokenId_,
        address user
    ) internal view returns (uint256) {
        (uint256 collateral_, uint256 normalDebt_) = codex.positions(vault, tokenId_, user);
        normalDebt_;
        return collateral_;
    }

    function normalDebt(
        address vault,
        uint256 tokenId_,
        address user
    ) internal view returns (uint256) {
        (uint256 collateral_, uint256 normalDebt_) = codex.positions(vault, tokenId_, user);
        collateral_;
        return normalDebt_;
    }

    function test_setup() public {
        assertEq(gold.balanceOf(address(vaultA)), 1000 ether);
        assertEq(token(address(vaultA), tokenId, address(this)), 1000 ether);
    }

    function test_enter() public {
        address position = address(this);
        gold.mint(500 ether);
        assertEq(gold.balanceOf(address(this)), 500 ether);
        assertEq(gold.balanceOf(address(vaultA)), 1000 ether);
        vaultA.enter(0, position, 500 ether);
        assertEq(gold.balanceOf(address(this)), 0 ether);
        assertEq(gold.balanceOf(address(vaultA)), 1500 ether);
        vaultA.exit(0, position, 250 ether);
        assertEq(gold.balanceOf(address(this)), 250 ether);
        assertEq(gold.balanceOf(address(vaultA)), 1250 ether);
    }

    function test_lock() public {
        assertEq(collateral(address(vaultA), tokenId, address(this)), 0 ether);
        assertEq(token(address(vaultA), tokenId, address(this)), 1000 ether);
        codex.modifyCollateralAndDebt(address(vaultA), tokenId, me, me, me, 6 ether, 0);
        assertEq(collateral(address(vaultA), tokenId, address(this)), 6 ether);
        assertEq(token(address(vaultA), tokenId, address(this)), 994 ether);
        codex.modifyCollateralAndDebt(address(vaultA), tokenId, me, me, me, -6 ether, 0);
        assertEq(collateral(address(vaultA), tokenId, address(this)), 0 ether);
        assertEq(token(address(vaultA), tokenId, address(this)), 1000 ether);
    }

    function test_debtCeiling_below() public {
        // it's ok to increase debt as long as debt ceiling is not exceeded
        codex.setParam(address(vaultA), "debtCeiling", 10 ether);
        assertTrue(try_modifyCollateralAndDebt(address(vaultA), tokenId, 10 ether, 9 ether));
        // only if under debt ceiling
        assertTrue(!try_modifyCollateralAndDebt(address(vaultA), tokenId, 0 ether, 2 ether));
    }

    function test_debtCeiling_aboveButDecreasingDebt() public {
        // it's ok to be over the debt ceiling as long as debt is decreasing
        codex.setParam(address(vaultA), "debtCeiling", 10 ether);
        assertTrue(try_modifyCollateralAndDebt(address(vaultA), tokenId, 10 ether, 8 ether));
        codex.setParam(address(vaultA), "debtCeiling", 5 ether);
        // can decrease debt when over ceiling
        assertTrue(try_modifyCollateralAndDebt(address(vaultA), tokenId, 0 ether, -1 ether));
    }

    function test_safe() public {
        // safe means that the position is not risky
        // you can't modifyCollateralAndDebt a position into unsafe
        codex.modifyCollateralAndDebt(address(vaultA), tokenId, me, me, me, 10 ether, 5 ether); // safe
        assertTrue(!try_modifyCollateralAndDebt(address(vaultA), tokenId, 0 ether, 6 ether)); // unsafe
    }

    function test_unsafe() public {
        // remaining unsafe is ok as long as collateral has increased or debt has decreased

        codex.modifyCollateralAndDebt(address(vaultA), tokenId, me, me, me, 10 ether, 10 ether);
        collybus.updateSpot(address(vaultA.token()), 0.5 ether); // now unsafe

        // debt can't increase if unsafe
        assertTrue(!try_modifyCollateralAndDebt(address(vaultA), tokenId, 0 ether, 1 ether));
        // debt can decrease
        assertTrue(try_modifyCollateralAndDebt(address(vaultA), tokenId, 0 ether, -1 ether));
        // collateral can't decrease
        assertTrue(!try_modifyCollateralAndDebt(address(vaultA), tokenId, -1 ether, 0 ether));
        // collateral can increase
        assertTrue(try_modifyCollateralAndDebt(address(vaultA), tokenId, 1 ether, 0 ether));

        // position is still unsafe
        // collateral can't decrease, even if debt decreases more
        assertTrue(!this.try_modifyCollateralAndDebt(address(vaultA), tokenId, -2 ether, -4 ether));
        // debt can't increase, even if collateral increases more
        assertTrue(!this.try_modifyCollateralAndDebt(address(vaultA), tokenId, 5 ether, 1 ether));

        // collateral can decrease if end state is safe
        assertTrue(this.try_modifyCollateralAndDebt(address(vaultA), tokenId, -1 ether, -4 ether));
        collybus.updateSpot(address(vaultA.token()), 0.4 ether); // now unsafe
        // debt can increase if end state is safe
        assertTrue(this.try_modifyCollateralAndDebt(address(vaultA), tokenId, 5 ether, 1 ether));
    }

    function test_alt_callers() public {
        User ali = new User(codex);
        User bob = new User(codex);
        User che = new User(codex);

        address a = address(ali);
        address b = address(bob);
        address c = address(che);

        codex.modifyBalance(address(vaultA), tokenId, a, int256(20 ether));
        codex.modifyBalance(address(vaultA), tokenId, b, int256(20 ether));
        codex.modifyBalance(address(vaultA), tokenId, c, int256(20 ether));

        ali.modifyCollateralAndDebt(address(vaultA), tokenId, a, a, a, 10 ether, 5 ether);

        // anyone can lock
        assertTrue(ali.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, a, a, 1 ether, 0 ether));
        assertTrue(bob.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, b, b, 1 ether, 0 ether));
        assertTrue(che.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, c, c, 1 ether, 0 ether));
        // but only with their own tokens
        assertTrue(!ali.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, b, a, 1 ether, 0 ether));
        assertTrue(!bob.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, c, b, 1 ether, 0 ether));
        assertTrue(!che.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, a, c, 1 ether, 0 ether));

        // only the lad can free
        assertTrue(ali.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, a, a, -1 ether, 0 ether));
        assertTrue(!bob.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, b, b, -1 ether, 0 ether));
        assertTrue(!che.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, c, c, -1 ether, 0 ether));
        // the lad can free to anywhere
        assertTrue(ali.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, b, a, -1 ether, 0 ether));
        assertTrue(ali.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, c, a, -1 ether, 0 ether));

        // only the lad can create debt
        assertTrue(ali.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, a, a, 0 ether, 1 ether));
        assertTrue(!bob.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, b, b, 0 ether, 1 ether));
        assertTrue(!che.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, c, c, 0 ether, 1 ether));
        // the lad can create debt to anywhere
        assertTrue(ali.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, a, b, 0 ether, 1 ether));
        assertTrue(ali.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, a, c, 0 ether, 1 ether));

        codex.mint(address(bob), 1 ether);
        codex.mint(address(che), 1 ether);

        // anyone can decrease debt
        assertTrue(ali.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, a, a, 0 ether, -1 ether));
        assertTrue(bob.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, b, b, 0 ether, -1 ether));
        assertTrue(che.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, c, c, 0 ether, -1 ether));
        // but only with their own credit
        assertTrue(!ali.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, a, b, 0 ether, -1 ether));
        assertTrue(!bob.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, b, c, 0 ether, -1 ether));
        assertTrue(!che.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, c, a, 0 ether, -1 ether));
    }

    function test_grantDelegate() public {
        User ali = new User(codex);
        User bob = new User(codex);
        User che = new User(codex);

        address a = address(ali);
        address b = address(bob);
        address c = address(che);

        codex.modifyBalance(address(vaultA), tokenId, a, int256(20 ether));
        codex.modifyBalance(address(vaultA), tokenId, b, int256(20 ether));
        codex.modifyBalance(address(vaultA), tokenId, c, int256(20 ether));

        ali.modifyCollateralAndDebt(address(vaultA), tokenId, a, a, a, 10 ether, 5 ether);

        // only owner can do risky actions
        assertTrue(ali.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, a, a, 0 ether, 1 ether));
        assertTrue(!bob.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, b, b, 0 ether, 1 ether));
        assertTrue(!che.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, c, c, 0 ether, 1 ether));

        ali.grantDelegate(address(bob));

        // unless they grantDelegate another user
        assertTrue(ali.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, a, a, 0 ether, 1 ether));
        assertTrue(bob.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, b, b, 0 ether, 1 ether));
        assertTrue(!che.can_modifyCollateralAndDebt(address(vaultA), tokenId, a, c, c, 0 ether, 1 ether));
    }

    function test_debtFloor() public {
        assertTrue(try_modifyCollateralAndDebt(address(vaultA), tokenId, 9 ether, 1 ether));
        codex.setParam(address(vaultA), "debtFloor", 5 ether);
        assertTrue(!try_modifyCollateralAndDebt(address(vaultA), tokenId, 5 ether, 2 ether));
        assertTrue(try_modifyCollateralAndDebt(address(vaultA), tokenId, 0 ether, 5 ether));
        assertTrue(!try_modifyCollateralAndDebt(address(vaultA), tokenId, 0 ether, -5 ether));
        assertTrue(try_modifyCollateralAndDebt(address(vaultA), tokenId, 0 ether, -6 ether));
    }
}

contract VaultTest is Test {
    TestCodex codex;
    DSToken token;
    Vault20 vaultA;
    Moneta creditA;
    DSToken credit;
    address me;

    function setUp() public {
        codex = new TestCodex();

        Collybus collybus = new Collybus();

        token = new DSToken("Token");
        vaultA = new Vault20(address(codex), address(token), address(collybus));
        codex.init(address(vaultA));
        codex.allowCaller(keccak256("ANY_SIG"), address(vaultA));

        credit = new DSToken("Credit");
        creditA = new Moneta(address(codex), address(credit));
        codex.allowCaller(keccak256("ANY_SIG"), address(creditA));
        credit.setOwner(address(creditA));

        me = address(this);
    }

    function try_lock(address a) public payable returns (bool ok) {
        string memory sig = "lock()";
        (ok, ) = a.call(abi.encodeWithSignature(sig));
    }

    function try_enter_token(address user, uint256 amount) public returns (bool ok) {
        string memory sig = "enter(uint256,address,uint256)";
        (ok, ) = address(vaultA).call(abi.encodeWithSignature(sig, 0, user, amount));
    }

    function try_exit_credit(address user, uint256 amount) public returns (bool ok) {
        string memory sig = "exit(address,uint256)";
        (ok, ) = address(creditA).call(abi.encodeWithSignature(sig, user, amount));
    }

    function test_token_enter() public {
        token.mint(20 ether);
        token.approve(address(vaultA), 20 ether);
        assertTrue(try_enter_token(address(this), 10 ether));
        assertEq(codex.balances(address(vaultA), tokenId, me), 10 ether);
        assertTrue(try_lock(address(vaultA)));
        assertTrue(!try_enter_token(address(this), 10 ether));
        assertEq(codex.balances(address(vaultA), tokenId, me), 10 ether);
    }

    function test_credit_exit() public {
        address position = address(this);
        codex.mint(address(this), 100 ether);
        codex.grantDelegate(address(creditA));
        assertTrue(try_exit_credit(position, 40 ether));
        assertEq(credit.balanceOf(address(this)), 40 ether);
        assertEq(codex.credit(me), 60 ether);
        assertTrue(try_lock(address(creditA)));
        assertTrue(!try_exit_credit(position, 40 ether));
        assertEq(credit.balanceOf(address(this)), 40 ether);
        assertEq(codex.credit(me), 60 ether);
    }

    function test_credit_exit_enter() public {
        address position = address(this);
        codex.mint(address(this), 100 ether);
        codex.grantDelegate(address(creditA));
        creditA.exit(position, 60 ether);
        credit.approve(address(creditA), type(uint256).max);
        creditA.enter(position, 30 ether);
        assertEq(credit.balanceOf(address(this)), 30 ether);
        assertEq(codex.credit(me), 70 ether);
    }

    function test_lock_no_access() public {
        vaultA.blockCaller(keccak256("ANY_SIG"), address(this));
        assertTrue(!try_lock(address(vaultA)));
        creditA.blockCaller(keccak256("ANY_SIG"), address(this));
        assertTrue(!try_lock(address(creditA)));
    }
}

contract SurplusTest is Test {
    
    TestCodex codex;
    TestAer aer;
    DSToken gold;
    Publican publican;

    Vault20 vaultA;

    DebtAuction debtAuction;
    SurplusAuction surplusAuction;

    DSToken gov;

    address me;

    function try_modifyCollateralAndDebt(
        address vault,
        uint256 tokenId_,
        int256 collateral_,
        int256 normalDebt_
    ) public returns (bool ok) {
        string memory sig = "modifyCollateralAndDebt(bytes32,address,address,address,int256,int256)";
        address self = address(this);
        (ok, ) = address(codex).call(
            abi.encodeWithSignature(sig, vault, tokenId_, self, self, self, collateral_, normalDebt_)
        );
    }

    function token(
        address vault,
        uint256 tokenId_,
        address user
    ) internal view returns (uint256) {
        return codex.balances(vault, tokenId_, user);
    }

    function collateral(
        address vault,
        uint256 tokenId_,
        address user
    ) internal view returns (uint256) {
        (uint256 collateral_, uint256 normalDebt_) = codex.positions(vault, tokenId_, user);
        normalDebt_;
        return collateral_;
    }

    function normalDebt(
        address vault,
        uint256 tokenId_,
        address user
    ) internal view returns (uint256) {
        (uint256 collateral_, uint256 normalDebt_) = codex.positions(vault, tokenId_, user);
        collateral_;
        return normalDebt_;
    }

    function setUp() public {
        vm.warp(604411200);

        gov = new DSToken("GOV");
        gov.mint(100 ether);

        codex = new TestCodex();

        publican = new Publican(address(codex));
        publican.init(address(vaultA));
        publican.setParam("aer", address(aer));
        codex.allowCaller(keccak256("ANY_SIG"), address(publican));

        Collybus collybus = new Collybus();
        collybus.updateSpot(address(gold), 1 ether);

        surplusAuction = new SurplusAuction(address(codex), address(gov));
        debtAuction = new DebtAuction(address(codex), address(gov));

        aer = new TestAer(address(codex), address(surplusAuction), address(debtAuction));
        surplusAuction.allowCaller(keccak256("ANY_SIG"), address(aer));
        debtAuction.allowCaller(keccak256("ANY_SIG"), address(aer));

        gold = new DSToken("TOKEN");
        gold.mint(1000 ether);

        codex.init(address(vaultA));
        vaultA = new Vault20(address(codex), address(gold), address(collybus));
        codex.allowCaller(keccak256("ANY_SIG"), address(vaultA));
        gold.approve(address(vaultA));
        vaultA.enter(0, address(this), 1000 ether);

        codex.setParam(address(vaultA), "debtCeiling", 1000 ether);
        codex.setParam("globalDebtCeiling", 1000 ether);

        codex.allowCaller(keccak256("ANY_SIG"), address(surplusAuction));
        codex.allowCaller(keccak256("ANY_SIG"), address(debtAuction));

        codex.grantDelegate(address(debtAuction));
        gold.approve(address(codex));
        gov.approve(address(surplusAuction));

        me = address(this);
    }

    function test_surplusAuction() public {
        // get some surplus
        codex.mint(address(aer), 100 ether);
        assertEq(codex.credit(address(aer)), 100 ether);
        assertEq(gov.balanceOf(address(this)), 100 ether);

        aer.setParam("surplusAuctionSellSize", 100 ether);
        assertEq(aer.Awe(), 0 ether);
        uint256 id = aer.startSurplusAuction();

        assertEq(codex.credit(address(this)), 0 ether);
        assertEq(gov.balanceOf(address(this)), 100 ether);
        surplusAuction.submitBid(id, 100 ether, 10 ether);
        vm.warp(block.timestamp + 4 hours);
        gov.setOwner(address(surplusAuction));
        surplusAuction.closeAuction(id);
        assertEq(codex.credit(address(this)), 100 ether);
        assertEq(gov.balanceOf(address(this)), 90 ether);
    }
}

contract ModifyRateTest is Test {
    Codex codex;
    Collybus collybus;
    address vaultA;

    function debt(address vault, address position) internal view returns (uint256) {
        (uint256 collateral_, uint256 normalDebt_) = codex.positions(vault, tokenId, position);
        collateral_;
        (uint256 TotalNormalDebt_, uint256 rate, uint256 debtCeiling, uint256 debtFloor) = codex.vaults(vault);
        TotalNormalDebt_;
        debtCeiling;
        debtFloor;
        return (normalDebt_ * rate) / WAD;
    }

    function collateral(address vault, address position) internal view returns (uint256) {
        (uint256 collateral_, uint256 normalDebt_) = codex.positions(vault, tokenId, position);
        normalDebt_;
        return collateral_;
    }

    function setUp() public {
        codex = new Codex();
        collybus = new Collybus();

        address token = address(new DSToken("GOLD"));
        vaultA = address(new Vault20(address(codex), token, address(collybus)));

        collybus.setParam(address(vaultA), "liquidationRatio", 1 ether);

        codex.init(address(vaultA));
        codex.setParam("globalDebtCeiling", 100 ether);
        codex.setParam(address(vaultA), "debtCeiling", 100 ether);
    }

    function createDebt(address vault, uint256 credit) internal {
        codex.setParam("globalDebtCeiling", credit);
        codex.setParam(vault, "debtCeiling", credit);
        collybus.updateSpot(address(IVault(vault).token()), 10000 ether);
        address self = address(this);
        codex.modifyBalance(vault, tokenId, self, 1 ether);
        codex.modifyCollateralAndDebt(vault, tokenId, self, self, self, int256(1 ether), int256(credit));
    }

    function test_modifyRate() public {
        address self = address(this);
        address ali = address(bytes20("ali"));
        createDebt(address(vaultA), 1 ether);

        assertEq(debt(address(vaultA), self), 1.00 ether);
        codex.modifyRate(address(vaultA), ali, int256(0.05 ether));
        assertEq(debt(address(vaultA), self), 1.05 ether);
        assertEq(codex.credit(ali), 0.05 ether);
    }
}
