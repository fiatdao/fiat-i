// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PRBProxyFactory} from "proxy/contracts/PRBProxyFactory.sol";
import {PRBProxy} from "proxy/contracts/PRBProxy.sol";
import {IVault} from "../../../interfaces/IVault.sol";
import {Aer} from "../../../core/Aer.sol";
import {Codex} from "../../../core/Codex.sol";
import {NoLossCollateralAuction} from "../../../core/auctions/NoLossCollateralAuction.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {Limes} from "../../../core/Limes.sol";
import {LinearDecrease} from "../../../core/auctions/PriceCalculator.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {Publican} from "../../../core/Publican.sol";
import {Vault20} from "../../../vaults/Vault.sol";
import {toInt256, WAD, sub, wdiv} from "../../../core/utils/Math.sol";

import {VaultFactory} from "../../../vaults/VaultFactory.sol";
import {VaultEPT} from "../../../vaults/VaultEPT.sol";
import {NoLossCollateralAuctionEPTActions} from "../../../actions/auction/NoLossCollateralAuctionEPTActions.sol";

interface ITrancheFactory {
    function deployTranche(uint256 expiration, address wpAddress) external returns (address);
}

interface ITranche {
    function balanceOf(address owner) external view returns (uint256);

    function deposit(uint256 shares, address destination) external returns (uint256, uint256);

    function approve(address who, uint256 amount) external;
}

interface ICCP {
    function getPoolId() external view returns (bytes32);

    function getVault() external view returns (address);
}

contract NoLossCollateralAuctionEPTActions_UnitTest is Test {
    Codex internal codex;
    Moneta internal moneta;
    PRBProxy internal userProxy;
    PRBProxyFactory internal prbProxyFactory;
    VaultFactory internal vaultFactory;

    FIAT internal fiat;
    Collybus internal collybus;
    Publican internal publican;
    Aer internal aer;
    NoLossCollateralAuction internal collateralAuction;
    Limes internal limes;
    NoLossCollateralAuctionEPTActions internal auctionActions;

    address internal me = address(this);
    uint256 internal ONE_USDC = 1e6;
    uint256 internal maturity = 1639727861; // 17 DEC 21
    IERC20 internal underlierUSDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    // Element
    VaultEPT internal vaultYUSDC_V4_impl;
    VaultEPT internal vault_yvUSDC_17DEC21;

    ITrancheFactory internal trancheFactory = ITrancheFactory(0x62F161BF3692E4015BefB05A03a94A40f520d1c0);
    address internal wrappedPositionYUSDC = address(0xdEa04Ffc66ECD7bf35782C70255852B34102C3b0);
    ITranche internal trancheUSDC_V4_yvUSDC_17DEC21 = ITranche(address(0x76a34D72b9CF97d972fB0e390eB053A37F211c74));
    address internal ccp_yvUSDC_17DEC21 = address(0x90CA5cEf5B29342b229Fb8AE2DB5d8f4F894D652);

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 13700000);

        vaultFactory = new VaultFactory();
        fiat = new FIAT();
        codex = new Codex();
        publican = new Publican(address(codex));
        codex.allowCaller(codex.modifyRate.selector, address(publican));
        moneta = new Moneta(address(codex), address(fiat));
        fiat.allowCaller(fiat.mint.selector, address(moneta));
        collybus = new Collybus();
        aer = new Aer(address(codex), address(0), address(0));
        limes = new Limes(address(codex));
        collateralAuction = new NoLossCollateralAuction(address(codex), address(limes));
        LinearDecrease calculator = new LinearDecrease();
        prbProxyFactory = new PRBProxyFactory();
        userProxy = PRBProxy(prbProxyFactory.deployFor(me));

        // Element
        vaultYUSDC_V4_impl = new VaultEPT(
            address(codex),
            wrappedPositionYUSDC,
            address(0x62F161BF3692E4015BefB05A03a94A40f520d1c0)
        );
        _mintUSDC(me, 2000000 * ONE_USDC);

        underlierUSDC.approve(address(trancheUSDC_V4_yvUSDC_17DEC21), type(uint256).max);
        trancheUSDC_V4_yvUSDC_17DEC21.deposit(1000 * ONE_USDC, me);

        address instance = vaultFactory.createVault(
            address(vaultYUSDC_V4_impl),
            abi.encode(address(trancheUSDC_V4_yvUSDC_17DEC21), address(collybus), ccp_yvUSDC_17DEC21)
        );
        vault_yvUSDC_17DEC21 = VaultEPT(instance);

        // set Vault
        codex.init(address(vault_yvUSDC_17DEC21));
        codex.allowCaller(codex.transferCredit.selector, address(moneta));
        codex.setParam("globalDebtCeiling", 500 ether);
        codex.setParam(address(vault_yvUSDC_17DEC21), "debtCeiling", 500 ether);
        collybus.setParam(address(vault_yvUSDC_17DEC21), "liquidationRatio", 1 ether);
        collybus.updateSpot(address(underlierUSDC), 1 ether);
        publican.init(address(vault_yvUSDC_17DEC21));
        codex.allowCaller(codex.modifyBalance.selector, address(vault_yvUSDC_17DEC21));

        calculator.setParam(bytes32("duration"), 100000);

        collateralAuction.init(address(vault_yvUSDC_17DEC21), address(collybus));
        collateralAuction.setParam(address(vault_yvUSDC_17DEC21), bytes32("maxAuctionDuration"), 200000);
        collateralAuction.setParam(address(vault_yvUSDC_17DEC21), bytes32("calculator"), address(calculator));
        collateralAuction.allowCaller(collateralAuction.ANY_SIG(), address(limes));

        limes.setParam(bytes32("globalMaxDebtOnAuction"), 500e18);
        limes.setParam(bytes32("aer"), address(aer));
        limes.setParam(address(vault_yvUSDC_17DEC21), bytes32("liquidationPenalty"), WAD);
        limes.setParam(address(vault_yvUSDC_17DEC21), bytes32("maxDebtOnAuction"), 500e18);
        limes.setParam(address(vault_yvUSDC_17DEC21), bytes32("collateralAuction"), address(collateralAuction));
        limes.allowCaller(limes.ANY_SIG(), address(collateralAuction));

        aer.allowCaller(aer.ANY_SIG(), address(limes));
        aer.allowCaller(aer.ANY_SIG(), address(collateralAuction));

        codex.allowCaller(codex.ANY_SIG(), address(moneta));
        codex.allowCaller(codex.ANY_SIG(), address(vault_yvUSDC_17DEC21));
        codex.allowCaller(codex.ANY_SIG(), address(limes));
        codex.allowCaller(codex.ANY_SIG(), address(collateralAuction));

        underlierUSDC.approve(address(userProxy), type(uint256).max);
        trancheUSDC_V4_yvUSDC_17DEC21.approve(address(vault_yvUSDC_17DEC21), type(uint256).max);

        vault_yvUSDC_17DEC21.enter(0, me, trancheUSDC_V4_yvUSDC_17DEC21.balanceOf(me));

        codex.modifyCollateralAndDebt(address(vault_yvUSDC_17DEC21), 0, me, me, me, 900e18, 500e18);
        // update price so we can liquidate
        collybus.updateSpot(address(underlierUSDC), 0.4 ether);

        limes.liquidate(address(vault_yvUSDC_17DEC21), 0, me, me);

        // re-update price
        collybus.updateSpot(address(underlierUSDC), 1 ether);

        auctionActions = new NoLossCollateralAuctionEPTActions(
            address(codex),
            address(moneta),
            address(fiat),
            address(collateralAuction)
        );

        fiat.allowCaller(keccak256("ANY_SIG"), address(moneta));

        codex.grantDelegate(address(moneta));
        moneta.exit(me, 100e18);

        fiat.approve(address(userProxy), 100e18);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(auctionActions.approveFIAT.selector, address(moneta), 100e18)
        );
    }

    function _mintUSDC(address to, uint256 amount) internal {
        // USDC minters
        vm.store(address(underlierUSDC), keccak256(abi.encode(address(this), uint256(12))), bytes32(uint256(1)));
        // USDC minterAllowed
        vm.store(
            address(underlierUSDC),
            keccak256(abi.encode(address(this), uint256(13))),
            bytes32(uint256(type(uint256).max))
        );
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(underlierUSDC).call(abi.encodeWithSignature(sig, to, amount));
        assert(ok);
    }

    function _collateral(address vault, address user) internal view returns (uint256) {
        (uint256 collateral, ) = codex.positions(vault, 0, user);
        return collateral;
    }

    function _normalDebt(address vault, address user) internal view returns (uint256) {
        (, uint256 normalDebt) = codex.positions(vault, 0, user);
        return normalDebt;
    }

    function _balance(address vault, address user) internal view returns (uint256) {
        return codex.balances(vault, 0, user);
    }

    function _getSwapParams(
        address assetIn,
        address assetOut,
        uint256 minOutput
    ) internal view returns (NoLossCollateralAuctionEPTActions.SwapParams memory swapParams) {
        swapParams.balancerVault = ICCP(ccp_yvUSDC_17DEC21).getVault();
        swapParams.poolId = ICCP(ccp_yvUSDC_17DEC21).getPoolId();
        swapParams.assetIn = assetIn;
        swapParams.assetOut = assetOut;
        swapParams.minOutput = minOutput;
        swapParams.deadline = block.timestamp + 12 weeks;
    }

    function test_takeCollateral() public {
        collateralAuction.redoAuction(1, me);
        fiat.transfer(address(userProxy), 100e18);

        uint256 fiatBalance = fiat.balanceOf(address(userProxy));
        uint256 collateralBalance = _balance(address(vault_yvUSDC_17DEC21), address(userProxy));
        assertEq(collateralBalance, 0);
       
        vm.warp(block.timestamp + 100);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateral.selector,
                address(vault_yvUSDC_17DEC21),
                0,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy)
            )
        );
        // the collateral is still in FIAT system
        assertGt(_balance(address(vault_yvUSDC_17DEC21), address(userProxy)), collateralBalance);
        // should have refunded excess FIAT
        assertGt(fiat.balanceOf(address(userProxy)), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(address(userProxy)));
        
    }

    function test_takeCollateral_from_user_BEFORE_maturity() public {
        collateralAuction.redoAuction(1, me);
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = _balance(address(vault_yvUSDC_17DEC21), me);

        vm.warp(block.timestamp + 100);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateral.selector,
                address(vault_yvUSDC_17DEC21),
                0,
                me,
                1,
                100e18,
                1e18,
                me
            )
        );
        // the collateral is still in FIAT system
        assertGt(_balance(address(vault_yvUSDC_17DEC21), me), collateralBalance);
        // should have refunded excess FIAT
        assertGt(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(me));
        

    }

    function test_takeCollateral_from_user_AFTER_maturity() public {
        vm.warp(maturity + 3600 * 24 * 20);
        collateralAuction.redoAuction(1, me);
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = _balance(address(vault_yvUSDC_17DEC21), me);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateral.selector,
                address(vault_yvUSDC_17DEC21),
                0,
                me,
                1,
                100e18,
                1e18,
                me
            )
        );
        // the collateral is still in FIAT system
        assertGt(_balance(address(vault_yvUSDC_17DEC21), me), collateralBalance);
        // all FIAT was used
        assertEq(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(me));
    }

    function test_takeCollateralAndSwapForUnderlier_BEFORE_maturity() public {
        fiat.transfer(address(userProxy), 100e18);
        uint256 fiatBalance = fiat.balanceOf(address(userProxy));
        uint256 collateralBalance = trancheUSDC_V4_yvUSDC_17DEC21.balanceOf(address(userProxy));
        assertEq(collateralBalance, 0);

        collateralAuction.redoAuction(1, me);
        vm.warp(block.timestamp + 200);
        assertEq(underlierUSDC.balanceOf(address(userProxy)), 0);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndSwapForUnderlier.selector,
                address(vault_yvUSDC_17DEC21),
                0,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy),
                _getSwapParams(address(trancheUSDC_V4_yvUSDC_17DEC21), address(underlierUSDC), 0)
            )
        );
        // we have more USDC than before
        assertGt(underlierUSDC.balanceOf(address(userProxy)), 0);
        // should have refunded excess FIAT
        assertGt(fiat.balanceOf(address(userProxy)), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(address(userProxy)));
        // No collateral left
        assertEq(_balance(address(vault_yvUSDC_17DEC21), address(auctionActions)), 0);
        assertEq(collateralBalance, trancheUSDC_V4_yvUSDC_17DEC21.balanceOf(address(userProxy)));
    }

    function test_takeCollateralAndSwapForUnderlier_from_user_BEFORE_maturity() public {
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = trancheUSDC_V4_yvUSDC_17DEC21.balanceOf(me);
        assertEq(fiatBalance, 100e18);
        assertEq(collateralBalance, 0);

        
        collateralAuction.redoAuction(1, me);
        vm.warp(block.timestamp + 100);

        uint256 usdcBefore = underlierUSDC.balanceOf(me);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndSwapForUnderlier.selector,
                address(vault_yvUSDC_17DEC21),
                0,
                me,
                1,
                100e18,
                1e18,
                me,
                _getSwapParams(address(trancheUSDC_V4_yvUSDC_17DEC21), address(underlierUSDC), 0)
            )
        );
        // we have more USDC than before
        assertGt(underlierUSDC.balanceOf(me), usdcBefore);
        // should have refunded excess FIAT
        assertGt(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(me));
        // No collateral left
        assertEq(_balance(address(vault_yvUSDC_17DEC21), address(auctionActions)), 0);
        assertEq(collateralBalance, trancheUSDC_V4_yvUSDC_17DEC21.balanceOf(me));
    }

    function test_takeCollateralAndRedeemForUnderlier_AFTER_maturity() public {
        fiat.transfer(address(userProxy), 100e18);
        uint256 fiatBalance = fiat.balanceOf(address(userProxy));
        assertEq(fiat.balanceOf(address(userProxy)), 100e18);
        uint256 collateralBalance = trancheUSDC_V4_yvUSDC_17DEC21.balanceOf(address(userProxy));

        // Move post maturity
        vm.warp(maturity + 1);
        
        collateralAuction.redoAuction(1, me);

        vm.warp(block.timestamp + 100);

        uint256 usdcBefore = underlierUSDC.balanceOf(address(userProxy));

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndRedeemForUnderlier.selector,
                address(vault_yvUSDC_17DEC21),
                0,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy)
            )
        );
        // USDC received
        assertGt(underlierUSDC.balanceOf(address(userProxy)), usdcBefore);
        // should have refunded excess FIAT
        assertGt(fiat.balanceOf(address(userProxy)), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(address(userProxy)));
        // No collateral left
        assertEq(collateralBalance, trancheUSDC_V4_yvUSDC_17DEC21.balanceOf(address(userProxy)));
    }

    function test_takeCollateralAndRedeemForUnderlier_from_user_AFTER_maturity() public {
        uint256 fiatBalance = fiat.balanceOf(me);
        uint256 collateralBalance = trancheUSDC_V4_yvUSDC_17DEC21.balanceOf(me);

        // Move post maturity
        vm.warp(maturity + 1);

        collateralAuction.redoAuction(1, me);

        uint256 usdcBefore = underlierUSDC.balanceOf(me);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndRedeemForUnderlier.selector,
                address(vault_yvUSDC_17DEC21),
                0,
                me,
                1,
                100e18,
                1e18,
                me
            )
        );
        // we got the underlier
        assertGt(underlierUSDC.balanceOf(me), usdcBefore);
        // used all FIAT
        assertEq(fiat.balanceOf(me), 0);
        // should have less FIAT than before
        assertGt(fiatBalance, fiat.balanceOf(me));
        // No collateral left
        assertEq(collateralBalance, trancheUSDC_V4_yvUSDC_17DEC21.balanceOf(me));
    }

    function testFail_takeCollateralAndRedeemForUnderlier_BEFORE_maturity() public {
        fiat.transfer(address(userProxy), 100e18);

        vm.warp(block.timestamp + 24 * 3600);

        collateralAuction.redoAuction(1, me);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndRedeemForUnderlier.selector,
                address(vault_yvUSDC_17DEC21),
                0,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy)
            )
        );
    }

    function testFail_takeCollateralAndSwapForUnderlier_AFTER_maturity() public {
        fiat.transfer(address(userProxy), 100e18);
       
        uint256 collateralBalance = trancheUSDC_V4_yvUSDC_17DEC21.balanceOf(address(userProxy));

        assertEq(collateralBalance, 0);

        vm.warp(maturity + 3600 * 24 * 20);
        collateralAuction.redoAuction(1, me);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndSwapForUnderlier.selector,
                address(vault_yvUSDC_17DEC21),
                0,
                address(userProxy),
                1,
                100e18,
                1e18,
                address(userProxy),
                _getSwapParams(address(trancheUSDC_V4_yvUSDC_17DEC21), address(underlierUSDC), 0)
            )
        );
    }

    function testFail_takeCollateralAndSwapForUnderlier_from_user_AFTER_maturity() public {
        vm.warp(maturity + 3600 * 24 * 20);
        collateralAuction.redoAuction(1, me);

        userProxy.execute(
            address(auctionActions),
            abi.encodeWithSelector(
                auctionActions.takeCollateralAndSwapForUnderlier.selector,
                address(vault_yvUSDC_17DEC21),
                0,
                me,
                1,
                100e18,
                1e18,
                me,
                _getSwapParams(address(trancheUSDC_V4_yvUSDC_17DEC21), address(underlierUSDC), 0)
            )
        );
    }
}
