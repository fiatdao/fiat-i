// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {DSToken} from "../../../test/utils/dapphub/DSToken.sol";

import {Codex} from "../../../core/Codex.sol";
import {WAD} from "../../../core/utils/Math.sol";

import {CodexGuard} from "../../../guards/CodexGuard.sol";

contract NotSenatus {
    CodexGuard internal codexGuard;

    constructor(CodexGuard codexGuard_) {
        codexGuard = codexGuard_;
    }

    function setDebtCeilingAdjuster(
        address vault,
        uint256 maxDelta,
        uint256 delay
    ) external {
        codexGuard.setDebtCeilingAdjuster(vault, 0, maxDelta, delay);
    }

    function removeDebtCeilingAdjuster(address vault) external {
        codexGuard.removeDebtCeilingAdjuster(vault);
    }
}

contract CodexGuardTest is Test {
    Codex codex;

    CodexGuard codexGuard;

    function setUp() public {
        codex = new Codex();

        codexGuard = new CodexGuard(address(this), address(this), 1, address(codex));
        codex.allowCaller(codex.ANY_SIG(), address(codexGuard));
    }

    function try_call(address addr, bytes memory data) public returns (bool) {
        bytes memory _data = data;
        assembly {
            let ok := call(gas(), addr, 0, add(_data, 0x20), mload(_data), 0, 0)
            let free := mload(0x40)
            mstore(free, ok)
            mstore(0x40, add(free, 32))
            revert(free, 32)
        }
    }

    function can_call(address addr, bytes memory data) public returns (bool) {
        bytes memory call = abi.encodeWithSignature("try_call(address,bytes)", addr, data);
        (bool ok, bytes memory success) = address(this).call(call);
        ok = abi.decode(success, (bool));
        if (ok) return true;
        return false;
    }

    function test_isGuard() public {
        codexGuard.isGuard();

        codex.blockCaller(codex.ANY_SIG(), address(codexGuard));
        assertTrue(!can_call(address(codexGuard), abi.encodeWithSelector(codexGuard.isGuard.selector)));
    }

    function test_setDebtCeilingAdjuster() public {
        codexGuard.setDebtCeilingAdjuster(address(1), 0, 5, 1);

        (uint256 maxDebtCeiling, uint256 maxDelta, uint256 delay, uint256 last, uint256 lastInc) = codexGuard
            .debtCeilingAdjusters(address(1));
        assertEq(maxDebtCeiling, 10_000_000 * WAD);
        assertEq(maxDelta, 5);
        assertEq(delay, 1);
        assertEq(last, 0);
        assertEq(lastInc, 0);

        NotSenatus notSenatus = new NotSenatus(codexGuard);
        assertTrue(
            !can_call(
                address(notSenatus),
                abi.encodeWithSelector(notSenatus.setDebtCeilingAdjuster.selector, address(1), 5, 1)
            )
        );
    }

    function test_removeDebtCeilingAdjuster() public {
        codexGuard.setDebtCeilingAdjuster(address(1), 0, 5, 1);

        NotSenatus notSenatus = new NotSenatus(codexGuard);
        assertTrue(
            !can_call(
                address(notSenatus),
                abi.encodeWithSelector(notSenatus.removeDebtCeilingAdjuster.selector, address(1))
            )
        );

        codexGuard.removeDebtCeilingAdjuster(address(1));

        (uint256 maxDebtCeiling, uint256 maxDelta, uint256 delay, uint256 last, uint256 lastInc) = codexGuard
            .debtCeilingAdjusters(address(1));
        assertEq(maxDebtCeiling, 0);
        assertEq(maxDelta, 0);
        assertEq(delay, 0);
        assertEq(last, 0);
        assertEq(lastInc, 0);
    }

    function test_setDebtFloor() public {
        codexGuard.setDebtFloor(address(1), 0, new address[](0));
        codexGuard.setDebtFloor(address(1), 10_000 * WAD, new address[](0));
        (, , , uint256 debtFloor) = codex.vaults(address(1));
        assertEq(debtFloor, 10_000 * WAD);

        assertTrue(
            !can_call(
                address(codexGuard),
                abi.encodeWithSelector(codexGuard.setDebtFloor.selector, address(1), 10_000 * WAD + 1, new address[](0))
            )
        );

        codexGuard.setGuardian(address(0));
        assertTrue(
            !can_call(
                address(codexGuard),
                abi.encodeWithSelector(codexGuard.setDebtFloor.selector, address(1), 10_000 * WAD, new address[](0))
            )
        );
    }
}

contract MockCodex {
    struct Vault {
        uint256 totalNormalizedDebt;
        uint256 rate;
        uint256 debtCeiling;
        uint256 debtFloor;
    }
    uint256 public globalDebtCeiling;
    mapping(address => Vault) public vaults;

    function setParam(bytes32 param, uint256 data) external {
        if (param == "globalDebtCeiling") globalDebtCeiling = data;
    }

    function setParam(
        address vault,
        bytes32 param,
        uint256 data
    ) external {
        if (param == "debtCeiling") vaults[vault].debtCeiling = data;
        else if (param == "rate") vaults[vault].rate = data;
    }

    function setTotalNormalizedDebt(address vault, uint256 wad) external {
        vaults[vault].totalNormalizedDebt = (wad * WAD) / vaults[vault].rate;
    }
}

contract CodexGuard_DebtCeilingAdjuster_Test is Test {
    MockCodex codex;
    CodexGuard codexGuard;

    address constant gold = address(uint160(uint256(keccak256("gold"))));
    address constant silver = address(uint160(uint256(keccak256("silver"))));
    address constant vault = address(uint160(uint256(keccak256("gold"))));

    function setUp() public {
        codex = new MockCodex();
        codex.setParam("globalDebtCeiling", 10000 * WAD);
        codex.setParam(vault, "debtCeiling", 10000 * WAD);
        codex.setParam(vault, "rate", 1 * WAD);

        codexGuard = new CodexGuard(address(this), address(this), 1, address(codex));
        codexGuard.setDebtCeilingAdjuster(vault, 12600 * WAD, 2500 * WAD, 1 hours);

        _warp(0);
    }

    function _warp(uint256 time) internal {
        vm.roll(time / 15); // 1 block each 15 seconds
        vm.warp(time);
    }

    function test_exec() public {
        codex.setTotalNormalizedDebt(vault, 10000 * WAD); // Max debt ceiling amount
        (uint256 totalNormalizedDebt, , uint256 debtCeiling, ) = codex.vaults(vault);
        assertEq(totalNormalizedDebt, 10000 * WAD);
        assertEq(debtCeiling, 10000 * WAD);
        assertEq(codex.globalDebtCeiling(), 10000 * WAD);

        _warp(1 hours);

        codexGuard.setDebtCeiling(vault);
        (, , debtCeiling, ) = codex.vaults(vault);
        assertEq(debtCeiling, 12500 * WAD);
        assertEq(codex.globalDebtCeiling(), 12500 * WAD);
        (, , , uint256 last, uint256 lastInc) = codexGuard.debtCeilingAdjusters(vault);
        assertEq(last, 1 hours / 15);
        assertEq(lastInc, 1 hours);
        codex.setTotalNormalizedDebt(vault, 10200 * WAD); // New max debt ceiling amount

        _warp(2 hours);

        codexGuard.setDebtCeiling(vault);
        (, , debtCeiling, ) = codex.vaults(vault);
        assertEq(debtCeiling, 12600 * WAD); // < 12700 * WAD (due max debtCeiling: 10200 + gap)
        assertEq(codex.globalDebtCeiling(), 12600 * WAD);
        (, , , last, lastInc) = codexGuard.debtCeilingAdjusters(vault);
        assertEq(last, 2 hours / 15);
        assertEq(lastInc, 2 hours);
    }

    function test_exec_multiple_vaults() public {
        codex.setParam(gold, "debtCeiling", 5000 * WAD);
        codexGuard.setDebtCeilingAdjuster(gold, 7600 * WAD, 2500 * WAD, 1 hours);

        codex.setParam(silver, "debtCeiling", 5000 * WAD);
        codex.setParam(silver, "rate", 1 * WAD);
        codexGuard.setDebtCeilingAdjuster(silver, 7600 * WAD, 1000 * WAD, 2 hours);

        codex.setTotalNormalizedDebt(gold, 5000 * WAD); // Max gold debt ceiling amount
        (uint256 goldTotalNormalizedDebt, , uint256 goldDebtCeiling, ) = codex.vaults(gold);
        assertEq(goldTotalNormalizedDebt, 5000 * WAD);
        assertEq(goldDebtCeiling, 5000 * WAD);
        assertEq(codex.globalDebtCeiling(), 10000 * WAD);

        codex.setTotalNormalizedDebt(silver, 5000 * WAD); // Max silver debt ceiling amount
        (uint256 silverTotalNormalizedDebt, , uint256 silverDebtCeiling, ) = codex.vaults(silver);
        assertEq(silverTotalNormalizedDebt, 5000 * WAD);
        assertEq(silverDebtCeiling, 5000 * WAD);
        assertEq(codex.globalDebtCeiling(), 10000 * WAD);

        assertEq(codexGuard.setDebtCeiling(gold), 5000 * WAD);
        assertEq(codexGuard.setDebtCeiling(silver), 5000 * WAD);
        _warp(1 hours);
        assertEq(codexGuard.setDebtCeiling(gold), 7500 * WAD);
        assertEq(codexGuard.setDebtCeiling(silver), 5000 * WAD);

        (, , goldDebtCeiling, ) = codex.vaults(gold);
        assertEq(goldDebtCeiling, 7500 * WAD);
        assertEq(codex.globalDebtCeiling(), 12500 * WAD);
        (, , , uint256 goldLast, uint256 goldLastInc) = codexGuard.debtCeilingAdjusters(gold);
        assertEq(goldLast, 1 hours / 15);
        assertEq(goldLastInc, 1 hours);

        assertEq(codexGuard.setDebtCeiling(silver), 5000 * WAD); // Don't need to check gold since no debt increase

        _warp(2 hours);
        assertEq(codexGuard.setDebtCeiling(gold), 7500 * WAD); // Gold debtCeiling does not increase
        assertEq(codexGuard.setDebtCeiling(silver), 6000 * WAD); // Silver debtCeiling increases

        (, , goldDebtCeiling, ) = codex.vaults(gold);
        assertEq(goldDebtCeiling, 7500 * WAD);
        (, , silverDebtCeiling, ) = codex.vaults(silver);
        assertEq(silverDebtCeiling, 6000 * WAD);
        assertEq(codex.globalDebtCeiling(), 13500 * WAD);
        assertTrue(codex.globalDebtCeiling() == goldDebtCeiling + silverDebtCeiling);

        (, , , goldLast, goldLastInc) = codexGuard.debtCeilingAdjusters(gold);
        assertEq(goldLast, 1 hours / 15);
        assertEq(goldLastInc, 1 hours);
        (, , , uint256 silverLast, uint256 silverLastInc) = codexGuard.debtCeilingAdjusters(silver);
        assertEq(silverLast, 2 hours / 15);
        assertEq(silverLastInc, 2 hours);

        codex.setTotalNormalizedDebt(gold, 7500 * WAD); // Will use max debtCeiling
        codex.setTotalNormalizedDebt(silver, 6000 * WAD); // Will use `gap`

        _warp(4 hours); // Both will be able to increase

        assertEq(codexGuard.setDebtCeiling(gold), 7600 * WAD);
        assertEq(codexGuard.setDebtCeiling(silver), 7000 * WAD);

        (, , goldDebtCeiling, ) = codex.vaults(gold);
        assertEq(goldDebtCeiling, 7600 * WAD);
        (, , silverDebtCeiling, ) = codex.vaults(silver);
        assertEq(silverDebtCeiling, 7000 * WAD);
        assertEq(codex.globalDebtCeiling(), 14600 * WAD);
        assertTrue(codex.globalDebtCeiling() == goldDebtCeiling + silverDebtCeiling);

        (, , , goldLast, goldLastInc) = codexGuard.debtCeilingAdjusters(gold);
        assertEq(goldLast, 4 hours / 15);
        assertEq(goldLastInc, 4 hours);
        (, , , silverLast, silverLastInc) = codexGuard.debtCeilingAdjusters(silver);
        assertEq(silverLast, 4 hours / 15);
        assertEq(silverLastInc, 4 hours);
    }

    function test_vault_not_enabled() public {
        codex.setTotalNormalizedDebt(vault, 10000 * WAD); // Max debt ceiling amount
        _warp(1 hours);

        codexGuard.removeDebtCeilingAdjuster(vault);
        assertEq(codexGuard.setDebtCeiling(vault), 10000 * WAD); // The debtCeiling from the codex
    }

    function test_exec_not_enough_time_passed() public {
        codex.setTotalNormalizedDebt(vault, 10000 * WAD); // Max debt ceiling amount
        _warp(3575);
        assertEq(codexGuard.setDebtCeiling(vault), 10000 * WAD); // No change
        _warp(1 hours);
        assertEq(codexGuard.setDebtCeiling(vault), 12500 * WAD); // + gap
    }

    function test_exec_line_decrease_under_min_time() public {
        // As the debt ceiling will decrease
        codex.setTotalNormalizedDebt(vault, 10000 * WAD);
        (, , uint256 debtCeiling, ) = codex.vaults(vault);
        assertEq(debtCeiling, 10000 * WAD);
        assertEq(codex.globalDebtCeiling(), 10000 * WAD);
        (, , , uint48 last, uint48 lastInc) = codexGuard.debtCeilingAdjusters(vault);
        assertEq(last, 0);
        assertEq(lastInc, 0);

        _warp(15); // To block number 1

        assertEq(codexGuard.setDebtCeiling(vault), 10000 * WAD);
        (, , debtCeiling, ) = codex.vaults(vault);
        assertEq(debtCeiling, 10000 * WAD);
        assertEq(codex.globalDebtCeiling(), 10000 * WAD);
        (, , , last, lastInc) = codexGuard.debtCeilingAdjusters(vault);
        assertEq(last, 0); // no update
        assertEq(lastInc, 0); // no increment

        codex.setTotalNormalizedDebt(vault, 7000 * WAD); // debt + gap = 7000 + 2500 = 9500 < 10000
        (uint256 totalNormalizedDebt, , , ) = codex.vaults(vault);
        assertEq(totalNormalizedDebt, 7000 * WAD);

        _warp(30); // To block number 2

        assertEq(codexGuard.setDebtCeiling(vault), 9500 * WAD);
        (, , debtCeiling, ) = codex.vaults(vault);
        assertEq(debtCeiling, 9500 * WAD);
        assertEq(codex.globalDebtCeiling(), 9500 * WAD);
        (, , , last, lastInc) = codexGuard.debtCeilingAdjusters(vault);
        assertEq(last, 2); // update
        assertEq(lastInc, 0); // no increment

        codex.setTotalNormalizedDebt(vault, 6000 * WAD); // debt + gap = 6000 + 2500 = 8500 < 9500
        (totalNormalizedDebt, , , ) = codex.vaults(vault);
        assertEq(totalNormalizedDebt, 6000 * WAD);

        assertEq(codexGuard.setDebtCeiling(vault), 9500 * WAD); // Same value as it was executed on same block than previous setDebtCeiling
        (, , debtCeiling, ) = codex.vaults(vault);
        assertEq(debtCeiling, 9500 * WAD);
        assertEq(codex.globalDebtCeiling(), 9500 * WAD);
        (, , , last, lastInc) = codexGuard.debtCeilingAdjusters(vault);
        assertEq(last, 2); // no update
        assertEq(lastInc, 0); // no increment

        _warp(45); // To block number 3

        assertEq(codexGuard.setDebtCeiling(vault), 8500 * WAD);
        (, , debtCeiling, ) = codex.vaults(vault);
        assertEq(debtCeiling, 8500 * WAD);
        assertEq(codex.globalDebtCeiling(), 8500 * WAD);
        (, , , last, lastInc) = codexGuard.debtCeilingAdjusters(vault);
        assertEq(last, 3); // update
        assertEq(lastInc, 0); // no increment
    }

    function test_invalid_exec_vault() public {
        _warp(1 hours);
        assertEq(codexGuard.setDebtCeiling(address(1)), 0);
    }

    function test_exec_twice_failure() public {
        codex.setTotalNormalizedDebt(vault, 100 * WAD); // Max debt ceiling amount
        codex.setParam(vault, "debtCeiling", 100 * WAD);
        codexGuard.setDebtCeilingAdjuster(vault, 20000 * WAD, 2500 * WAD, 1 hours);

        _warp(1 hours);

        assertEq(codexGuard.setDebtCeiling(vault), 2600 * WAD);
        (, , uint256 debtCeiling, ) = codex.vaults(vault);
        assertEq(debtCeiling, 2600 * WAD);
        assertEq(codex.globalDebtCeiling(), 12500 * WAD);

        codex.setTotalNormalizedDebt(vault, 2500 * WAD);

        assertEq(codexGuard.setDebtCeiling(vault), 2600 * WAD); // This should short-circuit

        _warp(2 hours);

        assertEq(codexGuard.setDebtCeiling(vault), 5000 * WAD);
        (, , debtCeiling, ) = codex.vaults(vault);
        assertEq(debtCeiling, 5000 * WAD);
        assertEq(codex.globalDebtCeiling(), 14900 * WAD);
    }
}
