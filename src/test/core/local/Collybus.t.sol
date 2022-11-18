// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {Collybus} from "../../../core/Collybus.sol";
import {WAD} from "../../../core/utils/Math.sol";

contract CollybusTest is Test {
    Collybus collybus;
    address vault = address(uint160(uint256(keccak256("Vault"))));
    address underlier = address(uint160(uint256(keccak256("underlier"))));
    uint256 tokenId = 1;
    uint128 rateId = 3;
    address me = address(this);

    // helper
    function readWith(
        uint256 ttm,
        bool net,
        uint256 spot,
        uint256 rate
    ) internal returns (uint256) {
        collybus.updateDiscountRate(rateId, rate);
        collybus.updateSpot(underlier, spot);
        return collybus.read(vault, underlier, tokenId, block.timestamp + ttm, net);
    }

    // assert result matches up to 9 decimal points
    function assertTol(uint256 x, uint256 y) internal {
        uint256 tolerance = 1000000000;
        uint256 diff;
        if (x >= y) {
            diff = x - y;
        } else {
            diff = y - x;
        }
        assertTrue(diff <= tolerance);
    }

    function setUp() public {
        collybus = new Collybus();
        collybus.setParam(vault, "liquidationRatio", uint128(11e17));
        collybus.setParam(vault, "defaultRateId", 1);
        collybus.setParam(vault, tokenId, "rateId", rateId);
        collybus.updateSpot(underlier, 1e18);
        collybus.updateDiscountRate(1, 0);
    }

    function test_updateLiquidationRatio() public {
        collybus.setParam(vault, "liquidationRatio", 1);
        (uint256 liquidationRatio, ) = collybus.vaults(vault);
        assertEq(liquidationRatio, 1);
    }

    function test_updateDefaultRateId() public {
        collybus.setParam(vault, "defaultRateId", 2);
        (, uint256 defaultRateId) = collybus.vaults(vault);
        assertEq(defaultRateId, 2);
    }

    function test_updateDefaultRate() public {
        // default rate is 0.0
        assertEq(collybus.read(vault, underlier, 4, block.timestamp + 15634800, false), 1e18);

        // default rate is > 0.0
        collybus.setParam(vault, "defaultRateId", 3);
        collybus.updateDiscountRate(3, 315306960);
        assertLt(collybus.read(vault, underlier, 4, block.timestamp + 15634800, false), 1e18);
    }

    function test_updateSpot() public {
        collybus.updateSpot(underlier, 101e16);
        assertEq(collybus.spots(underlier), 101e16);
    }

    function test_updateDiscountRate() public {
        collybus.updateDiscountRate(rateId, 315306960);
        assertEq(collybus.rates(rateId), 315306960);
    }

    function testFail_updateDiscountRate_invalidRateId() public {
        collybus.updateDiscountRate(type(uint128).max + 1, 315306960);
    }

    function testFail_updateDiscountRate_invalidRate() public {
        collybus.updateDiscountRate(rateId, 2e10);
    }

    function test_readNoDiscounting() public {
        assertEq(readWith(0, false, 900000000000000000, 0), 900000000000000000);
        assertEq(readWith(0, false, 900000000000000000, 315306960), 900000000000000000);
        assertEq(readWith(0, false, 990000000000000000, 0), 990000000000000000);
        assertEq(readWith(0, false, 990000000000000000, 3020197350), 990000000000000000);
        assertEq(readWith(0, false, 1000000000000000000, 0), 1000000000000000000);
        assertEq(readWith(0, false, 1000000000000000000, 315306960), 1000000000000000000);
        assertEq(readWith(0, false, 1010000000000000000, 0), 1010000000000000000);
        assertEq(readWith(0, false, 1010000000000000000, 3020197350), 1010000000000000000);
        assertEq(readWith(0, false, 1100000000000000000, 0), 1100000000000000000);
        assertEq(readWith(0, false, 1100000000000000000, 315306960), 1100000000000000000);
        assertEq(readWith(0, true, 900000000000000000, 0), 818181818181818181);
        assertEq(readWith(0, true, 900000000000000000, 3020197350), 818181818181818181);
        assertEq(readWith(0, true, 990000000000000000, 0), 900000000000000000);
        assertEq(readWith(0, true, 990000000000000000, 315306960), 900000000000000000);
        assertEq(readWith(0, true, 1000000000000000000, 0), 909090909090909090);
        assertEq(readWith(0, true, 1000000000000000000, 3020197350), 909090909090909090);
        assertEq(readWith(0, true, 1010000000000000000, 0), 918181818181818181);
        assertEq(readWith(0, true, 1010000000000000000, 315306960), 918181818181818181);
        assertEq(readWith(0, true, 1100000000000000000, 0), 1000000000000000000);
        assertEq(readWith(0, true, 1100000000000000000, 3020197350), 1000000000000000000);
        assertEq(readWith(15634800, false, 900000000000000000, 0), 900000000000000000);
        assertEq(readWith(15634800, false, 990000000000000000, 0), 990000000000000000);
        assertEq(readWith(15634800, false, 1000000000000000000, 0), 1000000000000000000);
        assertEq(readWith(15634800, false, 1010000000000000000, 0), 1010000000000000000);
        assertEq(readWith(15634800, false, 1100000000000000000, 0), 1100000000000000000);
    }

    function test_readDiscounting() public {
        assertTol(readWith(15634800, false, 900000000000000000, 315306960), 895574133205322071);
        assertTol(readWith(15634800, true, 900000000000000000, 315306960), 814158302913929155);
        assertTol(readWith(15634800, false, 900000000000000000, 3020197350), 858489613526599472);
        assertTol(readWith(15634800, true, 900000000000000000, 3020197350), 780445103205999520);
        assertTol(readWith(15634800, false, 990000000000000000, 315306960), 985131546525854278);
        assertTol(readWith(15634800, true, 990000000000000000, 315306960), 895574133205322070);
        assertTol(readWith(15634800, false, 990000000000000000, 3020197350), 944338574879259419);
        assertTol(readWith(15634800, true, 990000000000000000, 3020197350), 858489613526599471);
        assertTol(readWith(15634800, false, 1000000000000000000, 315306960), 995082370228135634);
        assertTol(readWith(15634800, true, 1000000000000000000, 315306960), 904620336571032394);
        assertTol(readWith(15634800, false, 1000000000000000000, 3020197350), 953877348362888302);
        assertTol(readWith(15634800, true, 1000000000000000000, 3020197350), 867161225784443910);
        assertTol(readWith(15634800, false, 1010000000000000000, 315306960), 1005033193930416990);
        assertTol(readWith(15634800, true, 1010000000000000000, 315306960), 913666539936742718);
        assertTol(readWith(15634800, false, 1010000000000000000, 3020197350), 963416121846517185);
        assertTol(readWith(15634800, true, 1010000000000000000, 3020197350), 875832838042288350);
        assertTol(readWith(15634800, false, 1100000000000000000, 315306960), 1094590607250949190);
        assertTol(readWith(15634800, true, 1100000000000000000, 315306960), 995082370228135627);
        assertTol(readWith(15634800, false, 1100000000000000000, 3020197350), 1049265083199177130);
        assertTol(readWith(15634800, true, 1100000000000000000, 3020197350), 953877348362888300);
        assertTol(readWith(31557600, false, 1000000000000000000, 315306960), 990099010147937417);
        assertTol(readWith(31557600, true, 1000000000000000000, 315306960), 900090009225397651);
        assertTol(readWith(31557600, false, 1000000000000000000, 3020197350), 909090909141720578);
        assertTol(readWith(31557600, true, 1000000000000000000, 3020197350), 826446281037927798);
    }

    function test_read(
        uint32 rate,
        uint120 spot,
        uint32 maturity
    ) public {
        collybus.updateDiscountRate(rateId, rate);
        collybus.updateSpot(underlier, spot);
        collybus.read(vault, underlier, tokenId, maturity, false);
    }
}
