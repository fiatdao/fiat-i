// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {Codex} from "../../../core/Codex.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {Publican} from "../../../core/Publican.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {IVault} from "../../../interfaces/IVault.sol";
import {toInt256, WAD, sub, wmul, wdiv} from "../../../core/utils/Math.sol";

import {Vault20} from "../../../vaults/Vault.sol";

import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {Caller} from "../../../test/utils/Caller.sol";
import {TestERC20} from "../../../test/utils/TestERC20.sol";

import {Vault20Actions} from "../../../actions/vault/Vault20Actions.sol";

contract Vault20Actions_UnitTest_1 is Test {
    Codex internal codex;
    Publican internal publican;
    address internal collybus = address(0xc0111b115);
    Moneta internal moneta;
    FIAT internal fiat;
    Vault20Actions internal vaultActions;
    PRBProxy internal userProxy;

    Vault20 internal vault20Instance;

    uint256 internal tokenId = 0;
    address internal me = address(this);
    Caller kakaroto;
    address internal collateralToken;

    uint256 ONE_COLLATERAL_TOKEN = 1e18;

    function _collateral(address vault, address user) internal view returns (uint256) {
        (uint256 collateral, ) = codex.positions(vault, 0, user);
        return collateral;
    }

    function _normalDebt(address vault, address user) internal view returns (uint256) {
        (, uint256 normalDebt) = codex.positions(vault, 0, user);
        return normalDebt;
    }

    function _modifyCollateralAndDebt(
        address vault,
        address token,
        address collateralizer,
        address creditor,
        int256 deltaCollateral,
        int256 deltaNormalDebt
    ) internal {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                vault,
                token,
                0,
                address(userProxy),
                collateralizer,
                creditor,
                deltaCollateral,
                deltaNormalDebt
            )
        );
    }

    function setUp() public {
        kakaroto = new Caller();

        codex = new Codex();
        publican = new Publican(address(codex));
        fiat = new FIAT();
        moneta = new Moneta(address(codex), address(fiat));
        collateralToken = address(new TestERC20("", "", 18));

        vaultActions = new Vault20Actions(address(codex), address(moneta), address(fiat), address(publican));
        vault20Instance = new Vault20(address(codex), collateralToken, collybus);

        PRBProxyFactory prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        TestERC20(collateralToken).mint(me, 1000 * ONE_COLLATERAL_TOKEN);

        fiat.allowCaller(fiat.mint.selector, address(moneta));
        codex.setParam("globalDebtCeiling", uint256(1000 ether));
        codex.allowCaller(keccak256("ANY_SIG"), address(publican));

        codex.setParam(address(vault20Instance), "debtCeiling", uint256(1000 ether));
        codex.allowCaller(codex.modifyBalance.selector, address(vault20Instance));
        codex.init(address(vault20Instance));

        publican.init(address(vault20Instance));
        publican.setParam(address(vault20Instance), "interestPerSecond", 1000000000705562181);

        IERC20(collateralToken).approve(address(userProxy), type(uint256).max);
        kakaroto.externalCall(
            collateralToken,
            abi.encodeWithSelector(IERC20.approve.selector, address(userProxy), type(uint256).max)
        );

        fiat.approve(address(userProxy), type(uint256).max);
        kakaroto.externalCall(
            address(fiat),
            abi.encodeWithSelector(fiat.approve.selector, address(userProxy), type(uint256).max)
        );

        vm.mockCall(collybus, abi.encodeWithSelector(Collybus.read.selector), abi.encode(uint256(WAD)));
        
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(vaultActions.approveFIAT.selector, address(moneta), type(uint256).max)
        );
    }

    function test_enterVault() public {
        uint256 amount = 1000 * ONE_COLLATERAL_TOKEN;
        uint256 meInitialBalance = IERC20(collateralToken).balanceOf(me);
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = codex.balances(address(vault20Instance), 0, address(userProxy));

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.enterVault.selector,
                address(vault20Instance),
                address(collateralToken),
                0,
                me,
                amount
            )
        );

        assertEq(IERC20(collateralToken).balanceOf(me), meInitialBalance - amount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance + amount);
        assertEq(
            codex.balances(address(vault20Instance), 0, address(userProxy)),
            initialCollateral + wdiv(amount, 10**IERC20Metadata(collateralToken).decimals())
        );
    }

    function test_enterVault_from_user() public {
        uint256 amount = 1000 * ONE_COLLATERAL_TOKEN;
        IERC20(collateralToken).transfer(address(kakaroto), amount);

        uint256 kakarotoInitialBalance = IERC20(collateralToken).balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = codex.balances(address(vault20Instance), 0, address(userProxy));

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.enterVault.selector,
                address(vault20Instance),
                address(collateralToken),
                0,
                address(kakaroto),
                amount
            )
        );

        assertEq(IERC20(collateralToken).balanceOf(address(kakaroto)), kakarotoInitialBalance - amount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance + amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(codex.balances(address(vault20Instance), 0, address(userProxy)), initialCollateral + wadAmount);
    }

    function test_exitVault() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.enterVault.selector,
                address(vault20Instance),
                address(collateralToken),
                0,
                me,
                1000 * ONE_COLLATERAL_TOKEN
            )
        );

        uint256 meInitialBalance = IERC20(collateralToken).balanceOf(me);
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = codex.balances(address(vault20Instance), 0, address(userProxy));

        uint256 amount = 500 * ONE_COLLATERAL_TOKEN;

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.exitVault.selector,
                address(vault20Instance),
                address(collateralToken),
                0,
                me,
                amount
            )
        );

        assertEq(IERC20(collateralToken).balanceOf(me), meInitialBalance + amount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance - amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(codex.balances(address(vault20Instance), 0, address(userProxy)), initialCollateral - wadAmount);
    }

    function test_exitVault_send_to_user() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.enterVault.selector,
                address(vault20Instance),
                address(collateralToken),
                0,
                me,
                1000 * ONE_COLLATERAL_TOKEN
            )
        );

        uint256 kakarotoInitialBalance = IERC20(collateralToken).balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = codex.balances(address(vault20Instance), 0, address(userProxy));

        uint256 amount = 500 * ONE_COLLATERAL_TOKEN;

        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.exitVault.selector,
                address(vault20Instance),
                address(collateralToken),
                0,
                address(kakaroto),
                amount
            )
        );

        assertEq(IERC20(collateralToken).balanceOf(address(kakaroto)), kakarotoInitialBalance + amount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance - amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(codex.balances(address(vault20Instance), 0, address(userProxy)), initialCollateral - wadAmount);
    }

    function test_increaseCollateral() public {
        uint256 amount = 1000 * ONE_COLLATERAL_TOKEN;
        uint256 meInitialBalance = IERC20(collateralToken).balanceOf(me);
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            address(0),
            toInt256(wdiv(amount, 10**IERC20Metadata(collateralToken).decimals())),
            0
        );

        assertEq(IERC20(collateralToken).balanceOf(me), meInitialBalance - amount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance + amount);
        assertEq(
            _collateral(address(vault20Instance), address(userProxy)),
            initialCollateral + wdiv(amount, 10**IERC20Metadata(collateralToken).decimals())
        );
    }

    function test_increaseCollateral_from_user() public {
        uint256 amount = 1000 * ONE_COLLATERAL_TOKEN;
        IERC20(collateralToken).transfer(address(kakaroto), amount);

        uint256 kakarotoInitialBalance = IERC20(collateralToken).balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            address(kakaroto),
            address(0),
            toInt256(wdiv(amount, 10**IERC20Metadata(collateralToken).decimals())),
            0
        );

        assertEq(IERC20(collateralToken).balanceOf(address(kakaroto)), kakarotoInitialBalance - amount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance + amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral + wadAmount);
    }

    function test_increaseCollateral_from_proxy_zero() public {
        uint256 amount = 1000 * ONE_COLLATERAL_TOKEN;
        IERC20(collateralToken).transfer(address(userProxy), amount);

        uint256 proxyInitialBalance = IERC20(collateralToken).balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            address(0),
            address(0),
            toInt256(wdiv(amount, 10**IERC20Metadata(collateralToken).decimals())),
            0
        );

        assertEq(IERC20(collateralToken).balanceOf(address(userProxy)), proxyInitialBalance - amount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance + amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral + wadAmount);
    }

    function test_increaseCollateral_from_proxy_address() public {
        uint256 amount = 1000 * ONE_COLLATERAL_TOKEN;
        IERC20(collateralToken).transfer(address(userProxy), amount);

        uint256 proxyInitialBalance = IERC20(collateralToken).balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            address(userProxy),
            address(0),
            toInt256(wdiv(amount, 10**IERC20Metadata(collateralToken).decimals())),
            0
        );

        assertEq(IERC20(collateralToken).balanceOf(address(userProxy)), proxyInitialBalance - amount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance + amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral + wadAmount);
    }

    function test_decreaseCollateral() public {
        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            address(0),
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            0
        );

        uint256 meInitialBalance = IERC20(collateralToken).balanceOf(me);
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));

        uint256 amount = 500 * ONE_COLLATERAL_TOKEN;

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            address(0),
            -toInt256(wdiv(amount, 10**IERC20Metadata(collateralToken).decimals())),
            0
        );

        assertEq(IERC20(collateralToken).balanceOf(me), meInitialBalance + amount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance - amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral - wadAmount);
    }

    function test_decreaseCollateral_send_to_user() public {
        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            address(0),
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            0
        );

        uint256 kakarotoInitialBalance = IERC20(collateralToken).balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));

        uint256 amount = 500 * ONE_COLLATERAL_TOKEN;

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            address(kakaroto),
            address(0),
            -toInt256(wdiv(amount, 10**IERC20Metadata(collateralToken).decimals())),
            0
        );

        assertEq(IERC20(collateralToken).balanceOf(address(kakaroto)), kakarotoInitialBalance + amount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance - amount);
        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral - wadAmount);
    }

    function test_increaseDebt() public {
        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            address(0),
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            0
        );

        uint256 meInitialBalance = fiat.balanceOf(me);
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));

        _modifyCollateralAndDebt(address(vault20Instance), collateralToken, address(0), me, 0, toInt256(500 * WAD));

        assertEq(fiat.balanceOf(me), meInitialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_increaseDebt_send_to_user() public {
        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            address(0),
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            0
        );

        uint256 kakarotoInitialBalance = fiat.balanceOf(address(kakaroto));
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            address(0),
            address(kakaroto),
            0,
            toInt256(500 * WAD)
        );

        assertEq(fiat.balanceOf(address(kakaroto)), kakarotoInitialBalance + (500 * WAD));
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), initialDebt + (500 * WAD));
    }

    function test_decreaseDebt() public {
        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            me,
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            toInt256(500 * WAD)
        );

        uint256 meInitialBalance = fiat.balanceOf(me);
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));

        _modifyCollateralAndDebt(address(vault20Instance), collateralToken, address(0), me, 0, -toInt256(200 * WAD));

        assertEq(fiat.balanceOf(me), meInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_decreaseDebt_accrues_interest() public {
        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            me,
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            toInt256(500 * WAD)
        );

        uint256 meInitialBalance = fiat.balanceOf(me);
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));

        vm.warp(block.timestamp + 31622400);

        publican.collect(address(vault20Instance));

        (, uint256 rate, , ) = codex.vaults(address(vault20Instance));

        _modifyCollateralAndDebt(address(vault20Instance), collateralToken, address(0), me, 0, -toInt256(200 * WAD));

        assertEq(fiat.balanceOf(me), meInitialBalance - wmul(200 * WAD, rate));
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), (initialDebt) - (200 * WAD));
    }

    function test_decreaseDebt_accrues_interest_close() public {
        vm.warp(block.timestamp + 1000);

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            me,
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            toInt256(500 * WAD)
        );

        (, uint256 rate1, , ) = codex.vaults(address(vault20Instance));
        assertEq(fiat.balanceOf(me), wmul(rate1, 500 * WAD));

        vm.warp(block.timestamp + 31622400);
        publican.collect(address(vault20Instance));

        (, uint256 rate2, , ) = codex.vaults(address(vault20Instance));
        uint256 interest = wmul(rate2, 500 * WAD) - wmul(rate1, 500 * WAD);
        codex.createUnbackedDebt(me, me, interest);
        codex.grantDelegate(address(moneta));
        moneta.exit(me, interest);

        _modifyCollateralAndDebt(address(vault20Instance), collateralToken, address(0), me, 0, -toInt256(500 * WAD));

        assertEq(fiat.balanceOf(me), 0);
        assertEq(codex.credit(address(userProxy)), 0);
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), 0);
    }

    function test_decreaseDebt_get_fiat_from() public {
        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            me,
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            toInt256(500 * WAD)
        );

        fiat.transfer(address(kakaroto), 500 * WAD);

        uint256 kakarotoInitialBalance = fiat.balanceOf(address(kakaroto));
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            address(0),
            address(kakaroto),
            0,
            -toInt256(200 * WAD)
        );

        assertEq(fiat.balanceOf(address(kakaroto)), kakarotoInitialBalance - (200 * WAD));
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), initialDebt - (200 * WAD));
    }

    function test_increaseCollateralAndIncreaseDebt() public {
        uint256 meInitialBalance = IERC20(collateralToken).balanceOf(me);
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        uint256 tokenAmount = 1000 * ONE_COLLATERAL_TOKEN;
        uint256 debtAmount = 500 * WAD;

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            me,
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            toInt256(500 * WAD)
        );

        assertEq(IERC20(collateralToken).balanceOf(me), meInitialBalance - tokenAmount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance + tokenAmount);
        uint256 wadAmount = wdiv(tokenAmount, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral + wadAmount);
        assertEq(fiat.balanceOf(me), fiatMeInitialBalance + debtAmount);
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), initialDebt + debtAmount);
    }

    function test_increaseCollateralAndIncreaseDebt_from_user() public {
        uint256 tokenAmount = 1000 * ONE_COLLATERAL_TOKEN;
        uint256 debtAmount = 500 * WAD;

        IERC20(collateralToken).transfer(address(kakaroto), tokenAmount);

        uint256 kakarotoInitialBalance = IERC20(collateralToken).balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            address(kakaroto),
            me,
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            toInt256(500 * WAD)
        );

        assertEq(IERC20(collateralToken).balanceOf(address(kakaroto)), kakarotoInitialBalance - tokenAmount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance + tokenAmount);
        uint256 wadAmount = wdiv(tokenAmount, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral + wadAmount);
        assertEq(fiat.balanceOf(me), fiatMeInitialBalance + debtAmount);
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), initialDebt + debtAmount);
    }

    function test_increaseCollateralAndIncreaseDebt_from_proxy_zero() public {
        uint256 tokenAmount = 1000 * ONE_COLLATERAL_TOKEN;
        uint256 debtAmount = 500 * WAD;

        IERC20(collateralToken).transfer(address(userProxy), tokenAmount);

        uint256 proxyInitialBalance = IERC20(collateralToken).balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            address(0),
            me,
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            toInt256(500 * WAD)
        );

        assertEq(IERC20(collateralToken).balanceOf(address(userProxy)), proxyInitialBalance - tokenAmount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance + tokenAmount);
        uint256 wadAmount = wdiv(tokenAmount, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral + wadAmount);
        assertEq(fiat.balanceOf(me), fiatMeInitialBalance + debtAmount);
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), initialDebt + debtAmount);
    }

    function test_increaseCollateralAndIncreaseDebt_from_proxy_address() public {
        uint256 tokenAmount = 1000 * ONE_COLLATERAL_TOKEN;
        uint256 debtAmount = 500 * WAD;

        IERC20(collateralToken).transfer(address(userProxy), tokenAmount);

        uint256 proxyInitialBalance = IERC20(collateralToken).balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            address(userProxy),
            me,
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            toInt256(500 * WAD)
        );

        assertEq(IERC20(collateralToken).balanceOf(address(userProxy)), proxyInitialBalance - tokenAmount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance + tokenAmount);
        uint256 wadAmount = wdiv(tokenAmount, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral + wadAmount);
        assertEq(fiat.balanceOf(me), fiatMeInitialBalance + debtAmount);
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), initialDebt + debtAmount);
    }

    function test_increaseCollateralAndIncreaseDebt_send_fiat_to_user() public {
        uint256 meInitialBalance = IERC20(collateralToken).balanceOf(me);
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));
        uint256 fiatKakarotoInitialBalance = fiat.balanceOf(address(kakaroto));

        uint256 tokenAmount = 1000 * ONE_COLLATERAL_TOKEN;
        uint256 debtAmount = 500 * WAD;

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            address(kakaroto),
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            toInt256(500 * WAD)
        );

        assertEq(IERC20(collateralToken).balanceOf(me), meInitialBalance - tokenAmount);
        assertEq(ERC20(collateralToken).balanceOf(address(vault20Instance)), vaultInitialBalance + tokenAmount);
        uint256 wadAmount = wdiv(tokenAmount, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral + wadAmount);
        assertEq(fiat.balanceOf(address(kakaroto)), fiatKakarotoInitialBalance + debtAmount);
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), initialDebt + debtAmount);
    }

    function test_decreaseDebtAndDecreaseCollateral() public {
        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            me,
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            toInt256(500 * WAD)
        );

        uint256 meInitialBalance = IERC20(collateralToken).balanceOf(me);
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            me,
            -toInt256(wdiv(300 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            -toInt256(100 * WAD)
        );

        assertEq(IERC20(collateralToken).balanceOf(me), meInitialBalance + (300 * ONE_COLLATERAL_TOKEN));
        assertEq(
            ERC20(collateralToken).balanceOf(address(vault20Instance)),
            vaultInitialBalance - (300 * ONE_COLLATERAL_TOKEN)
        );

        uint256 wadAmount = wdiv(300 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral - wadAmount);
        assertEq(fiat.balanceOf(me), fiatMeInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), initialDebt - (100 * WAD));
    }

    function test_decreaseDebtAndDecreaseCollateral_send_collateral_to_user() public {
        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            me,
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            toInt256(500 * WAD)
        );

        uint256 kakarotoInitialBalance = IERC20(collateralToken).balanceOf(address(kakaroto));
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));
        uint256 fiatMeInitialBalance = fiat.balanceOf(me);

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            address(kakaroto),
            me,
            -toInt256(wdiv(300 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            -toInt256(100 * WAD)
        );

        assertEq(
            IERC20(collateralToken).balanceOf(address(kakaroto)),
            kakarotoInitialBalance + (300 * ONE_COLLATERAL_TOKEN)
        );
        assertEq(
            ERC20(collateralToken).balanceOf(address(vault20Instance)),
            vaultInitialBalance - (300 * ONE_COLLATERAL_TOKEN)
        );

        uint256 wadAmount = wdiv(300 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral - wadAmount);
        assertEq(fiat.balanceOf(me), fiatMeInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), initialDebt - (100 * WAD));
    }

    function test_decreaseDebtAndDecreaseCollateral_get_fiat_from_user() public {
        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            me,
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            toInt256(500 * WAD)
        );
        uint256 meInitialBalance = IERC20(collateralToken).balanceOf(me);
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));

        fiat.transfer(address(kakaroto), 500 * WAD);
        uint256 fiatKakarotoInitialBalance = fiat.balanceOf(address(kakaroto));

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            address(kakaroto),
            -toInt256(wdiv(300 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            -toInt256(100 * WAD)
        );

        assertEq(IERC20(collateralToken).balanceOf(me), meInitialBalance + (300 * ONE_COLLATERAL_TOKEN));
        assertEq(
            ERC20(collateralToken).balanceOf(address(vault20Instance)),
            vaultInitialBalance - (300 * ONE_COLLATERAL_TOKEN)
        );

        uint256 wadAmount = wdiv(300 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral - wadAmount);
        assertEq(fiat.balanceOf(address(kakaroto)), fiatKakarotoInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), initialDebt - (100 * WAD));
    }

    function test_decreaseDebtAndDecreaseCollateral_get_fiat_from_proxy_zero() public {
        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            address(userProxy),
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            toInt256(500 * WAD)
        );

        uint256 meInitialBalance = IERC20(collateralToken).balanceOf(me);
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));

        // fiat.transfer(address(userProxy), 500 * WAD);
        uint256 fiatProxyInitialBalance = fiat.balanceOf(address(userProxy));

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            address(0),
            -toInt256(wdiv(300 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            -toInt256(100 * WAD)
        );

        assertEq(IERC20(collateralToken).balanceOf(me), meInitialBalance + (300 * ONE_COLLATERAL_TOKEN));
        assertEq(
            ERC20(collateralToken).balanceOf(address(vault20Instance)),
            vaultInitialBalance - (300 * ONE_COLLATERAL_TOKEN)
        );

        uint256 wadAmount = wdiv(300 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral - wadAmount);
        assertEq(fiat.balanceOf(address(userProxy)), fiatProxyInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), initialDebt - (100 * WAD));
    }

    function test_decreaseDebtAndDecreaseCollateral_get_fiat_from_proxy_address() public {
        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            address(userProxy),
            toInt256(wdiv(1000 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            toInt256(500 * WAD)
        );

        uint256 meInitialBalance = IERC20(collateralToken).balanceOf(me);
        uint256 vaultInitialBalance = IERC20(collateralToken).balanceOf(address(vault20Instance));
        uint256 initialCollateral = _collateral(address(vault20Instance), address(userProxy));
        uint256 initialDebt = _normalDebt(address(vault20Instance), address(userProxy));

        uint256 fiatProxyInitialBalance = fiat.balanceOf(address(userProxy));

        _modifyCollateralAndDebt(
            address(vault20Instance),
            collateralToken,
            me,
            address(userProxy),
            -toInt256(wdiv(300 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals())),
            -toInt256(100 * WAD)
        );

        assertEq(IERC20(collateralToken).balanceOf(me), meInitialBalance + (300 * ONE_COLLATERAL_TOKEN));
        assertEq(
            ERC20(collateralToken).balanceOf(address(vault20Instance)),
            vaultInitialBalance - (300 * ONE_COLLATERAL_TOKEN)
        );

        uint256 wadAmount = wdiv(300 * ONE_COLLATERAL_TOKEN, 10**IERC20Metadata(collateralToken).decimals());
        assertEq(_collateral(address(vault20Instance), address(userProxy)), initialCollateral - wadAmount);
        assertEq(fiat.balanceOf(address(userProxy)), fiatProxyInitialBalance - (100 * WAD));
        assertEq(_normalDebt(address(vault20Instance), address(userProxy)), initialDebt - (100 * WAD));
    }
}

interface IERC20Safe {
    function safeTransfer(address to, uint256 value) external;

    function safeTransferFrom(
        address from,
        address to,
        uint256 value
    ) external;
}

contract Vault20Actions_UnitTest_2 is Test {
    address codex = address(0xc0d311);
    address moneta = address(0x11101137a);
    address fiat = address(0xf1a7);

    //keccak256(abi.encode("mockVault"));
    address mockVault = address(0x4E0075d8C837f8fb999012e556b7A63FC65fceDa);

    //keccak256(abi.encode("mockCollateral"));
    address mockCollateral = address(0x624646310fa836B250c9285b044CB443c741f663);

    //keccak256(abi.encode("publican"));
    address publican = address(0xDF68e6705C6Cc25E78aAC874002B5ab31b679db4) ;

    PRBProxy userProxy;
    PRBProxyFactory prbProxyFactory;
    Vault20Actions vaultActions;

    address me = address(this);

    function setUp() public {
        prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        vaultActions = new Vault20Actions(address(codex), address(moneta), address(fiat), address(publican));

        vm.mockCall(fiat, abi.encodeWithSelector(ERC20.transferFrom.selector), abi.encode(bool(true)));

        vm.mockCall(fiat, abi.encodeWithSelector(ERC20.approve.selector), abi.encode(bool(true)));

        vm.mockCall(moneta, abi.encodeWithSelector(Moneta.enter.selector), abi.encode(bool(true)));
        
        // vaultExit
        vm.mockCall(mockVault, abi.encodeWithSelector(IVault.exit.selector), abi.encode(bool(true)));
        
        vm.mockCall(mockCollateral, abi.encodeWithSelector(IERC20Safe.safeTransfer.selector), abi.encode(bool(true)));

        vm.mockCall(mockVault, abi.encodeWithSelector(IVault.tokenScale.selector), abi.encode(uint256(10**6)));

        vm.mockCall(codex, abi.encodeWithSelector(Codex.modifyCollateralAndDebt.selector), abi.encode(bool(true)));

        vm.mockCall(publican, abi.encodeWithSelector(Publican.collect.selector), abi.encode(uint256(10**18)));
    }

    function testFail_increaseCollateral_when_vault_zero() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(0),
                address(mockCollateral),
                0,
                address(userProxy),
                me,
                address(0),
                1,
                0
            )
        );
    }

    function testFail_increaseCollateral_when_token_zero() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(mockVault),
                address(0),
                0,
                address(userProxy),
                me,
                address(0),
                1,
                0
            )
        );
    }

    function testFail_decreaseCollateral_when_vault_zero() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(0),
                address(mockCollateral),
                0,
                address(userProxy),
                me,
                address(0),
                -1,
                0
            )
        );
    }

    function testFail_decreaseCollateral_when_token_zero() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(mockVault),
                address(0),
                address(userProxy),
                me,
                me,
                address(0),
                -1,
                0
            )
        );
    }

    function testFail_decreaseCollateral_to_zero_address() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(mockVault),
                address(mockCollateral),
                0,
                address(userProxy),
                address(0),
                me,
                -1,
                0
            )
        );
    }

    function testFail_increaseDebt_to_zero_address() public {
        userProxy.execute(
            address(vaultActions),
            abi.encodeWithSelector(
                vaultActions.modifyCollateralAndDebt.selector,
                address(mockVault),
                address(mockCollateral),
                0,
                address(userProxy),
                me,
                address(0),
                0,
                1
            )
        );
    }
}
