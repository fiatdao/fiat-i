// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {DSToken} from "../../utils/dapphub/DSToken.sol";

import {Codex} from "../../../core/Codex.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {Limes} from "../../../core/Limes.sol";
import {WAD} from "../../../core/utils/Math.sol";
import {Vault20} from "../../../vaults/Vault.sol";

uint256 constant tokenId = 0;

contract AerMock {
    function queueDebt(uint256 due) public {}
}

contract CollateralAuctionMock {
    struct VaultConfig {
        uint256 multiplier;
        uint256 maxAuctionDuration;
        uint256 maxDiscount;
        uint256 auctionDebtFloor;
        address collybus;
        address calculator;
    }

    mapping(address => VaultConfig) public vaults; // Vault collateral auction configs

    function init(address vault, address collybus) external {
        vaults[vault].collybus = collybus;
    }

    function startAuction(
        uint256,
        uint256,
        address,
        uint256,
        address,
        address
    ) external pure returns (uint256 id) {
        id = 42;
    }
}

contract LimesTest is Test {
    address constant user = address(1337);
    uint256 constant THOUSAND = 1E3;
    address vault;
    Codex codex;
    Collybus collybus;
    AerMock aer;
    CollateralAuctionMock collateralAuction;
    Limes limes;

    function setUp() public {
        codex = new Codex();
        collybus = new Collybus();
        vault = address(new Vault20(address(codex), address(new DSToken("GOLD")), address(collybus)));
        codex.init(vault);
        collybus.updateSpot(address(Vault20(vault).token()), THOUSAND * WAD);
        collybus.setParam(vault, "liquidationRatio", 1 ether);
        codex.setParam(vault, "debtFloor", 100 * WAD);
        aer = new AerMock();
        collateralAuction = new CollateralAuctionMock();
        collateralAuction.init(vault, address(1));
        limes = new Limes(address(codex));
        codex.allowCaller(keccak256("ANY_SIG"), address(limes));
        limes.setParam(vault, "liquidationPenalty", (11 * WAD) / 10);
        limes.setParam("aer", address(aer));
        limes.setParam(vault, "collateralAuction", address(collateralAuction));
        limes.setParam("globalMaxDebtOnAuction", 10 * THOUSAND * WAD);
        limes.setParam(vault, "maxDebtOnAuction", 10 * THOUSAND * WAD);
    }

    function test_setParam_liquidationPenalty() public {
        limes.setParam(vault, "liquidationPenalty", WAD);
        limes.setParam(vault, "liquidationPenalty", (WAD * 113) / 100);
    }

    function testFail_setParam_liquidationPenalty_lt_WAD() public {
        limes.setParam(vault, "liquidationPenalty", WAD - 1);
    }

    function testFail_setParam_liquidationPenalty_eq_zero() public {
        limes.setParam(vault, "liquidationPenalty", 0);
    }

    // function testFail_setParam_collateralAuction_wrong_vault() public {
    //     limes.setParam(
    //         address(uint160(uint256(keccak256("mismatched_vault")))),
    //         "collateralAuction",
    //         address(collateralAuction)
    //     );
    // }

    function setPosition(uint256 collateral, uint256 normalDebt) internal {
        codex.modifyBalance(vault, tokenId, user, int256(collateral));
        (, uint256 rate, , ) = codex.vaults(vault);
        codex.createUnbackedDebt(address(aer), address(aer), (normalDebt * rate) / WAD);
        codex.confiscateCollateralAndDebt(
            vault,
            tokenId,
            user,
            user,
            address(aer),
            int256(collateral),
            int256(normalDebt)
        );
        (uint256 actualCollateral, uint256 actualNormalDebt) = codex.positions(vault, tokenId, user);
        assertEq(collateral, actualCollateral);
        assertEq(normalDebt, actualNormalDebt);
    }

    function isDusty() internal view returns (bool dusty) {
        (, uint256 rate, , uint256 debtFloor) = codex.vaults(vault);
        (, uint256 normalDebt) = codex.positions(vault, tokenId, user);
        uint256 due = (normalDebt * rate) / WAD;
        dusty = due > 0 && due < debtFloor;
    }

    function test_liquidate_basic() public {
        setPosition(WAD, 2 * THOUSAND * WAD);
        limes.liquidate(vault, tokenId, user, address(this));
        (uint256 collateral, uint256 normalDebt) = codex.positions(vault, tokenId, user);
        assertEq(collateral, 0);
        assertEq(normalDebt, 0);
    }

    function testFail_liquidate_not_unsafe() public {
        setPosition(WAD, 500 * WAD);
        limes.liquidate(vault, tokenId, user, address(this));
    }

    // limes.liquidate will liquidate vaults even if they are dusty
    function test_liquidate_dusty_vault() public {
        uint256 debtFloor = 200;
        codex.setParam(vault, "debtFloor", debtFloor * WAD);
        setPosition(1, (debtFloor / 2) * WAD);
        assertTrue(isDusty());
        limes.liquidate(vault, tokenId, user, address(this));
    }

    function test_liquidate_partial_liquidation_debtOnAuction_exceeds_maxDebtOnAuction_to_avoid_dusty_remnant() public {
        uint256 debtFloor = 200;
        codex.setParam(vault, "debtFloor", debtFloor * WAD);
        uint256 maxDebtOnAuction = 5 * THOUSAND;
        limes.setParam(vault, "maxDebtOnAuction", maxDebtOnAuction * WAD);
        (, uint256 liquidationPenalty, , ) = limes.vaults(vault);
        uint256 normalDebtStart = (maxDebtOnAuction * WAD * WAD) / liquidationPenalty + debtFloor * WAD - 1;
        setPosition(WAD, normalDebtStart);
        limes.liquidate(vault, tokenId, user, address(this));
        assertTrue(!isDusty());
        (, uint256 normalDebt) = codex.positions(vault, tokenId, user);

        // The full vault has been liquidated so as not to leave a dusty remnant,
        // at the expense of slightly exceeding maxDebtOnAuction.
        assertEq(normalDebt, 0);
        (, , , uint256 debtOnAuction) = limes.vaults(vault);
        assertTrue(debtOnAuction > maxDebtOnAuction * WAD);
        assertEq(debtOnAuction, (normalDebtStart * liquidationPenalty) / WAD);
    }

    function test_liquidate_partial_liquidation_debtOnAuction_does_not_exceed_maxDebtOnAuction_if_remnant_is_nondusty()
        public
    {
        uint256 debtFloor = 200;
        codex.setParam(vault, "debtFloor", debtFloor * WAD);
        uint256 maxDebtOnAuction = 5 * THOUSAND;
        limes.setParam(vault, "maxDebtOnAuction", maxDebtOnAuction * WAD);
        (, uint256 liquidationPenalty, , ) = limes.vaults(vault);
        setPosition(WAD, (maxDebtOnAuction * WAD * WAD) / liquidationPenalty + debtFloor * WAD);
        limes.liquidate(vault, tokenId, user, address(this));
        assertTrue(!isDusty());
        (, uint256 normalDebt) = codex.positions(vault, tokenId, user);

        // The vault remnant respects the debtFloor limit, so we don't exceed maxDebtOnAuction to liquidate it.
        assertEq(normalDebt, debtFloor * WAD);
        (, , , uint256 debtOnAuction) = limes.vaults(vault);
        assertTrue(debtOnAuction <= maxDebtOnAuction * WAD);
        assertEq(debtOnAuction, (((maxDebtOnAuction * WAD * WAD) / liquidationPenalty) * liquidationPenalty) / WAD);
    }

    function test_liquidate_partial_liquidation_globalDebtOnAuction_exceeds_globalMaxDebtOnAuction_to_avoid_dusty_remnant()
        public
    {
        uint256 debtFloor = 200;
        codex.setParam(vault, "debtFloor", debtFloor * WAD);
        uint256 globalMaxDebtOnAuction = 5 * THOUSAND;
        limes.setParam("globalMaxDebtOnAuction", globalMaxDebtOnAuction * WAD);
        (, uint256 liquidationPenalty, , ) = limes.vaults(vault);
        uint256 normalDebtStart = (globalMaxDebtOnAuction * WAD * WAD) / liquidationPenalty + debtFloor * WAD - 1;
        setPosition(WAD, normalDebtStart);
        limes.liquidate(vault, tokenId, user, address(this));
        assertTrue(!isDusty());

        // The full vault has been liquidated so as not to leave a dusty remnant,
        // at the expense of slightly exceeding maxDebtOnAuction.
        (, uint256 normalDebt) = codex.positions(vault, tokenId, user);
        assertEq(normalDebt, 0);
        assertTrue(limes.globalDebtOnAuction() > globalMaxDebtOnAuction * WAD);
        assertEq(limes.globalDebtOnAuction(), (normalDebtStart * liquidationPenalty) / WAD);
    }

    function test_liquidate_partial_liquidation_globalDebtOnAuction_does_not_exceed_globalMaxDebtOnAuction_if_remnant_is_nondusty()
        public
    {
        uint256 debtFloor = 200;
        codex.setParam(vault, "debtFloor", debtFloor * WAD);
        uint256 globalMaxDebtOnAuction = 5 * THOUSAND;
        limes.setParam("globalMaxDebtOnAuction", globalMaxDebtOnAuction * WAD);
        (, uint256 liquidationPenalty, , ) = limes.vaults(vault);
        setPosition(WAD, (globalMaxDebtOnAuction * WAD * WAD) / liquidationPenalty + debtFloor * WAD);
        limes.liquidate(vault, tokenId, user, address(this));
        assertTrue(!isDusty());

        // The full vault has been liquidated so as not to leave a dusty remnant,
        // at the expense of slightly exceeding maxDebtOnAuction.
        (, uint256 normalDebt) = codex.positions(vault, tokenId, user);
        assertEq(normalDebt, debtFloor * WAD);
        assertTrue(limes.globalDebtOnAuction() <= globalMaxDebtOnAuction * WAD);
        assertEq(
            limes.globalDebtOnAuction(),
            (((globalMaxDebtOnAuction * WAD * WAD) / liquidationPenalty) * liquidationPenalty) / WAD
        );
    }

    // A previous version reverted if room was dusty, even if the Vault being liquidated
    // was also dusty and would fit in the remaining maxDebtOnAuction/globalMaxDebtOnAuction room.
    function test_liquidate_dusty_vault_dusty_room() public {
        // Use a liquidationPenalty that will give nice round numbers
        uint256 liquidationPenalty = (110 * WAD) / 100; // 10%
        limes.setParam(vault, "liquidationPenalty", liquidationPenalty);

        // set both maxDebtOnAuction_i and globalMaxDebtOnAuction to the same value for this test
        uint256 ROOM = 200;
        uint256 globalMaxDebtOnAuction = 33 * THOUSAND + ROOM;
        limes.setParam("globalMaxDebtOnAuction", globalMaxDebtOnAuction * WAD);
        limes.setParam(vault, "maxDebtOnAuction", globalMaxDebtOnAuction * WAD);

        // Test using a non-zero rate to ensure the code is handling stability fees correctly.
        codex.modifyRate(vault, address(aer), (5 * int256(WAD)) / 10);
        (, uint256 rate, , ) = codex.vaults(vault);
        assertEq(rate, (15 * WAD) / 10);

        // First, make both maxDebtOnAuction is nearly reached.
        setPosition(WAD, ((((globalMaxDebtOnAuction - ROOM) * WAD * WAD) / rate) * WAD) / liquidationPenalty);
        limes.liquidate(vault, tokenId, user, address(this));
        assertEq(globalMaxDebtOnAuction * WAD - limes.globalDebtOnAuction(), ROOM * WAD);
        (, , , uint256 debtOnAuction) = limes.vaults(vault);
        assertEq(globalMaxDebtOnAuction * WAD - debtOnAuction, ROOM * WAD);

        // Create a small vault
        uint256 DebtFloor_1 = 30;
        codex.setParam(vault, "debtFloor", DebtFloor_1 * WAD);
        setPosition(WAD / 10**4, (DebtFloor_1 * WAD * WAD) / rate);

        // Dust limit goes up!
        uint256 DebtFloor_2 = 1500;
        codex.setParam(vault, "debtFloor", DebtFloor_2 * WAD);

        // The testing vault is block.timestamp dusty
        assertTrue(isDusty());

        // In fact, there is only room to create dusty auctions at this point.
        assertTrue(
            limes.globalMaxDebtOnAuction() - limes.globalDebtOnAuction() <
                (DebtFloor_2 * WAD * liquidationPenalty) / WAD
        );
        uint256 maxDebtOnAuction;
        (, , maxDebtOnAuction, debtOnAuction) = limes.vaults(vault);
        assertTrue(maxDebtOnAuction - debtOnAuction < (DebtFloor_2 * WAD * liquidationPenalty) / WAD);

        // But...our Vault is small enough to fit in ROOM
        assertTrue((DebtFloor_1 * WAD * liquidationPenalty) / WAD < ROOM * WAD);

        // liquidate should still succeed
        limes.liquidate(vault, tokenId, user, address(this));
    }

    function try_liquidate(
        address vault_,
        uint256 tokenId_,
        address user_,
        address keeper_
    ) internal returns (bool ok) {
        string memory sig = "liquidate(bytes32,address,address)";
        (ok, ) = address(limes).call(abi.encodeWithSignature(sig, vault_, tokenId_, user_, keeper_));
    }

    function test_liquidate_do_not_create_dusty_auction_maxDebtOnAuction() public {
        uint256 debtFloor = 300;
        codex.setParam(vault, "debtFloor", debtFloor * WAD);
        uint256 maxDebtOnAuction = 3 * THOUSAND;
        limes.setParam(vault, "maxDebtOnAuction", maxDebtOnAuction * WAD);

        // Test using a non-zero rate to ensure the code is handling stability fees correctly.
        codex.modifyRate(vault, address(aer), (5 * int256(WAD)) / 10);
        (, uint256 rate, , ) = codex.vaults(vault);
        assertEq(rate, (15 * WAD) / 10);

        (, uint256 liquidationPenalty, , ) = limes.vaults(vault);
        setPosition(WAD, ((((maxDebtOnAuction - debtFloor / 2) * WAD * WAD) / rate) * WAD) / liquidationPenalty);
        limes.liquidate(vault, tokenId, user, address(this));

        // Make sure any partial liquidation would be dusty (assuming non-dusty remnant)
        (, , , uint256 debtOnAuction) = limes.vaults(vault);
        uint256 room = maxDebtOnAuction * WAD - debtOnAuction;
        uint256 deltaNormalDebt = (room * WAD) / rate / liquidationPenalty;
        assertTrue(deltaNormalDebt * rate < debtFloor * WAD);

        // This will need to be partially liquidated
        setPosition(WAD, (maxDebtOnAuction * WAD * WAD) / liquidationPenalty);
        assertTrue(!try_liquidate(vault, tokenId, user, address(this))); // should revert, as the auction would be dusty
    }

    function test_liquidate_do_not_create_dusty_auction_globalMaxDebtOnAuction() public {
        uint256 debtFloor = 300;
        codex.setParam(vault, "debtFloor", debtFloor * WAD);
        uint256 globalMaxDebtOnAuction = 3 * THOUSAND;
        limes.setParam("globalMaxDebtOnAuction", globalMaxDebtOnAuction * WAD);

        // Test using a non-zero rate to ensure the code is handling stability fees correctly.
        codex.modifyRate(vault, address(aer), (5 * int256(WAD)) / 10);
        (, uint256 rate, , ) = codex.vaults(vault);
        assertEq(rate, (15 * WAD) / 10);

        (, uint256 liquidationPenalty, , ) = limes.vaults(vault);
        setPosition(WAD, ((((globalMaxDebtOnAuction - debtFloor / 2) * WAD * WAD) / rate) * WAD) / liquidationPenalty);
        limes.liquidate(vault, tokenId, user, address(this));

        // Make sure any partial liquidation would be dusty (assuming non-dusty remnant)
        uint256 room = globalMaxDebtOnAuction * WAD - limes.globalDebtOnAuction();
        uint256 deltaNormalDebt = (room * WAD) / rate / liquidationPenalty;
        assertTrue(deltaNormalDebt * rate < debtFloor * WAD);

        // This will need to be partially liquidated
        setPosition(WAD, (globalMaxDebtOnAuction * WAD * WAD) / liquidationPenalty);
        assertTrue(!try_liquidate(vault, tokenId, user, address(this))); // should revert, as the auction would be dusty
    }
}
