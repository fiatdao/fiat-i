// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Codex} from "../../../core/Codex.sol";
import {IVault} from "../../../interfaces/IVault.sol";
import {IMoneta} from "../../../interfaces/IMoneta.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {WAD, toInt256, wmul, wdiv, sub, add} from "../../../core/utils/Math.sol";

import {VaultFYActions} from "../../../actions/vault/VaultFYActions.sol";

contract YieldSpaceMock {
    function sellBasePreview(uint128 baseIn) external pure returns (uint128) {
        return (baseIn * 102) / 100;
    }

    function sellBase(address, uint128 min) external pure returns (uint128) {
        return (min * 102) / 100;
    }

    function sellFYTokenPreview(uint128 fyTokenIn) external pure returns (uint128) {
        return (fyTokenIn * 99) / 100;
    }

    function sellFYToken(address, uint128 min) external pure returns (uint128) {
        return (min * 99) / 100;
    }
}

contract VaultFYActions_UnitTest is Test {
    address internal codex = address(0xc0d311);
    address internal moneta = address(0x11101137a);
    //keccak256(abi.encode("publican"));
    address internal publican = address(0xDF68e6705C6Cc25E78aAC874002B5ab31b679db4);
    //keccak256(abi.encode("mockVault"));
    address internal mockVault = address(0x4E0075d8C837f8fb999012e556b7A63FC65fceDa);
    VaultFYActions VaultActions;
    address internal fiat = address(0xf1a7);
    YieldSpaceMock yieldSpace;
    address internal ccp = address(0xcc9);

    address me = address(this);
    bytes32 poolId = bytes32("somePoolId");

    address internal underlierUSDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    address internal fyUSDC06 = address(0x4568bBcf929AB6B4d716F2a3D5A967a1908B4F1C); // FYUSDC06

    uint256 underlierScale = uint256(1e6);
    uint256 tokenScale = uint256(1e6);
    uint256 percentFee = 1e16;

    function setUp() public {
        yieldSpace = new YieldSpaceMock();

        VaultActions = new VaultFYActions(codex, moneta, fiat, publican);

        vm.mockCall(mockVault, abi.encodeWithSelector(IVault.token.selector), abi.encode(fyUSDC06));

        vm.mockCall(mockVault, abi.encodeWithSelector(IVault.underlierToken.selector), abi.encode(underlierUSDC));

        vm.mockCall(mockVault, abi.encodeWithSelector(IVault.underlierScale.selector), abi.encode(1e6));

        vm.mockCall(mockVault, abi.encodeWithSelector(IVault.tokenScale.selector), abi.encode(1e6));
        
    }

    function test_underlierToFYToken() public {
        assertEq(VaultActions.underlierToFYToken(1e6, address(yieldSpace)), yieldSpace.sellBasePreview(1e6));
    }

    function test_fyTokenToUnderlier() public {
        assertEq(VaultActions.fyTokenToUnderlier(1e6, address(yieldSpace)), yieldSpace.sellFYTokenPreview(1e6));
    }

    function test_underlierToFYTokenOverflow() public {
        bytes memory customError = abi.encodeWithSignature("VaultFYActions__toUint128_overflow()");
        vm.expectRevert(customError);
        VaultActions.underlierToFYToken(type(uint128).max, address(yieldSpace));
    }

    function test_fyTokenToUnderlierOverflow() public {
        bytes memory customError = abi.encodeWithSignature("VaultFYActions__toUint128_overflow()");
        vm.expectRevert(customError);
        VaultActions.fyTokenToUnderlier(type(uint128).max, address(yieldSpace));
    }
}
