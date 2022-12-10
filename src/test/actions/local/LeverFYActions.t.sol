// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import "forge-std/Vm.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Codex} from "../../../core/Codex.sol";
import {IVault} from "../../../interfaces/IVault.sol";
import {IMoneta} from "../../../interfaces/IMoneta.sol";
import {Moneta} from "../../../core/Moneta.sol";
import {FIAT} from "../../../core/FIAT.sol";
import {WAD, toInt256, wmul, wdiv, sub, add} from "../../../core/utils/Math.sol";
import {SenseToken} from "../../../test/utils/SenseToken.sol";
import {TestERC20} from "../../../test/utils/TestERC20.sol";
import {VaultFYActions, IFYPool} from "../../../actions/vault/VaultFYActions.sol";
import {LeverFYActions} from "../../../actions/lever/LeverFYActions.sol";
import {IBalancerVault, IConvergentCurvePool} from "../../../actions/helper/ConvergentCurvePoolHelper.sol";

contract BalancerVaultMock {
    address[2] _tokens;
    uint256[2] _balances;

    address _pool;

    constructor(address pool) {
        _pool = pool;
    }

    function getPoolTokens(bytes32)
        external
        view
        returns (
            address[] memory,
            uint256[] memory,
            uint256 lastChangeBlock
        )
    {
        address[] memory tokens = new address[](2);
        tokens[0] = _tokens[0];
        tokens[1] = _tokens[1];

        uint256[] memory balances = new uint256[](2);
        balances[0] = _balances[0];
        balances[1] = _balances[1];

        return (tokens, balances, 0);
    }
}

contract LeverFYActions_UnitTest is Test {
    address codex = address(0xc0d311);
    address moneta = address(0x11101137a);
    address fiat = address(0xf1a7);

    //keccak256(abi.encode("publican"));
    address publican = address(0xDF68e6705C6Cc25E78aAC874002B5ab31b679db4) ;

    //keccak256(abi.encode("flash"));
    address flash = address(0xAA190528E10298b2fD47f6609EbF063866aAb523);

    LeverFYActions LeverActions;
    BalancerVaultMock balancerVault;

    //keccak256(abi.encode("ccp"));
    address ccp = address(0xB37e78E08aeaDC0d5E9b2460Ac62D25Fb0a8fa93);

    address underlierUSDC;
    address fyUSDC;

    address me = address(this);
  
    bytes32 fiatPoolId = bytes32("somePoolId");

    function setUp() public {
        balancerVault = new BalancerVaultMock(address(ccp));

        vm.mockCall(fiat, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        vm.mockCall(underlierUSDC, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));

        LeverActions = new LeverFYActions(
            codex,
            fiat,
            flash,
            moneta,
            publican,
            fiatPoolId,
            address(balancerVault)
        );
    }

    function test_underlierToFYToken() public {
        uint256 quote = uint256(1100000000000000000);

        uint256 impliedYieldFee = wmul(1e16, sub(quote, WAD));
        quote = sub(quote, impliedYieldFee);
        uint256 expectedPrice = wmul(quote, uint256(1e6));

        vm.mockCall(ccp, abi.encodeWithSelector(IFYPool.sellBasePreview.selector), abi.encode(expectedPrice));

        assertEq(
            LeverActions.underlierToFYToken(1e6, address(ccp)),
            expectedPrice
        );
    }

    function test_fyTokenToUnderlier() public {
        uint256 quote = uint256(900000000000000000);
        
        uint256 impliedYieldFee = wmul(1e16, sub(WAD, quote));
        quote = sub(quote, impliedYieldFee);
        uint256 expectedPrice = wmul(quote, uint256(1e6));
        
        vm.mockCall(ccp, abi.encodeWithSelector(IFYPool.sellFYTokenPreview.selector), abi.encode(expectedPrice));
        
        assertEq(
            LeverActions.fyTokenToUnderlier(1e6, address(ccp)),
            expectedPrice
        );
    }
}
