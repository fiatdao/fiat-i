// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {DSToken} from "../../utils/dapphub/DSToken.sol";

import {ICodex} from "../../../interfaces/ICodex.sol";

import {Codex} from "../../../core/Codex.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {WAD, wpow} from "../../../core/utils/Math.sol";
import {Publican} from "../../../core/Publican.sol";
import {Vault20} from "../../../vaults/Vault.sol";

contract Wpow is Publican {
    constructor(address codex_) Publican(codex_) {}

    function pWpow(
        uint256 x,
        uint256 n,
        uint256 b
    ) public pure returns (uint256) {
        return wpow(x, n, b);
    }
}

contract PublicanTest is Test {
    Codex codex;
    Collybus collybus;
    Vault20 vaultA;
    Publican publican;

    function assertEqPrecision(
        uint256 a,
        uint256 b,
        uint256 scale
    ) internal {
        assertEq((a * scale) / WAD, (b * scale) / WAD);
    }

    function lastCollected(address vault) internal view returns (uint256) {
        (uint256 interestPerSecond, uint256 lastCollected_) = publican.vaults(vault);
        interestPerSecond;
        return lastCollected_;
    }

    function totalNormalDebt(address vault) internal view returns (uint256 totalNormalDebt_) {
        (totalNormalDebt_, , , ) = ICodex(address(codex)).vaults(vault);
    }

    function rate(address vault) internal view returns (uint256 rate_) {
        (, rate_, , ) = ICodex(address(codex)).vaults(vault);
    }

    function debtCeiling(address vault) internal view returns (uint256 debtCeiling_) {
        (, , debtCeiling_, ) = ICodex(address(codex)).vaults(vault);
    }

    address ali = address(bytes20("ali"));

    function setUp() public {
        vm.warp(604411200);

        codex = new Codex();
        collybus = new Collybus();
        publican = new Publican(address(codex));

        address token = address(new DSToken("GOLD"));
        vaultA = new Vault20(address(codex), token, address(collybus));

        collybus.setParam(address(vaultA), "liquidationRatio", 1 ether);

        codex.allowCaller(keccak256("ANY_SIG"), address(publican));
        codex.init(address(vaultA));

        createDebt(address(vaultA), 100 ether);
    }

    function createDebt(address vault, uint256 credit) internal {
        codex.setParam("globalDebtCeiling", codex.globalDebtCeiling() + credit);
        codex.setParam(vault, "debtCeiling", debtCeiling(vault) + credit);
        collybus.updateSpot(address(Vault20(vault).token()), WAD * 10000 ether);
        address self = address(this);
        codex.modifyBalance(vault, 0, self, int256(WAD * 1 ether));
        codex.modifyCollateralAndDebt(vault, 0, self, self, self, int256(1 ether), int256(credit));
    }

    function test_collect_setup() public {
        vm.warp(0);
        assertEq(uint256(block.timestamp), 0);
        vm.warp(1);
        assertEq(uint256(block.timestamp), 1);
        vm.warp(2);
        assertEq(uint256(block.timestamp), 2);
        assertEq(totalNormalDebt(address(vaultA)), 100 ether);
    }

    function test_collect_updates_lastCollected() public {
        publican.init(address(vaultA));
        assertEq(lastCollected(address(vaultA)), block.timestamp);

        publican.setParam(address(vaultA), "interestPerSecond", WAD);
        publican.collect(address(vaultA));
        assertEq(lastCollected(address(vaultA)), block.timestamp);
        vm.warp(block.timestamp + 1);
        assertEq(lastCollected(address(vaultA)), block.timestamp - 1);
        publican.collect(address(vaultA));
        assertEq(lastCollected(address(vaultA)), block.timestamp);
        vm.warp(block.timestamp + 1 days);
        publican.collect(address(vaultA));
        assertEq(lastCollected(address(vaultA)), block.timestamp);
    }

    function test_collect_setParam() public {
        publican.init(address(vaultA));
        publican.setParam(address(vaultA), "interestPerSecond", WAD);
        publican.collect(address(vaultA));
        publican.setParam(address(vaultA), "interestPerSecond", 1000000564701133626); // 5% / day
    }

    function test_collect_0d() public {
        publican.init(address(vaultA));
        publican.setParam(address(vaultA), "interestPerSecond", 1000000564701133626); // 5% / day
        assertEq(codex.credit(ali), 0);
        publican.collect(address(vaultA));
        assertEq(codex.credit(ali), 0);
    }

    function test_collect_1d() public {
        publican.init(address(vaultA));
        publican.setParam("aer", ali);

        publican.setParam(address(vaultA), "interestPerSecond", 1000000564701133626); // 5% / day
        vm.warp(block.timestamp + 1 days);
        assertEq(codex.credit(ali), 0 ether);
        uint256 ratePreview = publican.virtualRate(address(vaultA));
        publican.collect(address(vaultA));
        (, uint256 newRate, , ) = codex.vaults(address(vaultA));
        assertEq(ratePreview, newRate);
        assertEqPrecision(codex.credit(ali), 5 ether - 1, 1e10);
    }

    function test_collect_1d_many() public {
        address token = address(new DSToken("SILVER"));
        Vault20 vaultB = new Vault20(address(codex), token, address(collybus));
        codex.init(address(vaultB));
        collybus.setParam(address(vaultB), "liquidationRatio", 1 ether);

        createDebt(address(vaultB), 100 ether);

        publican.init(address(vaultA));
        publican.init(address(vaultB));
        publican.setParam("aer", ali);

        publican.setParam(address(vaultA), "interestPerSecond", 1050000000000000000); // 5% / second
        publican.setParam(address(vaultB), "interestPerSecond", 1000000000000000000); // 0% / second
        publican.setParam("baseInterest", uint256(50000000000000000)); // 5% / second
        vm.warp(block.timestamp + 1);

        address[] memory vaults = new address[](2);
        vaults[0] = address(vaultA);
        vaults[1] = address(vaultB);
        publican.collectMany(vaults);
        assertEq(codex.credit(ali), 15 ether); // 10% for vaultA, 5% for vaultB
    }

    function test_collect_2d() public {
        publican.init(address(vaultA));
        publican.setParam("aer", ali);
        publican.setParam(address(vaultA), "interestPerSecond", 1000000564701133626); // 5% / day

        vm.warp(block.timestamp + 2 days);
        assertEq(codex.credit(ali), 0 ether);
        uint256 ratePreview = publican.virtualRate(address(vaultA));
        publican.collect(address(vaultA));
        (, uint256 newRate, , ) = codex.vaults(address(vaultA));
        assertEq(ratePreview, newRate);
        assertEqPrecision(codex.credit(ali), 10.25 ether - 1, 1e10);
    }

    function test_collect_3d() public {
        publican.init(address(vaultA));
        publican.setParam("aer", ali);

        publican.setParam(address(vaultA), "interestPerSecond", 1000000564701133626); // 5% / day
        vm.warp(block.timestamp + 3 days);
        assertEq(codex.credit(ali), 0 ether);
        uint256 ratePreview = publican.virtualRate(address(vaultA));
        publican.collect(address(vaultA));
        (, uint256 newRate, , ) = codex.vaults(address(vaultA));
        assertEq(ratePreview, newRate);
        assertEqPrecision(codex.credit(ali), 15.7625 ether - 1, 1e10);
    }

    function test_collect_negative_3d() public {
        publican.init(address(vaultA));
        publican.setParam("aer", ali);

        publican.setParam(address(vaultA), "interestPerSecond", 999999706969857929); // -2.5% / day
        vm.warp(block.timestamp + 3 days);
        assertEq(codex.credit(address(this)), 100 ether);
        codex.transferCredit(address(this), ali, 100 ether);
        assertEq(codex.credit(ali), 100 ether);
        uint256 ratePreview = publican.virtualRate(address(vaultA));
        publican.collect(address(vaultA));
        (, uint256 newRate, , ) = codex.vaults(address(vaultA));
        assertEq(ratePreview, newRate);
        assertEqPrecision(codex.credit(ali), 92.6859375 ether - 1, 1e10);
    }

    function test_collect_multi() public {
        publican.init(address(vaultA));
        publican.setParam("aer", ali);

        publican.setParam(address(vaultA), "interestPerSecond", 1000000564701133626); // 5% / day
        vm.warp(block.timestamp + 1 days);
        publican.collect(address(vaultA));
        assertEqPrecision(codex.credit(ali), 5 ether - 1, 1e10);
        publican.setParam(address(vaultA), "interestPerSecond", 1000001103127689513); // 10% / day
        vm.warp(block.timestamp + 1 days);
        publican.collect(address(vaultA));
        assertEqPrecision(codex.credit(ali), 15.5 ether - 1, 1e10);
        assertEqPrecision(codex.globalDebt(), 115.5 ether - 1, 1e10);
        assertEqPrecision(rate(address(vaultA)), 1.155 ether - 1, 1e10);
    }

    function test_collect_baseInterest() public {
        address token = address(new DSToken("SILVER"));
        Vault20 vaultB = new Vault20(address(codex), token, address(collybus));
        codex.init(address(vaultB));
        collybus.setParam(address(vaultB), "liquidationRatio", 1 ether);

        createDebt(address(vaultB), 100 ether);

        publican.init(address(vaultA));
        publican.init(address(vaultB));
        publican.setParam("aer", ali);

        publican.setParam(address(vaultA), "interestPerSecond", 1050000000000000000); // 5% / second
        publican.setParam(address(vaultB), "interestPerSecond", 1000000000000000000); // 0% / second
        publican.setParam("baseInterest", uint256(50000000000000000)); // 5% / second
        vm.warp(block.timestamp + 1);
        publican.collect(address(vaultA));
        assertEq(codex.credit(ali), 10 ether);
    }

    function test_setParam_interestPerSecond() public {
        publican.init(address(vaultA));
        vm.warp(block.timestamp + 1);
        publican.collect(address(vaultA));
        publican.setParam(address(vaultA), "interestPerSecond", 1);
    }

    function testFail_setParam_interestPerSecond() public {
        publican.init(address(vaultA));
        vm.warp(block.timestamp + 1);
        publican.setParam(address(vaultA), "interestPerSecond", 1);
    }

    function test_wpow() public {
        Wpow r = new Wpow(address(codex));
        uint256 result = r.pWpow(uint256(1000234891009084238), uint256(3724), WAD);
        // python calculator = 2.397991232255757e27 = 2397991232255757e12
        // expect 10 decimal precision
        assertEq((result * 1e10) / WAD, (uint256(2397991232255757) * 1e13) / WAD);
    }
}
