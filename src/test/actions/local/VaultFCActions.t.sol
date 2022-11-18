// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1155PresetMinterPauser} from "openzeppelin/contracts/token/ERC1155/presets/ERC1155PresetMinterPauser.sol";
import {ERC1155Holder} from "openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {Codex} from "../../../core/Codex.sol";
import {Publican} from "../../../core/Publican.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {WAD, wdiv, toInt256, sub} from "../../../core/utils/Math.sol";
import {IMoneta} from "../../../interfaces/IMoneta.sol";
import {IVault} from "../../../interfaces/IVault.sol";

import {VaultFC} from "../../../vaults/VaultFC.sol";

import {Caller} from "../../../test/utils/Caller.sol";

import {Vault1155Actions} from "../../../actions/vault/Vault1155Actions.sol";

interface IERC20Safe {
    function safeTransfer(address to, uint256 value) external;

    function safeTransferFrom(
        address from,
        address to,
        uint256 value
    ) external;
}

contract CallerERC1155Holder is Caller, ERC1155Holder {}

contract Vault1155Actions_UnitTest is Test, ERC1155Holder {
    Codex internal codex;
    address internal collybus = address(0xc0111b115);
    address internal publican = address(0x511b11ca11);
    Moneta internal moneta;
    FIAT internal fiat;

    //keccak256(abi.encode("underlier"));
    address internal underlier = address(0x1ef2A2B80693ccCDc6A388829635d22EBEDF667c);

    VaultFC internal vault;

    PRBProxy userProxy;
    PRBProxyFactory prbProxyFactory;
    Vault1155Actions vaultActions;
    ERC1155PresetMinterPauser notional;

    CallerERC1155Holder kakaroto;
    address me = address(this);
    uint256 tokenId;
    uint256 internal constant QUARTER = 86400 * 6 * 5 * 3;
    uint256 internal constant collateralAmount = 100000000;

    function _encodeERC1155Id(
        uint256 currencyId,
        uint256 maturity,
        uint256 assetType
    ) internal pure returns (uint256) {
        require(maturity <= type(uint40).max);

        return
            uint256(
                (bytes32(uint256(uint16(currencyId))) << 48) |
                    (bytes32(uint256(uint40(maturity))) << 8) |
                    bytes32(uint256(uint8(assetType)))
            );
    }

    function _collateral(
        address vault_,
        uint256 tokenId_,
        address user
    ) internal view returns (uint256) {
        (uint256 collateral, ) = codex.positions(vault_, tokenId_, user);
        return collateral;
    }

    function _normalDebt(
        address vault_,
        uint256 tokenId_,
        address user
    ) internal view returns (uint256) {
        (, uint256 normalDebt) = codex.positions(vault_, tokenId_, user);
        return normalDebt;
    }

    function setUp() public {
        // workaround for tenor validation
        vm.warp(1637082846);
        kakaroto = new CallerERC1155Holder();
        codex = new Codex();
        fiat = new FIAT();
        moneta = new Moneta(address(codex), address(fiat));
        fiat.allowCaller(fiat.mint.selector, address(moneta));
        notional = new ERC1155PresetMinterPauser("");

        vm.mockCall(underlier, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint256(6)));
        
        vault = new VaultFC(
            address(codex),
            collybus,
            address(notional),
            underlier,
            uint256(86400 * 6 * 5 * 3),
            3
        );

        codex.setParam("globalDebtCeiling", uint256(1000 ether));
        codex.setParam(address(vault), "debtCeiling", uint256(1000 ether));
        codex.allowCaller(codex.modifyBalance.selector, address(vault));
        codex.init(address(vault));

        prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        vaultActions = new Vault1155Actions(address(codex), address(moneta), address(fiat), publican);

        tokenId = _encodeERC1155Id(3, 1640736000, 1);
        notional.setApprovalForAll(address(userProxy), true);
        notional.mint(address(this), tokenId, collateralAmount, new bytes(0));

        kakaroto.externalCall(
            address(notional),
            abi.encodeWithSelector(notional.setApprovalForAll.selector, address(userProxy), true)
        );

        fiat.approve(address(userProxy), type(uint256).max);
        kakaroto.externalCall(
            address(fiat),
            abi.encodeWithSelector(fiat.approve.selector, address(userProxy), type(uint256).max)
        );

        vm.mockCall(collybus, abi.encodeWithSelector(Collybus.read.selector), abi.encode(uint256(WAD)));

        vm.mockCall(publican, abi.encodeWithSelector(Publican.collect.selector), abi.encode(uint256(10**18)));
        
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), type(uint256).max)
        );
    }

    function testFail_increaseCollateral_vault_zero() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(0),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                address(0),
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                0
            )
        );
    }

    function testFail_increaseCollateral_token_zero() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(0),
                tokenId,
                address(userProxy),
                me,
                address(0),
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                0
            )
        );
    }

    function test_increaseCollateral() public {
        uint256 meInitialBalance = notional.balanceOf(me, tokenId);
        uint256 vaultInitialBalance = notional.balanceOf(address(vault), tokenId);
        uint256 initialCollateral = _collateral(address(vault), tokenId, address(userProxy));

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                address(0),
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                0
            )
        );

        assertEq(notional.balanceOf(me, tokenId), meInitialBalance - collateralAmount);
        assertEq(notional.balanceOf(address(vault), tokenId), vaultInitialBalance + collateralAmount);
        uint256 wadAmount = wdiv(collateralAmount, IVault(address(vault)).tokenScale());
        assertEq(_collateral(address(vault), tokenId, address(userProxy)), initialCollateral + wadAmount);
    }

    function test_increaseCollateral_from_user() public {
        notional.safeTransferFrom(me, address(kakaroto), tokenId, collateralAmount, new bytes(0));
        uint256 kakarotoInitialBalance = notional.balanceOf(address(kakaroto), tokenId);
        uint256 vaultInitialBalance = notional.balanceOf(address(vault), tokenId);
        uint256 initialCollateral = _collateral(address(vault), tokenId, address(userProxy));

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                address(kakaroto),
                address(0),
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                0
            )
        );

        assertEq(notional.balanceOf(address(kakaroto), tokenId), kakarotoInitialBalance - collateralAmount);
        assertEq(notional.balanceOf(address(vault), tokenId), vaultInitialBalance + collateralAmount);
        uint256 wadAmount = wdiv(collateralAmount, IVault(address(vault)).tokenScale());
        assertEq(_collateral(address(vault), tokenId, address(userProxy)), initialCollateral + wadAmount);
    }

    function test_increaseCollateral_from_proxy_zero() public {
        notional.safeTransferFrom(me, address(userProxy), tokenId, collateralAmount, new bytes(0));
        uint256 proxyInitialBalance = notional.balanceOf(address(userProxy), tokenId);
        uint256 vaultInitialBalance = notional.balanceOf(address(vault), tokenId);
        uint256 initialCollateral = _collateral(address(vault), tokenId, address(userProxy));

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                address(0),
                address(0),
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                0
            )
        );

        assertEq(notional.balanceOf(address(userProxy), tokenId), proxyInitialBalance - collateralAmount);
        assertEq(notional.balanceOf(address(vault), tokenId), vaultInitialBalance + collateralAmount);
        uint256 wadAmount = wdiv(collateralAmount, IVault(address(vault)).tokenScale());
        assertEq(_collateral(address(vault), tokenId, address(userProxy)), initialCollateral + wadAmount);
    }

    function test_increaseCollateral_from_proxy_address() public {
        notional.safeTransferFrom(me, address(userProxy), tokenId, collateralAmount, new bytes(0));
        uint256 proxyInitialBalance = notional.balanceOf(address(userProxy), tokenId);
        uint256 vaultInitialBalance = notional.balanceOf(address(vault), tokenId);
        uint256 initialCollateral = _collateral(address(vault), tokenId, address(userProxy));

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                address(userProxy),
                address(0),
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                0
            )
        );

        assertEq(notional.balanceOf(address(userProxy), tokenId), proxyInitialBalance - collateralAmount);
        assertEq(notional.balanceOf(address(vault), tokenId), vaultInitialBalance + collateralAmount);
        uint256 wadAmount = wdiv(collateralAmount, IVault(address(vault)).tokenScale());
        assertEq(_collateral(address(vault), tokenId, address(userProxy)), initialCollateral + wadAmount);
    }

    function testFail_decreaseCollateral_to_zero() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                address(0),
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                0
            )
        );

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                address(0), // this can't be zero
                address(0),
                -toInt256(wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale())), // notice this negative value
                0
            )
        );
    }

    function test_decreaseCollateral() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                address(0),
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                0
            )
        );

        uint256 meInitialBalance = notional.balanceOf(me, tokenId);
        uint256 vaultInitialBalance = notional.balanceOf(address(vault), tokenId);
        uint256 initialCollateral = _collateral(address(vault), tokenId, address(userProxy));

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                address(0),
                -toInt256(wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale())),
                0
            )
        );

        assertEq(notional.balanceOf(me, tokenId), meInitialBalance + (collateralAmount / 2));
        assertEq(notional.balanceOf(address(vault), tokenId), vaultInitialBalance - (collateralAmount / 2));
        uint256 wadAmount = wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale());
        assertEq(_collateral(address(vault), tokenId, address(userProxy)), initialCollateral - wadAmount);
    }

    function test_decreaseCollateral_to_user() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                address(0),
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                0
            )
        );

        uint256 kakarotoInitialBalance = notional.balanceOf(address(kakaroto), tokenId);
        uint256 vaultInitialBalance = notional.balanceOf(address(vault), tokenId);
        uint256 initialCollateral = _collateral(address(vault), tokenId, address(userProxy));

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                address(kakaroto),
                address(0),
                -toInt256(wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale())),
                0
            )
        );

        assertEq(notional.balanceOf(address(kakaroto), tokenId), kakarotoInitialBalance + (collateralAmount / 2));
        assertEq(notional.balanceOf(address(vault), tokenId), vaultInitialBalance - (collateralAmount / 2));
        uint256 wadAmount = wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale());
        assertEq(_collateral(address(vault), tokenId, address(userProxy)), initialCollateral - wadAmount);
    }

    function testFail_increaseDebt_to_zero() public {
        // it should be some collateral added before increasing debt
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                address(0),
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                0
            )
        );

        // this setup is for only increasing debt
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                address(0),
                address(0), // this one causes the error
                0,
                toInt256(wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale()))
            )
        );
    }

    function test_increaseDebt() public {
        // it should be some collateral added before increasing debt
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                address(0),
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                0
            )
        );

        uint256 meInitialBalance = fiat.balanceOf(me);
        uint256 initialDebt = _normalDebt(address(vault), tokenId, address(userProxy));

        // this setup is for only increasing debt
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                address(0),
                me,
                0,
                toInt256(wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale()))
            )
        );

        assertEq(
            fiat.balanceOf(me),
            meInitialBalance + wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale())
        );
        assertEq(
            _normalDebt(address(vault), tokenId, address(userProxy)),
            initialDebt + wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale())
        );
    }

    function test_increaseDebt_to_user() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                address(0),
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                0
            )
        );

        uint256 kakarotoInitialBalance = fiat.balanceOf(address(kakaroto));
        uint256 initialDebt = _normalDebt(address(vault), tokenId, address(userProxy));

        uint256 wadAmount = wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale());

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                address(0),
                address(kakaroto),
                0,
                toInt256(wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale()))
            )
        );

        assertEq(fiat.balanceOf(address(kakaroto)), kakarotoInitialBalance + wadAmount);
        assertEq(_normalDebt(address(vault), tokenId, address(userProxy)), initialDebt + wadAmount);
    }

    function test_decreaseDebt() public {
        uint256 wadAmount = wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale());
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                me,
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                toInt256(wadAmount)
            )
        );

        uint256 meInitialBalance = fiat.balanceOf(me);
        uint256 initialDebt = _normalDebt(address(vault), tokenId, address(userProxy));

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                address(0), //this can be 0 because we are not modifying collateral
                me,
                0, // we don't want to modify collateral
                -toInt256(wadAmount / 2) // notice the negative sign
            )
        );

        assertEq(fiat.balanceOf(me), meInitialBalance - (wadAmount / 2));
        assertEq(_normalDebt(address(vault), tokenId, address(userProxy)), initialDebt - (wadAmount / 2));
    }

    function test_decreaseDebt_from_user() public {
        uint256 wadAmount = wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale());
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                me,
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                toInt256(wadAmount)
            )
        );

        fiat.transfer(address(kakaroto), wadAmount);

        uint256 kakarotoInitialBalance = fiat.balanceOf(address(kakaroto));
        uint256 initialDebt = _normalDebt(address(vault), tokenId, address(userProxy));

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                address(0), //this can be 0 because we are not modifying collateral
                address(kakaroto),
                0, // we don't want to modify collateral
                -toInt256(wadAmount / 2) // notice the negative sign
            )
        );

        assertEq(fiat.balanceOf(address(kakaroto)), kakarotoInitialBalance - (wadAmount / 2));
        assertEq(_normalDebt(address(vault), tokenId, address(userProxy)), initialDebt - (wadAmount / 2));
    }

    function test_decreaseDebt_from_proxy_zero() public {
        uint256 wadAmount = wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale());
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                me,
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                toInt256(wadAmount)
            )
        );

        fiat.transfer(address(userProxy), wadAmount);

        uint256 proxyInitialBalance = fiat.balanceOf(address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), tokenId, address(userProxy));

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                address(0), // this can be 0 because we are not modifying collateral
                address(0), // since this one is 0, and the delta debt is negative, the FIAT are taken from the proxy
                0, // we don't want to modify collateral
                -toInt256(wadAmount / 2) // notice the negative sign
            )
        );

        assertEq(fiat.balanceOf(address(userProxy)), proxyInitialBalance - (wadAmount / 2));
        assertEq(_normalDebt(address(vault), tokenId, address(userProxy)), initialDebt - (wadAmount / 2));
    }

    function test_decreaseDebt_from_proxy_address() public {
        uint256 wadAmount = wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale());
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                me,
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                toInt256(wadAmount)
            )
        );

        fiat.transfer(address(userProxy), wadAmount);

        uint256 proxyInitialBalance = fiat.balanceOf(address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), tokenId, address(userProxy));

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                address(0), // this can be 0 because we are not modifying collateral
                address(userProxy),
                0, // we don't want to modify collateral
                -toInt256(wadAmount / 2) // notice the negative sign
            )
        );

        assertEq(fiat.balanceOf(address(userProxy)), proxyInitialBalance - (wadAmount / 2));
        assertEq(_normalDebt(address(vault), tokenId, address(userProxy)), initialDebt - (wadAmount / 2));
    }

    function test_modifyCollateralAndDebt_increase_collateral_increase_debt() public {
        uint256 meInitialBalance = notional.balanceOf(me, tokenId);
        uint256 vaultInitialBalance = notional.balanceOf(address(vault), tokenId);
        uint256 initialCollateral = _collateral(address(vault), tokenId, address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), tokenId, address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        uint256 debtAmount = wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale());

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                notional,
                tokenId,
                address(userProxy),
                me,
                me,
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                toInt256(debtAmount)
            )
        );

        assertEq(notional.balanceOf(me, tokenId), meInitialBalance - collateralAmount);
        assertEq(notional.balanceOf(address(vault), tokenId), vaultInitialBalance + collateralAmount);
        uint256 wadAmount = wdiv(collateralAmount, IVault(address(vault)).tokenScale());
        assertEq(_collateral(address(vault), tokenId, address(userProxy)), initialCollateral + wadAmount);
        assertEq(fiat.balanceOf(me), fiatMeInitialBalance + debtAmount);
        assertEq(_normalDebt(address(vault), tokenId, address(userProxy)), initialDebt + debtAmount);
    }

    function test_modifyCollateralAndDebt_decrease_debt_decrease_collateral() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                me,
                toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale())),
                toInt256(wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale()))
            )
        );

        uint256 meInitialBalance = notional.balanceOf(me, tokenId);
        uint256 vaultInitialBalance = notional.balanceOf(address(vault), tokenId);
        uint256 initialCollateral = _collateral(address(vault), tokenId, address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault), tokenId, address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(vault),
                address(notional),
                tokenId,
                address(userProxy),
                me,
                me,
                -toInt256(wdiv(collateralAmount, IVault(address(vault)).tokenScale()) / 4),
                -toInt256(wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale()) / 4)
            )
        );

        assertEq(notional.balanceOf(me, tokenId), meInitialBalance + (collateralAmount / 4));
        assertEq(notional.balanceOf(address(vault), tokenId), vaultInitialBalance - (collateralAmount / 4));

        uint256 wadAmount = wdiv(collateralAmount / 4, IVault(address(vault)).tokenScale());
        assertEq(_collateral(address(vault), tokenId, address(userProxy)), initialCollateral - wadAmount);
        assertEq(
            fiat.balanceOf(me),
            fiatMeInitialBalance - (wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale()) / 4)
        );
        assertEq(
            _normalDebt(address(vault), tokenId, address(userProxy)),
            initialDebt - (wdiv(collateralAmount / 2, IVault(address(vault)).tokenScale()) / 4)
        );
    }
}
