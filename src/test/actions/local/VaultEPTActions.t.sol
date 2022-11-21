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

import {VaultEPTActions} from "../../../actions/vault/VaultEPTActions.sol";
import {IBalancerVault, IConvergentCurvePool} from "../../../actions/helper/ConvergentCurvePoolHelper.sol";

contract BalancerVaultMock {
    enum PoolSpecialization {
        GENERAL,
        MINIMAL_SWAP_INFO,
        TWO_TOKEN
    }

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

    function setTokensBalance(address[] memory tokens, uint256[] memory balances) external {
        _tokens[0] = tokens[0];
        _tokens[1] = tokens[1];

        _balances[0] = balances[0];
        _balances[1] = balances[1];
    }

    function getPool(bytes32) external view returns (address, PoolSpecialization) {
        return (_pool, PoolSpecialization.TWO_TOKEN);
    }
}

contract VaultEPTActions_UnitTest is Test {
    address internal codex = address(0xc0d311);
    address internal moneta = address(0x11101137a);
    //keccak256(abi.encode("publican"));
    address internal publican = address(0xDF68e6705C6Cc25E78aAC874002B5ab31b679db4);
    
    //keccak256(abi.encode("mockVault"));
    address internal mockVault = address(0x4E0075d8C837f8fb999012e556b7A63FC65fceDa);
    
    VaultEPTActions VaultActions;
    address internal fiat = address(0xf1a7);
    BalancerVaultMock balancerVault;
    address internal ccp = address(0xcc9);

    address me = address(this);
    bytes32 poolId = bytes32("somePoolId");

    address internal underlierUSDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    address internal trancheUSDC_V4_yvUSDC_17DEC21 = address(0x76a34D72b9CF97d972fB0e390eB053A37F211c74);

    uint256 underlierScale = uint256(1e6);
    uint256 tokenScale = uint256(1e6);
    uint256 percentFee = 1e16;

    function setUp() public {
        balancerVault = new BalancerVaultMock(address(ccp));

        VaultActions = new VaultEPTActions(address(codex), address(moneta), address(fiat), address(publican));

        vm.mockCall(mockVault, abi.encodeWithSelector(IVault.token.selector), abi.encode(trancheUSDC_V4_yvUSDC_17DEC21));

        vm.mockCall(mockVault, abi.encodeWithSelector(IVault.underlierToken.selector), abi.encode(underlierUSDC));

        vm.mockCall(mockVault, abi.encodeWithSelector(IVault.underlierScale.selector), abi.encode(uint256(1e6)));

        vm.mockCall(mockVault, abi.encodeWithSelector(IVault.tokenScale.selector), abi.encode(uint256(1e6)));

    }

    function test_underlierToPToken() public {
        address[] memory tokens = new address[](2);
        tokens[0] = underlierUSDC;
        tokens[1] = trancheUSDC_V4_yvUSDC_17DEC21;

        uint256[] memory balances = new uint256[](2);
        balances[0] = 1e6;
        balances[1] = 2e6;

        balancerVault.setTokensBalance(tokens, balances);

        vm.mockCall(ccp, abi.encodeWithSelector(IConvergentCurvePool.totalSupply.selector), abi.encode(uint256(88)));

        vm.mockCall(ccp, abi.encodeWithSelector(IConvergentCurvePool.percentFee.selector), abi.encode(percentFee));
        
        uint256 quote = uint256(1100000000000000000);

        vm.mockCall(
            ccp, 
            abi.encodeWithSelector(
                IConvergentCurvePool.solveTradeInvariant.selector,
                WAD,
                wdiv(balances[0], underlierScale),
                add(wdiv(balances[1], tokenScale), uint256(88)),
                true
            ),
            abi.encode(quote)
        );
        
        uint256 impliedYieldFee = wmul(1e16, sub(quote, WAD));
        quote = sub(quote, impliedYieldFee);
        uint256 expectedPrice = wmul(quote, uint256(1e6));

        assertEq(
            VaultActions.underlierToPToken(address(mockVault), address(balancerVault), poolId, 1e6),
            expectedPrice
        );
    }

    function test_pTokenToUnderlier() public {
        address[] memory tokens = new address[](2);
        tokens[0] = underlierUSDC;
        tokens[1] = trancheUSDC_V4_yvUSDC_17DEC21;

        uint256[] memory balances = new uint256[](2);
        balances[0] = 1e6;
        balances[1] = 2e6;

        balancerVault.setTokensBalance(tokens, balances);

        vm.mockCall(ccp, abi.encodeWithSelector(IConvergentCurvePool.totalSupply.selector), abi.encode(uint256(88)));

        vm.mockCall(ccp, abi.encodeWithSelector(IConvergentCurvePool.percentFee.selector), abi.encode(percentFee));

        uint256 quote = uint256(900000000000000000);
        
        vm.mockCall(
            ccp, 
            abi.encodeWithSelector(
                IConvergentCurvePool.solveTradeInvariant.selector,
                WAD,
                add(wdiv(balances[1], tokenScale), uint256(88)),
                wdiv(balances[0], underlierScale),
                true
            ),
            abi.encode(quote)
        );

        uint256 impliedYieldFee = wmul(1e16, sub(WAD, quote));
        quote = sub(quote, impliedYieldFee);
        uint256 expectedPrice = wmul(quote, uint256(1e6));

        assertEq(
            VaultActions.pTokenToUnderlier(address(mockVault), address(balancerVault), poolId, 1e6),
            expectedPrice
        );
    }
}
