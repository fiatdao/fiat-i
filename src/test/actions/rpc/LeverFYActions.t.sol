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
import {Flash} from "../../../core/Flash.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {toInt256, WAD, wdiv,wmul} from "../../../core/utils/Math.sol";

import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";

import {VaultEPT} from "../../../vaults/VaultEPT.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";

import {Caller} from "../../../test/utils/Caller.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";
import {VaultFY} from "../../../vaults/VaultFY.sol";
import {VaultFYActions} from "../../../actions/vault/VaultFYActions.sol";
import {LeverFYActions} from "../../../actions/lever/LeverFYActions.sol";
import {IBalancerVault} from "../../../actions/helper/ConvergentCurvePoolHelper.sol";

import {IVault} from "../../../interfaces/IVault.sol";
import {console} from "forge-std/console.sol";

contract LeverFYActions_RPC_tests is Test {
    Codex internal codex;
    Moneta internal moneta;

    PRBProxy internal userProxy;
    PRBProxyFactory internal prbProxyFactory;

    VaultFYActions internal vaultActions;
    VaultFactory internal vaultFactory;
    VaultFY internal impl;
    VaultFY internal implDAI;

    FIAT internal fiat;
    Collybus internal collybus;
    Publican internal publican;

    Caller internal user;
    address internal me = address(this);

    IVault internal fyUSDC2212Vault;
    IVault internal fyDAI2212Vault;

    Flash internal flash;

    LeverFYActions internal leverActions;

    IERC20 internal usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 internal dai = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);

    // Yield 
    address internal fyUSDC2212 = address(0x38b8BF13c94082001f784A642165517F8760988f);
    address internal fyUSDC2212LP = address(0xB2fff7FEA1D455F0BCdd38DA7DeE98af0872a13a);
    address internal fyDAI2212 = address(0xcDfBf28Db3B1B7fC8efE08f988D955270A5c4752);
    address internal fyDAI2212LP = address(0x52956Fb3DC3361fd24713981917f2B6ef493DCcC);
    
    uint256 internal ONE_USDC = 1e6;
    uint256 internal maturity = 1672412400;

    bytes32 internal fiatPoolId = 0x178e029173417b1f9c8bc16dcec6f697bc32374600000000000000000000025d;
    address internal fiatBalancerVault = address(0xBA12222222228d8Ba445958a75a0704d566BF2C8);


    function _mintUSDC(address to, uint256 amount) internal {
        // USDC minters
        vm.store(address(usdc), keccak256(abi.encode(address(this), uint256(12))), bytes32(uint256(1)));
        // USDC minterAllowed
        vm.store(
            address(usdc),
            keccak256(abi.encode(address(this), uint256(13))),
            bytes32(uint256(type(uint256).max))
        );
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(usdc).call(abi.encodeWithSignature(sig, to, amount));
        assert(ok);
    }

    function _mintDAI(address to, uint256 amount) internal {
        vm.store(address(dai), keccak256(abi.encode(address(address(this)), uint256(0))), bytes32(uint256(1)));
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(dai).call(abi.encodeWithSignature(sig, to, amount));
        assert(ok);
    }

    function _collateral(address vault, address user_) internal view returns (uint256) {
        (uint256 collateral, ) = codex.positions(vault, 0, user_);
        return collateral;
    }

    function _normalDebt(address vault, address user_) internal view returns (uint256) {
        (, uint256 normalDebt) = codex.positions(vault, 0, user_);
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

    function _buyCollateralAndIncreaseLever(
        address vault,
        address collateralizer,
        uint256 underlierAmount,
        uint256 deltaNormalDebt,
        LeverFYActions.SellFIATSwapParams memory fiatSwapParams,
        LeverFYActions.CollateralSwapParams memory collateralSwapParams
    ) internal {
        userProxy.execute(
            address(leverActions),
            abi.encodeWithSelector(
                leverActions.buyCollateralAndIncreaseLever.selector,
                vault,
                address(userProxy),
                collateralizer,
                underlierAmount,
                deltaNormalDebt,
                fiatSwapParams,
                collateralSwapParams
            )
        );
    }

    function _sellCollateralAndDecreaseLever(
        address vault,
        address collateralizer,
        uint256 fyTokenAmount,
        uint256 deltaNormalDebt,
        LeverFYActions.BuyFIATSwapParams memory fiatSwapParams,
        LeverFYActions.CollateralSwapParams memory collateralSwapParams
    ) internal {
        userProxy.execute(
            address(leverActions),
            abi.encodeWithSelector(
                leverActions.sellCollateralAndDecreaseLever.selector,
                vault,
                address(userProxy),
                collateralizer,
                fyTokenAmount,
                deltaNormalDebt,
                fiatSwapParams,
                collateralSwapParams
            )
        );
    }

    function _redeemCollateralAndDecreaseLever(
        address vault,
        address token,
        address collateralizer,
        uint256 fyTokenAmount,
        uint256 deltaNormalDebt,
        LeverFYActions.BuyFIATSwapParams memory fiatSwapParams
    ) internal {
        userProxy.execute(
            address(leverActions),
            abi.encodeWithSelector(
                leverActions.redeemCollateralAndDecreaseLever.selector,
                vault,
                token,
                address(userProxy),
                collateralizer,
                fyTokenAmount,
                deltaNormalDebt,
                fiatSwapParams
            )
        );
    }

    function _getCollateralSwapParams(
        address assetIn,
        address assetOut,
        uint256 minAssetOut,
        address yieldSpacePool
    ) internal pure returns (LeverFYActions.CollateralSwapParams memory collateralSwapParams) {
        collateralSwapParams.minAssetOut = minAssetOut;
        collateralSwapParams.yieldSpacePool = yieldSpacePool;
        collateralSwapParams.assetIn = assetIn;
        collateralSwapParams.assetOut = assetOut;
    }

    function _getSellFIATSwapParams(address assetOut, uint256 minAmountOut)
        internal
        view
        returns (LeverFYActions.SellFIATSwapParams memory fiatSwapParams)
    {
        fiatSwapParams.assetOut = assetOut;
        fiatSwapParams.minAmountOut = minAmountOut;
        fiatSwapParams.deadline = block.timestamp + 12 weeks;
    }

    function _getBuyFIATSwapParams(address assetIn, uint256 maxAmountIn)
        internal
        view
        returns (LeverFYActions.BuyFIATSwapParams memory fiatSwapParams)
    {
        fiatSwapParams.assetIn = assetIn;
        fiatSwapParams.maxAmountIn = maxAmountIn;
        fiatSwapParams.deadline = block.timestamp + 12 weeks;
    }

    function setUp() public {
        // Fork
        vm.createSelectFork(vm.rpcUrl("mainnet"), 16000000 ); 

        vaultFactory = new VaultFactory();
        fiat = FIAT(0x586Aa273F262909EEF8fA02d90Ab65F5015e0516);
        vm.startPrank(0xa55E0d3d697C4692e9C37bC3a7062b1bECeEF45B);
        fiat.allowCaller(fiat.ANY_SIG(), address(this));
        vm.stopPrank();
        codex = new Codex();
        publican = new Publican(address(codex));
        codex.allowCaller(codex.modifyRate.selector, address(publican));
        moneta = new Moneta(address(codex), address(fiat));
        fiat.allowCaller(fiat.mint.selector, address(moneta));
        collybus = new Collybus();
        prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        impl = new VaultFY(address(codex), address(usdc));
        fyUSDC2212Vault = IVault(
            vaultFactory.createVault(
                address(impl),
                abi.encode(address(fyUSDC2212), address(collybus))
            )
        );

        implDAI = new VaultFY(address(codex), address(dai));
        fyDAI2212Vault = IVault(
            vaultFactory.createVault(
                address(implDAI),
                abi.encode(address(fyDAI2212), address(collybus))
            )
        );

        vaultActions = new VaultFYActions(address(codex), address(moneta), address(fiat), address(publican));

        codex.allowCaller(codex.transferCredit.selector, address(moneta));

        // set Vaults
        codex.init(address(fyUSDC2212Vault));
        codex.init(address(fyDAI2212Vault));   
        codex.setParam("globalDebtCeiling", 10000000 ether);
        codex.setParam(address(fyUSDC2212Vault), "debtCeiling", 1000000 ether);
        collybus.setParam(address(fyUSDC2212Vault), "liquidationRatio", 1 ether);
        codex.setParam(address(fyDAI2212Vault), "debtCeiling", 1000000 ether);
        collybus.setParam(address(fyDAI2212Vault), "liquidationRatio", 1 ether);
        collybus.updateSpot(address(usdc), 1 ether);
        collybus.updateSpot(address(dai), 1 ether);
        publican.init(address(fyUSDC2212Vault));
        codex.allowCaller(codex.modifyBalance.selector, address(fyUSDC2212Vault));
        publican.init(address(fyDAI2212Vault));
        codex.allowCaller(codex.modifyBalance.selector, address(fyDAI2212Vault));

        // get USDC and DAI
        user = new Caller();
        _mintUSDC(address(user), 10000 * ONE_USDC);
        _mintUSDC(me, 10000 * ONE_USDC);
        _mintDAI(address(user), 10000 ether);
        _mintDAI(me, 10000 ether);

        flash = new Flash(address(moneta));
        fiat.allowCaller(fiat.mint.selector, address(moneta));
        flash.setParam("max", 1000000 * WAD);

        leverActions = new LeverFYActions(
            address(codex),
            address(fiat),
            address(flash),
            address(moneta),
            address(publican),
            fiatPoolId,
            fiatBalancerVault
        );

        codex.setParam("globalDebtCeiling", uint256(10000000 ether));
        codex.allowCaller(keccak256("ANY_SIG"), address(publican));
        codex.allowCaller(keccak256("ANY_SIG"), address(flash));

        IERC20(address(usdc)).approve(address(userProxy), type(uint256).max);
        IERC20(address(fyUSDC2212)).approve(address(userProxy), type(uint256).max);
        IERC20(address(fyUSDC2212LP)).approve(address(userProxy), type(uint256).max);

        IERC20(address(dai)).approve(address(userProxy), type(uint256).max);
        IERC20(address(fyDAI2212)).approve(address(userProxy), type(uint256).max);
        IERC20(address(fyDAI2212LP)).approve(address(userProxy), type(uint256).max);

        fiat.approve(address(userProxy), type(uint256).max);

        user.externalCall(
            address(usdc),
            abi.encodeWithSelector(usdc.approve.selector, address(userProxy), type(uint256).max)
        );
        user.externalCall(
            address(dai),
            abi.encodeWithSelector(dai.approve.selector, address(userProxy), type(uint256).max)
        );
    }

    function test_buyCollateralAndIncreaseLever_simple() public {
        uint256 lendFIAT = 1000 * WAD;
        uint256 upfrontUnderlier = 1000 * ONE_USDC;
        uint256 totalUnderlier = 2000 * ONE_USDC;

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(usdc), totalUnderlier - upfrontUnderlier - 5 * ONE_USDC), // borrowed underliers - fees
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP)) // swap all for fyTokens
        );
        
        assertGe(_collateral(address(fyUSDC2212Vault), address(userProxy)), 2000 * WAD);
        assertGe(_normalDebt(address(fyUSDC2212Vault), address(userProxy)), 1000 * WAD);
    }

    function test_buyCollateralAndIncreaseLever_DAI_simple() public {
        uint256 lendFIAT = 1000 * WAD;
        uint256 upfrontUnderlier = 1000 * WAD;
        uint256 totalUnderlier = 2000 * WAD;
        
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyDAI2212LP));

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(dai), totalUnderlier - upfrontUnderlier - 5 ether), // borrowed underliers - fees
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP)) // swap all for fyTokens
        );
        
        assertGe(_collateral(address(fyDAI2212Vault), address(userProxy)), 2000 * WAD - 5 ether);
        assertGe(_normalDebt(address(fyDAI2212Vault), address(userProxy)), 1000 * WAD);
        // already formatted
        assertEq(WAD,fyDAI2212Vault.underlierScale());
        assertApproxEqAbs(estDeltaCollateral-5 ether,IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)), 2 ether); // approx 2 DAI delta
    }

    function test_buyCollateralAndIncreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;

        uint256 meInitialBalance = usdc.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));
        assertEq(initialCollateral,0);
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyUSDC2212LP));

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(usdc), totalUnderlier - upfrontUnderlier - 10 * ONE_USDC), // borrowed underliers - fees
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP)) // swap all for fyTokens
        );

        assertEq(usdc.balanceOf(me), meInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)),
            vaultInitialBalance + (estDeltaCollateral - 10 * ONE_USDC) // subtract fees
        );
        assertGe(
            _collateral(address(fyUSDC2212Vault), address(userProxy)),
            wdiv(estDeltaCollateral, 10 * fyUSDC2212Vault.tokenScale()) - WAD // subtract fees
        );
        assertApproxEqAbs(estDeltaCollateral-5 * ONE_USDC,IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), 5 * ONE_USDC); // approx 5 USDC delta
    }

    function test_buyCollateralAndIncreaseLever_DAI() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;

        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));
        assertEq(initialCollateral,0);
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyDAI2212LP));

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(dai), totalUnderlier - upfrontUnderlier - 10 * WAD), // borrowed underliers - fees
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP)) // swap all for fyTokens
        );

        assertEq(dai.balanceOf(me), meInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)),
            vaultInitialBalance + (estDeltaCollateral - 10 * WAD) // subtract fees
        );
        assertGe(
            _collateral(address(fyDAI2212Vault), address(userProxy)),
            wdiv(estDeltaCollateral, 10 * fyDAI2212Vault.tokenScale()) - WAD // subtract fees
        );
        assertApproxEqAbs(estDeltaCollateral-5 * WAD,IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)), 5 * WAD); // approx 5 DAI delta
    }

    function test_buyCollateralAndIncreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        usdc.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = usdc.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));

        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyUSDC2212LP));

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(usdc), totalUnderlier - upfrontUnderlier - 5 * ONE_USDC), // borrowed underliers - fees
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP)) // swap all for fyTokens
        );

        assertEq(usdc.balanceOf(address(user)), userInitialBalance - upfrontUnderlier);
        assertGe(
            ERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)),
            vaultInitialBalance + (estDeltaCollateral - 5 * ONE_USDC) // subtract fees
        );
        assertGe(
            _collateral(address(fyUSDC2212Vault), address(userProxy)),
             wdiv(estDeltaCollateral, 10 * fyUSDC2212Vault.tokenScale()) - WAD // subtract fees
        );
    }

    function test_buyCollateralAndIncreaseLever_for_user_DAI() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        dai.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = dai.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        assertEq(vaultInitialBalance,0);

        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyDAI2212LP));

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(dai), totalUnderlier - upfrontUnderlier - 5 * WAD), // borrowed underliers - fees
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP)) // swap all for fyTokens
        );

        assertEq(dai.balanceOf(address(user)), userInitialBalance - upfrontUnderlier);
        assertApproxEqAbs(estDeltaCollateral-5 * WAD,IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)), 5 * WAD); // approx 5 DAI delta
    }

    function test_buyCollateralAndIncreaseLever_for_zero_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        assertEq(vaultInitialBalance,0);
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));
        assertEq(initialCollateral,0);
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyUSDC2212LP));

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(usdc), totalUnderlier - upfrontUnderlier - 5 * ONE_USDC), // borrowed underliers - fees
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP)) // swap all for fyTokens
        );

        assertEq(usdc.balanceOf(address(userProxy)), userProxyInitialBalance - upfrontUnderlier);
        assertApproxEqAbs(estDeltaCollateral-5 * ONE_USDC,IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), 5 * ONE_USDC); // approx 5 USDC delta
    }

    function test_buyCollateralAndIncreaseLever_for_zero_proxy_DAI() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        assertEq(vaultInitialBalance,0);
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));
        assertEq(initialCollateral,0);
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyDAI2212LP));

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(dai), totalUnderlier - upfrontUnderlier - 5 * WAD), // borrowed underliers - fees
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP)) // swap all for fyTokens
        );
        assertEq(dai.balanceOf(address(userProxy)), userProxyInitialBalance - upfrontUnderlier);
        assertApproxEqAbs(estDeltaCollateral-5 * WAD,IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)), 5 * WAD); // approx 5 DAI delta
    }

    function test_buyCollateralAndIncreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        assertEq(vaultInitialBalance,0);
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));
        assertEq(initialCollateral,0);
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyUSDC2212LP));

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(usdc), totalUnderlier - upfrontUnderlier - 5 * ONE_USDC), // borrowed underliers - fees
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP)) // swap all for fyTokens
        );

        assertEq(usdc.balanceOf(address(userProxy)), userProxyInitialBalance - upfrontUnderlier);
        assertApproxEqAbs(estDeltaCollateral-5 * ONE_USDC,IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), 5 * ONE_USDC); // approx 5 USDC delta
    }

    function test_buyCollateralAndIncreaseLever_for_proxy_DAI() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));
        assertEq(initialCollateral,0);
        assertEq(vaultInitialBalance,0);

        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyDAI2212LP));

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(dai), totalUnderlier - upfrontUnderlier - 5 * WAD), // borrowed underliers - fees
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP)) // swap all for fyTokens
        );

        assertEq(dai.balanceOf(address(userProxy)), userProxyInitialBalance - upfrontUnderlier);
        assertApproxEqAbs(estDeltaCollateral- 5 * WAD,IERC20(address(fyDAI2212)).balanceOf(address(fyDAI2212Vault)), 5 * WAD); // approx 5 DAI delta
    }

    function test_sellCollateralAndDecreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;

        uint256 meInitialBalance = usdc.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));
        uint256 estDeltaCollateral = leverActions.underlierToFYToken(totalUnderlier, address(fyUSDC2212LP));

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(usdc), totalUnderlier - upfrontUnderlier - 5 * ONE_USDC),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        assertApproxEqAbs(estDeltaCollateral-5 * ONE_USDC,IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), 5 * ONE_USDC); // approx 5 USDC delta

        uint256 fyTokenAmount = _collateral(address(fyUSDC2212Vault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(fyUSDC2212Vault), address(userProxy));
        uint256 sellCollateral = wmul(fyTokenAmount,fyUSDC2212Vault.tokenScale());
        uint256 estSellDeltaCollateral = leverActions.fyTokenToUnderlier(sellCollateral, address(fyUSDC2212LP));

        _sellCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            me,
            sellCollateral,
            normalDebt,
            _getBuyFIATSwapParams(address(usdc), normalDebt),
            _getCollateralSwapParams(address(fyUSDC2212), address(usdc), 0, address(fyUSDC2212LP))
        );

        assertGt(usdc.balanceOf(me), meInitialBalance - 5 * ONE_USDC); // subtract fees / rounding errors
        assertEq(IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
        assertEq(IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)),0);
        // approx 17 USDC from fees and slippage (when selling fyToken before maturity)
        assertApproxEqAbs(estSellDeltaCollateral,totalUnderlier, 17 * ONE_USDC);
    }

    function test_sellCollateralAndDecreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        usdc.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = usdc.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(usdc), totalUnderlier - upfrontUnderlier - 5 * ONE_USDC),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        uint256 fyTokenAmount = _collateral(address(fyUSDC2212Vault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(fyUSDC2212Vault), address(userProxy));
        uint256 sellCollateral = wmul(fyTokenAmount,fyUSDC2212Vault.tokenScale());
        uint256 estSellDeltaCollateral = leverActions.fyTokenToUnderlier(sellCollateral, address(fyUSDC2212LP));

        _sellCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            address(user),
            sellCollateral,
            normalDebt,
            _getBuyFIATSwapParams(address(usdc), normalDebt),
            _getCollateralSwapParams(address(fyUSDC2212),address(usdc), 0, address(fyUSDC2212LP))
        );

        assertGt(usdc.balanceOf(address(user)), userInitialBalance - 5 * ONE_USDC); // subtract fees / rounding errors
        assertEq(IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
        // approx 17 USDC from fees and slippage (when selling fyToken before maturity)
        assertApproxEqAbs(estSellDeltaCollateral,totalUnderlier, 17 * ONE_USDC);
    }

    function test_sellCollateralAndDecreaseLever_for_zero_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(usdc), totalUnderlier - upfrontUnderlier - 5 * ONE_USDC),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        uint256 fyTokenAmount = _collateral(address(fyUSDC2212Vault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(fyUSDC2212Vault), address(userProxy));
        uint256 sellCollateral = wmul(fyTokenAmount,fyUSDC2212Vault.tokenScale());
        uint256 estSellDeltaCollateral = leverActions.fyTokenToUnderlier(sellCollateral, address(fyUSDC2212LP));

        _sellCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            address(0),
            sellCollateral,
            normalDebt,
            _getBuyFIATSwapParams(address(usdc), normalDebt),
            _getCollateralSwapParams(address(fyUSDC2212),address(usdc), 0, address(fyUSDC2212LP))
        );

        assertGt(usdc.balanceOf(address(userProxy)), userProxyInitialBalance - 5 * ONE_USDC); // subtract fees / rounding errors
        assertEq(IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
        assertApproxEqAbs(estSellDeltaCollateral,totalUnderlier, 17 * ONE_USDC);
    }

    function test_sellCollateralAndDecreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(usdc), totalUnderlier - upfrontUnderlier - 5 * ONE_USDC),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        uint256 fyTokenAmount = _collateral(address(fyUSDC2212Vault), address(userProxy));
        uint256 normalDebt = _normalDebt(address(fyUSDC2212Vault), address(userProxy));
        uint256 sellCollateral = wmul(fyTokenAmount,fyUSDC2212Vault.tokenScale());
        uint256 estSellDeltaCollateral = leverActions.fyTokenToUnderlier(sellCollateral, address(fyUSDC2212LP));

        _sellCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            address(userProxy),
            sellCollateral,
            normalDebt,
            _getBuyFIATSwapParams(address(usdc), normalDebt),
            _getCollateralSwapParams(address(fyUSDC2212),address(usdc), 0, address(fyUSDC2212LP))
        );

        assertGt(usdc.balanceOf(address(userProxy)), userProxyInitialBalance - 5 * ONE_USDC); // subtract fees / rounding errors
        assertEq(IERC20(address(fyUSDC2212)).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
        assertApproxEqAbs(estSellDeltaCollateral,totalUnderlier, 17 * ONE_USDC);
    }

    function test_redeemCollateralAndDecreaseLever() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;

        uint256 meInitialBalance = usdc.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(usdc), totalUnderlier - upfrontUnderlier - 5 * ONE_USDC),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        assertLt(usdc.balanceOf(me), meInitialBalance);
        assertGt(IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(_collateral(address(fyUSDC2212Vault), address(userProxy)),fyUSDC2212Vault.tokenScale());
        uint256 normalDebt = _normalDebt(address(fyUSDC2212Vault), address(userProxy));

        vm.warp(maturity);

        _redeemCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            fyUSDC2212Vault.token(),
            me,
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(usdc),normalDebt)
        );

        assertGt(usdc.balanceOf(me), meInitialBalance);
        assertEq(ERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_DAI() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;

        uint256 meInitialBalance = dai.balanceOf(me);
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            me,
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(dai), totalUnderlier - upfrontUnderlier - 5 * WAD),
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP))
        );

        assertLt(dai.balanceOf(me), meInitialBalance);
        assertGt(IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(_collateral(address(fyDAI2212Vault), address(userProxy)),fyDAI2212Vault.tokenScale());
        uint256 normalDebt = _normalDebt(address(fyDAI2212Vault), address(userProxy));

        vm.warp(maturity);

        _redeemCollateralAndDecreaseLever(
            address(fyDAI2212Vault),
            fyDAI2212Vault.token(),
            me,
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(dai), normalDebt)
        );

        assertGt(dai.balanceOf(me), meInitialBalance);
        assertEq(ERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_user() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        usdc.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = usdc.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(usdc), totalUnderlier - upfrontUnderlier - 5 * ONE_USDC),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        assertLt(usdc.balanceOf(address(user)), userInitialBalance);
        assertGt(IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(_collateral(address(fyUSDC2212Vault), address(userProxy)),fyUSDC2212Vault.tokenScale());
        uint256 normalDebt = _normalDebt(address(fyUSDC2212Vault), address(userProxy));

        vm.warp(maturity);

        _redeemCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            fyUSDC2212Vault.token(),
            address(user),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(usdc),normalDebt)
        );

        assertGt(usdc.balanceOf(address(user)), userInitialBalance);
        assertEq(ERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_user_DAI() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        dai.transfer(address(user), upfrontUnderlier);

        uint256 userInitialBalance = dai.balanceOf(address(user));
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            address(user),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(dai), totalUnderlier - upfrontUnderlier - 5 * WAD),
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP))
        );

        assertLt(dai.balanceOf(address(user)), userInitialBalance);
        assertGt(IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(_collateral(address(fyDAI2212Vault), address(userProxy)),fyDAI2212Vault.tokenScale());
        uint256 normalDebt = _normalDebt(address(fyDAI2212Vault), address(userProxy));

        vm.warp(maturity);

        _redeemCollateralAndDecreaseLever(
            address(fyDAI2212Vault),
            fyDAI2212Vault.token(),
            address(user),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(dai),normalDebt)
        );

        assertGt(dai.balanceOf(address(user)), userInitialBalance);
        assertEq(ERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_zero_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(usdc), totalUnderlier - upfrontUnderlier - 5 * ONE_USDC),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        assertLt(usdc.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertGt(IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(_collateral(address(fyUSDC2212Vault), address(userProxy)),fyUSDC2212Vault.tokenScale());
        uint256 normalDebt = _normalDebt(address(fyUSDC2212Vault), address(userProxy));

        vm.warp(maturity);

        _redeemCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            fyUSDC2212Vault.token(),
            address(0),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(usdc),normalDebt)
        );

        assertGt(usdc.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertEq(ERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_zero_proxy_DAI() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            address(0),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(dai), totalUnderlier - upfrontUnderlier - 5 * WAD),
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP))
        );

        assertLt(dai.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertGt(IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(_collateral(address(fyDAI2212Vault), address(userProxy)),fyDAI2212Vault.tokenScale());
        uint256 normalDebt = _normalDebt(address(fyDAI2212Vault), address(userProxy));

        vm.warp(maturity);

        _redeemCollateralAndDecreaseLever(
            address(fyDAI2212Vault),
            fyDAI2212Vault.token(),
            address(0),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(dai),normalDebt)
        );

        assertGt(dai.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertEq(ERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_proxy() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * ONE_USDC;
        uint256 totalUnderlier = 600 * ONE_USDC;
        usdc.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = usdc.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault));
        uint256 initialCollateral = _collateral(address(fyUSDC2212Vault), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(fyUSDC2212Vault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(usdc), totalUnderlier - upfrontUnderlier - 5 * ONE_USDC),
            _getCollateralSwapParams(address(usdc), address(fyUSDC2212), 0, address(fyUSDC2212LP))
        );

        assertLt(usdc.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertGt(IERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(_collateral(address(fyUSDC2212Vault), address(userProxy)),fyUSDC2212Vault.tokenScale());
        uint256 normalDebt = _normalDebt(address(fyUSDC2212Vault), address(userProxy));

        vm.warp(maturity);

        _redeemCollateralAndDecreaseLever(
            address(fyUSDC2212Vault),
            fyUSDC2212Vault.token(),
            address(userProxy),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(usdc),normalDebt)
        );

        assertGt(usdc.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertEq(ERC20(fyUSDC2212).balanceOf(address(fyUSDC2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyUSDC2212Vault), address(userProxy)), initialCollateral);
    }

    function test_redeemCollateralAndDecreaseLever_for_proxy_DAI() public {
        uint256 lendFIAT = 500 * WAD;
        uint256 upfrontUnderlier = 100 * WAD;
        uint256 totalUnderlier = 600 * WAD;
        dai.transfer(address(userProxy), upfrontUnderlier);

        uint256 userProxyInitialBalance = dai.balanceOf(address(userProxy));
        uint256 vaultInitialBalance = IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault));
        uint256 initialCollateral = _collateral(address(fyDAI2212Vault), address(userProxy));

        _buyCollateralAndIncreaseLever(
            address(fyDAI2212Vault),
            address(userProxy),
            upfrontUnderlier,
            lendFIAT,
            _getSellFIATSwapParams(address(dai), totalUnderlier - upfrontUnderlier - 5 * WAD),
            _getCollateralSwapParams(address(dai), address(fyDAI2212), 0, address(fyDAI2212LP))
        );

        assertLt(dai.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertGt(IERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertGt(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);

        uint256 fyTokenAmount = wmul(_collateral(address(fyDAI2212Vault), address(userProxy)),fyDAI2212Vault.tokenScale());
        uint256 normalDebt = _normalDebt(address(fyDAI2212Vault), address(userProxy));

        vm.warp(maturity);

        _redeemCollateralAndDecreaseLever(
            address(fyDAI2212Vault),
            fyDAI2212Vault.token(),
            address(userProxy),
            fyTokenAmount,
            normalDebt,
            _getBuyFIATSwapParams(address(dai),normalDebt)
        );

        assertGt(dai.balanceOf(address(userProxy)), userProxyInitialBalance);
        assertEq(ERC20(fyDAI2212).balanceOf(address(fyDAI2212Vault)), vaultInitialBalance);
        assertEq(_collateral(address(fyDAI2212Vault), address(userProxy)), initialCollateral);
    }

    function test_underlierToFYToken() external {
        uint256 fyTokenAmountNow = leverActions.underlierToFYToken(100 * ONE_USDC, address(fyUSDC2212LP));
        assertGt(fyTokenAmountNow, 0);
        // advance some months
        vm.warp(block.timestamp + 10 days);
        uint256 fyTokenAmountBeforeMaturity = leverActions.underlierToFYToken(100 * ONE_USDC, address(fyUSDC2212LP));
        // closest to the maturity we get less sPT for same underlier amount
        assertGt(fyTokenAmountNow, fyTokenAmountBeforeMaturity);

    }

    function test_fyTokenToUnderlier() external {
        uint256 underlierNow = leverActions.fyTokenToUnderlier(100 * ONE_USDC,address(fyUSDC2212LP));
        assertGt(underlierNow, 0);

        // advance some months
        vm.warp(block.timestamp + 10 days);
        uint256 underlierBeforeMaturity = leverActions.fyTokenToUnderlier(100 * ONE_USDC,address(fyUSDC2212LP));
        // closest to the maturity we get more underlier for same sPT
        assertGt(underlierBeforeMaturity, underlierNow);
    }
}
