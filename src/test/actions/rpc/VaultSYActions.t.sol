// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC721Holder} from "openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {PRBProxy} from "proxy/contracts/PRBProxy.sol";
import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";

import {Codex} from "../../../core/Codex.sol";
import {Publican} from "../../../core/Publican.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {toInt256, WAD, wdiv} from "../../../core/utils/Math.sol";

import {VaultSY, ISmartYield} from "../../../vaults/VaultSY.sol";

import {Caller} from "../../../test/utils/Caller.sol";

import {VaultSYActions} from "../../../actions/vault/VaultSYActions.sol";

contract VaultSYActions_RPC_tests is Test, ERC1155Holder, ERC721Holder {
    Codex internal codex;
    Publican internal publican;
    address internal collybus = address(0xc0111b115);
    Moneta internal moneta;
    FIAT internal fiat;
    PRBProxy internal userProxy;
    PRBProxyFactory internal prbProxyFactory;
    VaultSYActions internal vaultActions;

    VaultSY internal vault;

    ISmartYield internal market = ISmartYield(0x673f9488619821aB4f4155FdFFe06f6139De518F); // bb_cDAI
    IERC20 internal underlier = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F); // DAI

    address internal me = address(this);
    Caller internal receiver;

    uint256 internal bondId;
    uint256 internal principal;

    function _modifyCollateralAndDebt(
        address vault_,
        address token,
        uint256 tokenId,
        address collateralizer,
        address creditor,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    ) internal {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                vault_,
                token,
                tokenId,
                address(userProxy),
                collateralizer,
                creditor,
                deltaCollateral,
                deltaNormalDebt
            )
        );
    }

    function _mintUnderlier(address to, uint256 amount) internal {
        vm.store(address(underlier), keccak256(abi.encode(address(address(this)), uint256(0))), bytes32(uint256(1)));
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(underlier).call(abi.encodeWithSignature(sig, to, amount));
        assert(ok);
    }

    function _createBond(uint256 amount, uint16 forDays) internal {
        underlier.approve(market.pool(), amount);
        // comp provider
        market.buyBond(amount, market.bondGain(amount, forDays), block.timestamp, forDays);
        bondId = market.seniorBondId();
        assertTrue(vault.seniorBond().ownerOf(bondId) == address(this));
        vault.seniorBond().approve(address(userProxy), bondId);
    }

    function _collateral(
        address vault_,
        uint256 tokenId,
        address user
    ) internal view returns (uint256) {
        (uint256 collateral, ) = codex.positions(vault_, tokenId, user);
        return collateral;
    }

    function _normalDebt(
        address vault_,
        uint256 tokenId,
        address user
    ) internal view returns (uint256) {
        (, uint256 normalDebt) = codex.positions(vault_, tokenId, user);
        return normalDebt;
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 13700000);

        receiver = new Caller();
        codex = new Codex();
        publican = new Publican(address(codex));
        fiat = new FIAT();
        moneta = new Moneta(address(codex), address(fiat));
        fiat.allowCaller(fiat.mint.selector, address(moneta));
        vault = new VaultSY(address(codex), address(collybus), address(market), "");

        codex.setParam("globalDebtCeiling", uint256(1000 ether));
        codex.setParam(address(vault), "debtCeiling", uint256(1000 ether));
        codex.allowCaller(codex.modifyBalance.selector, address(vault));
        codex.init(address(vault));

        principal = 1000 ether;
        _mintUnderlier(me, principal);
        _createBond(principal, 30);

        prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));
        vaultActions = new VaultSYActions(address(codex), address(moneta), address(fiat), address(publican));

        codex.allowCaller(keccak256("ANY_SIG"), address(publican));
        publican.init(address(vault));
        publican.setParam(address(vault), "interestPerSecond", WAD);

        vm.mockCall(collybus, abi.encodeWithSelector(Collybus.read.selector), abi.encode(uint256(10**18)));

        vault.seniorBond().approve(address(userProxy), bondId);
        fiat.approve(address(userProxy), type(uint256).max);

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), type(uint256).max)
        );

        receiver.externalCall(
            address(fiat),
            abi.encodeWithSelector(fiat.approve.selector, address(userProxy), type(uint256).max)
        );
    }

    function test_setup() public {
        assertEq(vault.seniorBond().ownerOf(bondId), me);
    }

    function test_increaseCollateral_from_user() public {
        assertTrue(vault.seniorBond().ownerOf(bondId) == address(this));
        uint256 initialCollateral = _collateral(address(vault), bondId, address(userProxy));

        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            me,
            address(0),
            toInt256(wdiv(principal, vault.tokenScale())),
            0
        );

        assertTrue(vault.seniorBond().ownerOf(bondId) == address(vault));
        assertEq(
            _collateral(address(vault), bondId, address(userProxy)),
            initialCollateral + wdiv(principal, vault.tokenScale())
        );
    }

    function test_increaseCollateral_from_proxy_zero() public {
        vault.seniorBond().transferFrom(me, address(userProxy), bondId);
        assertTrue(vault.seniorBond().ownerOf(bondId) == address(userProxy));
        uint256 initialCollateral = _collateral(address(vault), bondId, address(userProxy));

        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            address(0),
            address(0),
            toInt256(wdiv(principal, vault.tokenScale())),
            0
        );

        assertTrue(vault.seniorBond().ownerOf(bondId) == address(vault));
        assertEq(
            _collateral(address(vault), bondId, address(userProxy)),
            initialCollateral + wdiv(principal, vault.tokenScale())
        );
    }

    function test_increaseCollateral_from_proxy_address() public {
        vault.seniorBond().transferFrom(me, address(userProxy), bondId);
        assertTrue(vault.seniorBond().ownerOf(bondId) == address(userProxy));
        uint256 initialCollateral = _collateral(address(vault), bondId, address(userProxy));

        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            address(userProxy),
            address(0),
            toInt256(wdiv(principal, vault.tokenScale())),
            0
        );

        assertTrue(vault.seniorBond().ownerOf(bondId) == address(vault));
        assertEq(
            _collateral(address(vault), bondId, address(userProxy)),
            initialCollateral + wdiv(principal, vault.tokenScale())
        );
    }

    function test_decreaseCollateral() public {
        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            me,
            address(0),
            toInt256(wdiv(principal, vault.tokenScale())),
            0
        );

        assertTrue(vault.seniorBond().ownerOf(bondId) == address(vault));
        uint256 initialCollateral = _collateral(address(vault), bondId, address(userProxy));

        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            me,
            address(0),
            -toInt256(wdiv(principal, vault.tokenScale())),
            0
        );

        assertTrue(vault.seniorBond().ownerOf(bondId) == me);
        assertEq(
            _collateral(address(vault), bondId, address(userProxy)),
            initialCollateral - wdiv(principal, vault.tokenScale())
        );
    }

    function test_decreaseCollateral_matured() public {
        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            me,
            address(0),
            toInt256(wdiv(principal, vault.tokenScale())),
            0
        );

        assertTrue(vault.seniorBond().ownerOf(bondId) == address(vault));
        uint256 initialCollateral = _collateral(address(vault), bondId, address(userProxy));

        (, , uint128 maturity, , ) = vault.bonds(bondId);
        vm.roll(block.number + 2102400); // accrue block based interest
        vm.warp(maturity); // mature bond

        uint256 meInitialBalance = underlier.balanceOf(me);

        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            me,
            address(0),
            -toInt256(wdiv(principal, vault.tokenScale())),
            0
        );

        assertEq(underlier.balanceOf(me), meInitialBalance + principal);
        assertEq(
            _collateral(address(vault), bondId, address(userProxy)),
            initialCollateral - wdiv(principal, vault.tokenScale())
        );
    }

    function test_decreaseCollateral_send_to_user() public {
        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            me,
            address(0),
            toInt256(wdiv(principal, vault.tokenScale())),
            0
        );

        assertTrue(vault.seniorBond().ownerOf(bondId) == address(vault));
        uint256 initialCollateral = _collateral(address(vault), bondId, address(userProxy));

        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            address(receiver),
            address(0),
            -toInt256(wdiv(principal, vault.tokenScale())),
            0
        );

        assertTrue(vault.seniorBond().ownerOf(bondId) == address(receiver));
        assertEq(
            _collateral(address(vault), bondId, address(userProxy)),
            initialCollateral - wdiv(principal, vault.tokenScale())
        );
    }

    function test_increaseDebt() public {
        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            me,
            address(0),
            toInt256(wdiv(principal, vault.tokenScale())),
            0
        );

        uint256 meInitialBalance = fiat.balanceOf(me);
        uint256 initialDebt = _normalDebt(address(vault), bondId, address(userProxy));

        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            address(0),
            me,
            0,
            toInt256(500 * WAD)
        );

        assertEq(fiat.balanceOf(me), meInitialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vault), bondId, address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_increaseDebt_send_to_user() public {
        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            me,
            address(0),
            toInt256(wdiv(principal, vault.tokenScale())),
            0
        );

        uint256 meInitialBalance = fiat.balanceOf(me);
        uint256 initialDebt = _normalDebt(address(vault), bondId, address(userProxy));

        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            address(0),
            address(receiver),
            0,
            toInt256(500 * WAD)
        );

        assertEq(fiat.balanceOf(address(receiver)), meInitialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vault), bondId, address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_decreaseDebt() public {
        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            me,
            me,
            toInt256(wdiv(principal, vault.tokenScale())),
            toInt256(500 * WAD)
        );

        uint256 meInitialBalance = fiat.balanceOf(me);
        uint256 initialDebt = _normalDebt(address(vault), bondId, address(userProxy));

        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            address(0),
            me,
            0,
            -toInt256(200 * WAD)
        );

        assertEq(fiat.balanceOf(me), meInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault), bondId, address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decreaseDebt_get_fiat_from() public {
        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            me,
            me,
            toInt256(wdiv(principal, vault.tokenScale())),
            toInt256(500 * WAD)
        );

        fiat.transfer(address(receiver), 500 * WAD);

        uint256 meInitialBalance = fiat.balanceOf(address(receiver));
        uint256 initialDebt = _normalDebt(address(vault), bondId, address(userProxy));

        _modifyCollateralAndDebt(
            address(vault),
            address(vault.seniorBond()),
            bondId,
            address(0),
            address(receiver),
            0,
            -toInt256(200 * WAD)
        );

        assertEq(fiat.balanceOf(address(receiver)), meInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault), bondId, address(userProxy)), initialDebt - (200 * WAD));
    }
}
