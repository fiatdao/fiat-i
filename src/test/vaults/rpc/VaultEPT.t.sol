// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1155Holder} from "openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {Codex} from "../../../core/Codex.sol";
import {Collybus, ICollybus} from "../../../core/Collybus.sol";
import {WAD, wdiv} from "../../../core/utils/Math.sol";

import {Caller} from "../../../test/utils/Caller.sol";

import {VaultEPT} from "../../../vaults/VaultEPT.sol";
import {VaultFactory} from "../../../vaults/VaultFactory.sol";

interface ITrancheFactory {
    function deployTranche(uint256 _expiration, address _wpAddress) external returns (address);
}

interface ITranche {
    function unlockTimestamp() external view returns (uint256);

    function balanceOf(address _owner) external view returns (uint256);

    function deposit(uint256 _shares, address destination) external returns (uint256, uint256);
}

contract VaultEPT_ModifyPositionCollateralizationTest is Test, ERC1155Holder {
    ITrancheFactory internal trancheFactory = ITrancheFactory(0x62F161BF3692E4015BefB05A03a94A40f520d1c0);
    IERC20 internal underlierUSDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    IERC20 internal underlierDAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F); // DAI

    Codex internal codex;
    address internal collybus = address(0xc0111b115);
    VaultEPT internal impl;
    VaultEPT internal vaultYUSDC_V4_3Months;
    VaultFactory vaultFactory;
    Caller kakaroto;

    uint256 internal tokenId = 0;
    address internal me = address(this);
    address internal trancheUSDC_V4_3Months;
    address internal trancheUSDC_V4_6Months;
    address internal trancheDAI_3Months;

    address wrappedPositionYDAI = address(0x21BbC083362022aB8D7e42C18c47D484cc95C193);
    address wrappedPositionYUSDC = address(0xdEa04Ffc66ECD7bf35782C70255852B34102C3b0);

    uint256 ONE_USDC = 1e6;

    uint256 constant MAX_DECIMALS = 38; // ~type(int256).max ~= 1e18*1e18
    uint256 constant MAX_AMOUNT = 10**(MAX_DECIMALS);

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

    function _mintDAI(address to, uint256 amount) internal {
        vm.store(address(underlierDAI), keccak256(abi.encode(address(address(this)), uint256(0))), bytes32(uint256(1)));
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(underlierDAI).call(abi.encodeWithSignature(sig, to, amount));
        assert(ok);
    }

    function _balance(address vault, address user) internal view returns (uint256) {
        return codex.balances(vault, 0, user);
    }

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 13627845);

        vaultFactory = new VaultFactory();
        codex = new Codex();
        kakaroto = new Caller();

        impl = new VaultEPT(address(codex), wrappedPositionYUSDC, address(0x62F161BF3692E4015BefB05A03a94A40f520d1c0));

        codex.setParam("globalDebtCeiling", uint256(1000 ether));

        _mintUSDC(me, 10000 * ONE_USDC);
        _mintDAI(me, 10000 * WAD);
        trancheUSDC_V4_3Months = trancheFactory.deployTranche(block.timestamp + 12 weeks, wrappedPositionYUSDC);
        trancheUSDC_V4_6Months = trancheFactory.deployTranche(block.timestamp + 24 weeks, wrappedPositionYUSDC);

        trancheDAI_3Months = trancheFactory.deployTranche(block.timestamp + 12 weeks, wrappedPositionYDAI);

        underlierUSDC.approve(trancheUSDC_V4_3Months, type(uint256).max);
        underlierUSDC.approve(trancheUSDC_V4_6Months, type(uint256).max);
        underlierDAI.approve(trancheDAI_3Months, type(uint256).max);

        ITranche(trancheUSDC_V4_3Months).deposit(1000 * ONE_USDC, me);
        ITranche(trancheUSDC_V4_6Months).deposit(1000 * ONE_USDC, me);
        ITranche(trancheDAI_3Months).deposit(1000 * WAD, me);

        address instance = vaultFactory.createVault(
            address(impl),
            abi.encode(address(trancheUSDC_V4_3Months), collybus)
        );
        vaultYUSDC_V4_3Months = VaultEPT(instance);
        codex.setParam(instance, "debtCeiling", uint256(1000 ether));
        codex.allowCaller(codex.modifyBalance.selector, instance);
        codex.init(instance);

        IERC20(trancheUSDC_V4_3Months).approve(instance, type(uint256).max);
    }

    function testFail_initialize_with_wrong_ptoken() public {
        vaultFactory.createVault(address(impl), abi.encode(trancheDAI_3Months, collybus));
    }

    function test_initialize_with_right_ptoken() public {
        vaultFactory.createVault(address(impl), abi.encode(trancheUSDC_V4_3Months, collybus));
        vaultFactory.createVault(address(impl), abi.encode(trancheUSDC_V4_6Months, collybus));
    }

    function test_initialize_parameters() public {
        address instance = vaultFactory.createVault(
            address(impl),
            abi.encode(trancheUSDC_V4_3Months, collybus)
        );
        assertEq(address(VaultEPT(instance).token()), trancheUSDC_V4_3Months);
        assertEq(VaultEPT(instance).tokenScale(), 10**IERC20Metadata(trancheUSDC_V4_3Months).decimals());
        assertEq(VaultEPT(instance).maturity(0), ITranche(trancheUSDC_V4_3Months).unlockTimestamp());
        assertEq(VaultEPT(instance).underlierToken(), address(underlierUSDC));
        assertEq(VaultEPT(instance).underlierScale(), 10**IERC20Metadata(address(underlierUSDC)).decimals());
        assertEq(address(VaultEPT(instance).collybus()), collybus);
    }

    function test_enter(uint32 rnd) public {
        vm.assume(rnd != 0);
        uint256 amount = rnd % IERC20(trancheUSDC_V4_3Months).balanceOf(me);

        uint256 balanceBefore = IERC20(trancheUSDC_V4_3Months).balanceOf(address(vaultYUSDC_V4_3Months));
        uint256 collateralBefore = _balance(address(vaultYUSDC_V4_3Months), address(me));

        vaultYUSDC_V4_3Months.enter(0, me, amount);

        assertEq(IERC20(trancheUSDC_V4_3Months).balanceOf(address(vaultYUSDC_V4_3Months)), balanceBefore + amount);

        uint256 wadAmount = wdiv(amount, 10**IERC20Metadata(trancheUSDC_V4_3Months).decimals());

        assertEq(_balance(address(vaultYUSDC_V4_3Months), address(me)), collateralBefore + wadAmount);
    }

    function test_exit(uint32 rndA, uint32 rndB) public {
        vm.assume(rndA != 0 && rndA != IERC20(trancheUSDC_V4_3Months).balanceOf(me));
        vm.assume(rndB != 0);
        
        uint256 amountEnter = rndA % IERC20(trancheUSDC_V4_3Months).balanceOf(me);
        uint256 amountExit = rndB % amountEnter;

        vaultYUSDC_V4_3Months.enter(0, me, amountEnter);

        uint256 balanceBefore = IERC20(trancheUSDC_V4_3Months).balanceOf(address(vaultYUSDC_V4_3Months));
        uint256 collateralBefore = _balance(address(vaultYUSDC_V4_3Months), address(me));

        vaultYUSDC_V4_3Months.exit(0, me, amountExit);
        assertEq(IERC20(trancheUSDC_V4_3Months).balanceOf(address(vaultYUSDC_V4_3Months)), balanceBefore - amountExit);

        uint256 wadAmount = wdiv(amountExit, 10**IERC20Metadata(trancheUSDC_V4_3Months).decimals());
        assertEq(_balance(address(vaultYUSDC_V4_3Months), address(me)), collateralBefore - wadAmount);
    }

    function test_fairPrice_calls_into_collybus_face() public {
        uint256 fairPriceExpected = 100;
        bytes memory query = abi.encodeWithSelector(
            Collybus.read.selector,
            address(vaultYUSDC_V4_3Months),
            address(underlierUSDC),
            0,
            block.timestamp,
            true
        );

        vm.mockCall(
            collybus,
            query,
            abi.encode(uint256(fairPriceExpected))
        );

        uint256 fairPriceReturned = vaultYUSDC_V4_3Months.fairPrice(0, true, true);
        assertEq(fairPriceReturned, fairPriceExpected);
    }

    function test_fairPrice_calls_into_collybus_no_face() public {
        uint256 fairPriceExpected = 100;
        bytes memory query = abi.encodeWithSelector(
            Collybus.read.selector,
            address(vaultYUSDC_V4_3Months),
            address(underlierUSDC),
            0,
            vaultYUSDC_V4_3Months.maturity(0),
            true
        );
        
        vm.mockCall(
            collybus,
            query,
            abi.encode(uint256(fairPriceExpected))
        );

        uint256 fairPriceReturned = vaultYUSDC_V4_3Months.fairPrice(0, true, false);
        assertEq(fairPriceReturned, fairPriceExpected);
    }

    function test_allowCaller_can_be_called_by_root() public {
        vaultYUSDC_V4_3Months.allowCaller(vaultYUSDC_V4_3Months.setParam.selector, address(kakaroto));
        assertTrue(vaultYUSDC_V4_3Months.canCall(vaultYUSDC_V4_3Months.setParam.selector, address(kakaroto)));
    }

    function test_lock_can_be_called_by_root() public {
        vaultYUSDC_V4_3Months.lock();
        assertEq(vaultYUSDC_V4_3Months.live(), 0);
    }

    function test_setParam_can_be_called_by_root() public {
        vaultYUSDC_V4_3Months.setParam(bytes32("collybus"), me);
        assertEq(address(vaultYUSDC_V4_3Months.collybus()), me);
    }

    function test_setParam_can_be_called_by_authorized() public {
        vaultYUSDC_V4_3Months.allowCaller(vaultYUSDC_V4_3Months.setParam.selector, address(kakaroto));

        (bool ok, ) = kakaroto.externalCall(
            address(vaultYUSDC_V4_3Months),
            abi.encodeWithSelector(vaultYUSDC_V4_3Months.setParam.selector, bytes32("collybus"), me)
        );
        assertTrue(ok);
        assertEq(address(vaultYUSDC_V4_3Months.collybus()), me);
    }
}
