// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {DSToken} from "../../utils/dapphub/DSToken.sol";

import {Codex} from "../../../core/Codex.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {WAD} from "../../../core/utils/Math.sol";
import {Vault20} from "../../../vaults/Vault.sol";

uint256 constant tokenId = 0;

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

    function pass() public {}
}

contract TransferCollateralAndDebtTest is Test {
    Codex codex;
    address vault;
    User ali;
    User bob;
    address a;
    address b;

    function setUp() public {
        codex = new Codex();
        ali = new User(codex);
        bob = new User(codex);
        a = address(ali);
        b = address(bob);

        Collybus collybus = new Collybus();
        DSToken token = new DSToken("GOLD");
        Vault20 _vault = new Vault20(address(codex), address(token), address(collybus));
        vault = address(_vault);
        collybus.setParam(vault, "liquidationRatio", 1 ether);
        collybus.updateSpot(address(token), 0.5 ether);

        codex.init(vault);
        codex.setParam(vault, "debtCeiling", 1000 ether);
        codex.setParam("globalDebtCeiling", 1000 ether);

        codex.modifyBalance(vault, 0, a, 8 ether);
    }

    function test_transferCollateralAndDebt_to_self() public {
        ali.modifyCollateralAndDebt(vault, tokenId, a, a, a, 8 ether, 4 ether);
        assertTrue(ali.can_transferCollateralAndDebt(vault, tokenId, a, a, 8 ether, 4 ether));
        assertTrue(ali.can_transferCollateralAndDebt(vault, tokenId, a, a, 4 ether, 2 ether));
        assertTrue(!ali.can_transferCollateralAndDebt(vault, tokenId, a, a, 9 ether, 4 ether));
    }

    function test_give_to_other() public {
        ali.modifyCollateralAndDebt(vault, tokenId, a, a, a, 8 ether, 4 ether);
        assertTrue(!ali.can_transferCollateralAndDebt(vault, tokenId, a, b, 8 ether, 4 ether));
        bob.grantDelegate(address(ali));
        assertTrue(ali.can_transferCollateralAndDebt(vault, tokenId, a, b, 8 ether, 4 ether));
    }

    function test_transferCollateralAndDebt_to_other() public {
        ali.modifyCollateralAndDebt(vault, tokenId, a, a, a, 8 ether, 4 ether);
        bob.grantDelegate(address(ali));
        assertTrue(ali.can_transferCollateralAndDebt(vault, tokenId, a, b, 4 ether, 2 ether));
        assertTrue(!ali.can_transferCollateralAndDebt(vault, tokenId, a, b, 4 ether, 3 ether));
        assertTrue(!ali.can_transferCollateralAndDebt(vault, tokenId, a, b, 4 ether, 1 ether));
    }

    function test_transferCollateralAndDebt_debtFloor() public {
        ali.modifyCollateralAndDebt(vault, tokenId, a, a, a, 8 ether, 4 ether);
        bob.grantDelegate(address(ali));
        assertTrue(ali.can_transferCollateralAndDebt(vault, tokenId, a, b, 4 ether, 2 ether));
        codex.setParam(vault, "debtFloor", 1 ether);
        assertTrue(ali.can_transferCollateralAndDebt(vault, tokenId, a, b, 2 ether, 1 ether));
        assertTrue(!ali.can_transferCollateralAndDebt(vault, tokenId, a, b, 1 ether, 0.5 ether));
    }
}
