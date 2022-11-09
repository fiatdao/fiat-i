// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {DSTest} from "ds-test/test.sol";

import {Hevm} from "../utils/Hevm.sol";

import {StairstepExponentialDecrease, ExponentialDecrease, LinearDecrease} from "../../auctions/PriceCalculator.sol";
import {WAD} from "../../utils/Math.sol";

contract CollateralAuctionTest is DSTest {
    Hevm hevm;

    // CHEAT_CODE = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D
    bytes20 constant CHEAT_CODE = bytes20(uint160(uint256(keccak256("hevm cheat code"))));

    uint256 constant startTime = 604411200; // Used to avoid issues with `block.timestamp`

    function setUp() public {
        hevm = Hevm(address(CHEAT_CODE));
        hevm.warp(startTime);
    }

    function assertEqWithinTolerance(uint256 x, uint256 y, uint256 tolerance) internal {
        uint256 diff;
        if (x >= y) {
            diff = x - y;
        } else {
            diff = y - x;
        }
        assertTrue(diff <= tolerance);
    }

    function checkExpDecrease(
        StairstepExponentialDecrease calculator,
        uint256 factor,
        uint256 step,
        uint256 startPrice,
        uint256 startsAt,
        uint256 percentDecrease,
        uint256 testTime,
        uint256 tolerance
    ) public {
        uint256 price;
        uint256 lastPrice;
        uint256 testPrice;

        hevm.warp(startTime);
        calculator.setParam(bytes32("step"), step);
        calculator.setParam(bytes32("factor"), factor);
        price = calculator.price(startPrice, block.timestamp - startsAt);
        assertEq(price, startPrice);

        for (uint256 i = 1; i < testTime; i += 1) {
            hevm.warp(startTime + i);
            lastPrice = price;
            price = calculator.price(startPrice, block.timestamp - startsAt);
            // Stairstep calculation
            if (i % step == 0) {
                testPrice = (lastPrice * percentDecrease) / WAD;
            } else {
                testPrice = lastPrice;
            }
            assertEqWithinTolerance(testPrice, price, tolerance);
        }
    }

    function test_stairstep_exp_decrease() public {
        StairstepExponentialDecrease calculator = new StairstepExponentialDecrease();
        uint256 startsAt = block.timestamp; // Start of auction
        uint256 percentDecrease;
        uint256 step;
        uint256 testTime = 10 minutes;

        /*** Extreme high collateral price ($50m) ***/

        uint256 tolerance = 100000000; // Tolerance scales with price
        uint256 startPrice = 50000000 * WAD;

        // 1.1234567890% decrease every 1 second
        // TODO: Check if there's a cleaner way to do this. I was getting rational_const errors.
        percentDecrease = WAD - 1.1234567890e18 / 100;
        step = 1;
        checkExpDecrease(calculator, percentDecrease, step, startPrice, startsAt, percentDecrease, testTime, tolerance);

        // 2.1234567890% decrease every 1 second
        percentDecrease = WAD - 2.1234567890e18 / 100;
        step = 1;
        checkExpDecrease(calculator, percentDecrease, step, startPrice, startsAt, percentDecrease, testTime, tolerance);

        // 1.1234567890% decrease every 5 seconds
        percentDecrease = WAD - 1.1234567890e18 / 100;
        step = 5;
        checkExpDecrease(calculator, percentDecrease, step, startPrice, startsAt, percentDecrease, testTime, tolerance);

        // 2.1234567890% decrease every 5 seconds
        percentDecrease = WAD - 2.1234567890e18 / 100;
        step = 5;
        checkExpDecrease(calculator, percentDecrease, step, startPrice, startsAt, percentDecrease, testTime, tolerance);

        // 1.1234567890% decrease every 5 minutes
        percentDecrease = WAD - 1.1234567890e18 / 100;
        step = 5 minutes;
        checkExpDecrease(calculator, percentDecrease, step, startPrice, startsAt, percentDecrease, testTime, tolerance);

        /*** Extreme low collateral price ($0.0000001) ***/

        tolerance = 1; // Lowest tolerance is 1e-27
        startPrice = (1 * WAD) / 10000000;

        // 1.1234567890% decrease every 1 second
        percentDecrease = WAD - 1.1234567890e18 / 100;
        step = 1;
        checkExpDecrease(calculator, percentDecrease, step, startPrice, startsAt, percentDecrease, testTime, tolerance);

        // 2.1234567890% decrease every 1 second
        percentDecrease = WAD - 2.1234567890e18 / 100;
        step = 1;
        checkExpDecrease(calculator, percentDecrease, step, startPrice, startsAt, percentDecrease, testTime, tolerance);

        // 1.1234567890% decrease every 5 seconds
        percentDecrease = WAD - 1.1234567890e18 / 100;
        step = 5;
        checkExpDecrease(calculator, percentDecrease, step, startPrice, startsAt, percentDecrease, testTime, tolerance);

        // 2.1234567890% decrease every 5 seconds
        percentDecrease = WAD - 2.1234567890e18 / 100;
        step = 5;
        checkExpDecrease(calculator, percentDecrease, step, startPrice, startsAt, percentDecrease, testTime, tolerance);

        // 1.1234567890% decrease every 5 minutes
        percentDecrease = WAD - 1.1234567890e18 / 100;
        step = 5 minutes;
        checkExpDecrease(calculator, percentDecrease, step, startPrice, startsAt, percentDecrease, testTime, tolerance);
    }

    function test_continuous_exp_decrease() public {
        ExponentialDecrease calculator = new ExponentialDecrease();
        uint256 tHalf = 900;
        uint256 factor = 0.999230132966e18; // ~15 half life, factor ~= e^(ln(1/2)/900)
        calculator.setParam("factor", factor);

        uint256 startPrice = 4000 * WAD;
        uint256 expectedPrice = startPrice;
        uint256 tolerance = WAD / 1000; // 0.001, i.e 0.1%
        for (uint256 i = 0; i < 5; i++) {
            // will cover initial value + four half-lives
            assertEqWithinTolerance(calculator.price(startPrice, i * tHalf), expectedPrice, tolerance);
            // each loop iteration advances one half-life, so expectedPrice decreases by a factor of 2
            expectedPrice /= 2;
        }
    }

    function test_linear_decrease() public {
        hevm.warp(startTime);
        LinearDecrease calculator = new LinearDecrease();
        calculator.setParam(bytes32("duration"), 3600);

        uint256 startPrice = 1000 * WAD;
        uint256 startsAt = block.timestamp; // Start of auction
        uint256 price = calculator.price(startPrice, block.timestamp - startsAt);
        assertEq(price, startPrice);

        hevm.warp(startTime + 360); // 6min in,   1/10 done
        price = calculator.price(startPrice, block.timestamp - startsAt);
        assertEq(price, (1000 - 100) * WAD);

        hevm.warp(startTime + 360 * 2); // 12min in,  2/10 done
        price = calculator.price(startPrice, block.timestamp - startsAt);
        assertEq(price, (1000 - 100 * 2) * WAD);

        hevm.warp(startTime + 360 * 3); // 18min in,  3/10 done
        price = calculator.price(startPrice, block.timestamp - startsAt);
        assertEq(price, (1000 - 100 * 3) * WAD);

        hevm.warp(startTime + 360 * 4); // 24min in,  4/10 done
        price = calculator.price(startPrice, block.timestamp - startsAt);
        assertEq(price, (1000 - 100 * 4) * WAD);

        hevm.warp(startTime + 360 * 5); // 30min in,  5/10 done
        price = calculator.price(startPrice, block.timestamp - startsAt);
        assertEq(price, (1000 - 100 * 5) * WAD);

        hevm.warp(startTime + 360 * 6); // 36min in,  6/10 done
        price = calculator.price(startPrice, block.timestamp - startsAt);
        assertEq(price, (1000 - 100 * 6) * WAD);

        hevm.warp(startTime + 360 * 7); // 42min in,  7/10 done
        price = calculator.price(startPrice, block.timestamp - startsAt);
        assertEq(price, (1000 - 100 * 7) * WAD);

        hevm.warp(startTime + 360 * 8); // 48min in,  8/10 done
        price = calculator.price(startPrice, block.timestamp - startsAt);
        assertEq(price, (1000 - 100 * 8) * WAD);

        hevm.warp(startTime + 360 * 9); // 54min in,  9/10 done
        price = calculator.price(startPrice, block.timestamp - startsAt);
        assertEq(price, (1000 - 100 * 9) * WAD);

        hevm.warp(startTime + 360 * 10); // 60min in, 10/10 done
        price = calculator.price(startPrice, block.timestamp - startsAt);
        assertEq(price, 0);
    }
}
