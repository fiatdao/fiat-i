// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1155Holder} from "openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {Codex} from "../../../core/Codex.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {WAD, add, sub, mul, wmul, wdiv} from "../../../core/utils/Math.sol";

import {TestERC20} from "../../../test/utils/TestERC20.sol";

import {Receiver} from "../local/Vault1155.t.sol";

import {VaultSY, ISmartYield, ISmartYieldController} from "../../../vaults/VaultSY.sol";

contract VaultSY_ModifyPositionCollateralizationTest is Test, ERC1155Holder {
    ISmartYield internal market = ISmartYield(0x673f9488619821aB4f4155FdFFe06f6139De518F); // bb_cDAI
    IERC20 internal underlier = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F); // DAI

    Codex internal codex;
    Collybus internal collybus;
    VaultSY internal vault;

    Receiver internal receiver;

    address internal me = address(this);

    uint256 internal bondId;

    function _mintUnderlier(address to, uint256 amount) internal {
        vm.store(address(underlier), keccak256(abi.encode(address(address(this)), uint256(0))), bytes32(uint256(1)));
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(underlier).call(abi.encodeWithSignature(sig, to, amount));
        assert(ok);
    }

    function _createBond(uint256 amount, uint16 forDays) internal {
        underlier.approve(market.pool(), amount); // comp provider
        market.buyBond(amount, market.bondGain(amount, forDays), block.timestamp, forDays);
        bondId = market.seniorBondId();
        assertTrue(vault.seniorBond().ownerOf(bondId) == address(this));
        vault.seniorBond().approve(address(vault), bondId);
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 13627845);

        codex = new Codex();
        collybus = new Collybus();
        vault = new VaultSY(address(codex), address(collybus), address(market), "");

        receiver = new Receiver();

        codex.setParam("globalDebtCeiling", uint256(1000 ether));
        codex.setParam(address(vault), "debtCeiling", uint256(1000 ether));
        codex.allowCaller(codex.modifyBalance.selector, address(vault));

        vault.setParam("principalFloor", 10e4); // to compensate for rounding errors

        collybus.setParam(address(vault), "liquidationRatio", uint128(WAD));
        collybus.setParam(address(vault), "defaultRateId", 1);

        _mintUnderlier(me, 1000 ether);
        _createBond(1000 ether, 30);
    }

    function test_setup() public {
        assertEq(vault.seniorBond().ownerOf(bondId), me);
    }

    function test_vaultType() public {
        assertEq(vault.vaultType(), bytes32("ERC1155_W721:SY"));
    }

    function test_wrap() public {
        vault.wrap(bondId, me);
        assertEq(vault.seniorBond().ownerOf(bondId), address(vault));
        (uint256 principal, uint256 conversion, uint128 maturity, uint64 owned, uint64 redeemed) = vault.bonds(bondId);
        assertEq(owned, 1);
        assertEq(vault.balanceOf(me, bondId), principal); // = principal + gain
        (uint256 _principal, uint256 _maturity, bool liquidated) = vault.terms(bondId);
        assertEq(principal, _principal);
        assertEq(conversion, WAD);
        assertEq(maturity, _maturity);
        assertEq(owned, 1);
        assertEq(redeemed, 0);
        assertTrue(!liquidated);
    }

    function test_unwrap_whole() public {
        vault.wrap(bondId, me);
        vault.unwrap(bondId, me);
        assertEq(vault.seniorBond().ownerOf(bondId), me);
        (, , , uint64 owned, ) = vault.bonds(bondId);
        assertEq(owned, 0);
        assertEq(vault.balanceOf(me, bondId), 0);
    }

    function testFail_unwrap_whole_not_owning_total_supply() public {
        vault.wrap(bondId, me);
        vault.safeTransferFrom(me, address(0), bondId, 1, new bytes(0));
        vault.unwrap(bondId, me);
    }

    function test_unwrap_amount() public {
        vault.wrap(bondId, me);
        (uint256 principal, , uint128 maturity, , ) = vault.bonds(bondId);
        vm.roll(block.number + 2102400); // accrue block based interest
        vm.warp(maturity); // mature bond
        // principal
        uint256 unwraps = vault.unwraps(bondId, wdiv(principal, mul(2, WAD)));
        vault.unwrap(bondId, me, wdiv(principal, mul(2, WAD)));
        assertEq(vault.balanceOf(me, bondId), wdiv(principal, mul(2, WAD)));
        assertEq(underlier.balanceOf(me), wdiv(principal, mul(2, WAD)));
        assertEq(unwraps, underlier.balanceOf(me));
        assertEq(underlier.balanceOf(address(vault)), wdiv(principal, mul(2, WAD)));
        // gain
        vault.unwrap(bondId, me, wdiv(principal, mul(2, WAD)));
        assertEq(vault.balanceOf(me, bondId), 0);
        assertEq(underlier.balanceOf(me), principal);
        assertEq(underlier.balanceOf(address(vault)), 0);
    }

    function test_unwrap_amount_principal_increases() public {
        vault.wrap(bondId, me);

        ISmartYieldController controller = ISmartYieldController(vault.market().controller());
        uint256 fee = controller.FEE_REDEEM_SENIOR_BOND();

        // decrease fee
        (uint256 prePrincipal, uint256 preConversion, uint128 maturity, , ) = vault.bonds(bondId);
        vm.store(address(controller), bytes32(uint256(9)), bytes32(uint256(wdiv(fee, mul(2, WAD)))));
        vault.updateBond(bondId);
        (uint256 principal, uint256 conversion, , , ) = vault.bonds(bondId);
        assertGt(principal, prePrincipal);
        assertGt(conversion, preConversion);

        // unwrap half
        vm.roll(block.number + 2102400); // accrue block based interest
        vm.warp(maturity); // mature bond
        uint256 preBalance = vault.balanceOf(me, bondId);
        vault.unwrap(bondId, me, wdiv(preBalance, mul(2, WAD)));
        assertEq(vault.balanceOf(me, bondId), wdiv(preBalance, mul(2, WAD)));
        assertEq(wmul(underlier.balanceOf(me), uint256(1e14)), wmul(wdiv(principal, mul(2, WAD)), uint256(1e14))); // rounding
        assertEq(
            wmul(underlier.balanceOf(address(vault)), uint256(1e14)),
            wmul(wdiv(principal, mul(2, WAD)), uint256(1e14))
        ); // rounding

        // // unwrap remaining half
        uint256 preBalanceMe = underlier.balanceOf(me);
        uint256 preBalanceVault = underlier.balanceOf(address(vault));
        vault.unwrap(bondId, me, vault.balanceOf(me, bondId));
        assertEq(vault.balanceOf(me, bondId), 0);
        assertEq(underlier.balanceOf(me), add(preBalanceMe, preBalanceVault));
        assertEq(underlier.balanceOf(address(vault)), 0);
    }

    function test_unwrap_amount_principal_decreases() public {
        vault.wrap(bondId, me);

        ISmartYieldController controller = ISmartYieldController(vault.market().controller());
        uint256 fee = controller.FEE_REDEEM_SENIOR_BOND();

        // increases fee
        (uint256 prePrincipal, uint256 preConversion, uint128 maturity, , ) = vault.bonds(bondId);
        vm.store(address(controller), bytes32(uint256(9)), bytes32(uint256(wmul(fee, mul(2, WAD)))));
        vault.updateBond(bondId);
        (uint256 principal, uint256 conversion, , , ) = vault.bonds(bondId);
        assertLt(principal, prePrincipal);
        assertLt(conversion, preConversion);

        // unwrap half
        vm.roll(block.number + 2102400); // accrue block based interest
        vm.warp(maturity); // mature bond
        uint256 preBalance = vault.balanceOf(me, bondId);
        vault.unwrap(bondId, me, wdiv(preBalance, mul(2, WAD)));
        assertEq(vault.balanceOf(me, bondId), wdiv(preBalance, mul(2, WAD)));
        assertEq(wmul(underlier.balanceOf(me), uint256(1e14)), wmul(wdiv(principal, mul(2, WAD)), uint256(1e14))); // rounding
        assertEq(
            wmul(underlier.balanceOf(address(vault)), uint256(1e14)),
            wmul(wdiv(principal, mul(2, WAD)), uint256(1e14))
        ); // rounding

        // // unwrap remaining half
        uint256 preBalanceMe = underlier.balanceOf(me);
        uint256 preBalanceVault = underlier.balanceOf(address(vault));
        vault.unwrap(bondId, me, vault.balanceOf(me, bondId));
        assertEq(vault.balanceOf(me, bondId), 0);
        assertEq(underlier.balanceOf(me), add(preBalanceMe, preBalanceVault));
        assertEq(underlier.balanceOf(address(vault)), 0);
    }

    function testFail_unwrap_amount_not_matured() public {
        vault.wrap(bondId, me);
        (uint256 principal, , , , ) = vault.bonds(bondId);
        vm.roll(block.number + 2102400); // accrue block based interest
        vault.unwrap(bondId, me, principal);
    }

    function testFail_unwrap_amount_notOwned() public {
        vault.unwrap(123, me, 0);
    }

    function testFail_unwrap_amount_insufficient_balance() public {
        vault.wrap(bondId, me);
        (uint256 principal, , uint128 maturity, , ) = vault.bonds(bondId);
        vm.roll(block.number + 2102400); // accrue block based interest
        vm.warp(maturity); // mature bond
        vault.safeTransferFrom(me, address(0), bondId, vault.balanceOf(me, bondId), new bytes(0));
        vault.unwrap(bondId, me, principal);
    }

    function test_enter() public {
        uint256 amount = vault.wrap(bondId, me);
        vault.setApprovalForAll(address(vault), true);
        vault.enter(bondId, address(this), amount);
        assertEq(codex.balances(address(vault), bondId, me), amount);
    }

    function test_exit() public {
        uint256 amount = vault.wrap(bondId, me);
        vault.setApprovalForAll(address(vault), true);
        vault.enter(bondId, address(this), amount);
        vault.exit(bondId, address(this), amount);
        assertEq(codex.balances(address(vault), bondId, me), 0);
        assertEq(vault.balanceOf(me, bondId), amount);
    }

    function test_fairPrice_face() public {
        collybus.updateSpot(vault.underlierToken(), WAD);
        collybus.updateDiscountRate(1, 0);
        uint256 amount = vault.wrap(bondId, me);
        vault.setApprovalForAll(address(vault), true);
        vault.enter(bondId, address(this), amount);
        assertEq(vault.fairPrice(bondId, true, true), WAD);
    }

    function test_fairPrice_no_face() public {
        collybus.updateSpot(vault.underlierToken(), WAD);
        collybus.updateDiscountRate(1, 1e10);
        uint256 amount = vault.wrap(bondId, me);
        vault.setApprovalForAll(address(vault), true);
        vault.enter(bondId, address(this), amount);
        assertEq(vault.fairPrice(bondId, true, false), 974413039660163047);
    }

    uint256 constant MAX_DECIMALS = 38; // ~type(int256).max ~= 1e18*1e18
    uint256 constant MAX_AMOUNT = 10**(MAX_DECIMALS);

    function test_enter_transfersTokens_to_vault(
        uint256 tokenId,
        address owner,
        uint256 amount
    ) public {
        if (amount >= MAX_AMOUNT) return;

        vault.setApprovalForAll(address(vault), true);

        vm.store(
            address(vault),
            keccak256(abi.encode(me, keccak256(abi.encode(tokenId, uint256(1))))),
            bytes32(amount)
        );

        vault.enter(tokenId, owner, amount);

        assertEq(vault.balanceOf(address(this), tokenId), 0);
        assertEq(vault.balanceOf(address(vault), tokenId), amount);
    }

    function test_exit_transfers_tokens(uint256 tokenId, uint256 amount) public {
        if (amount >= MAX_AMOUNT) return;

        vault.setApprovalForAll(address(vault), true);
        vm.store(
            address(vault),
            keccak256(abi.encode(me, keccak256(abi.encode(tokenId, uint256(1))))),
            bytes32(amount)
        );

        vault.enter(tokenId, me, amount);
        vault.exit(tokenId, address(receiver), amount);

        assertEq(vault.balanceOf(address(receiver), tokenId), amount);
        assertEq(vault.balanceOf(address(vault), tokenId), 0);
    }
}
