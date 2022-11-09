// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockProvider} from "mockprovider/MockProvider.sol";

import {Codex} from "../../../Codex.sol";
import {IVault} from "../../../interfaces/IVault.sol";
import {IMoneta} from "../../../interfaces/IMoneta.sol";
import {Moneta} from "../../../Moneta.sol";
import {FIAT} from "../../../FIAT.sol";
import {WAD, toInt256, wmul, wdiv, sub, add} from "../../../utils/Math.sol";

import {VaultEPTActions} from "../../vault/VaultEPTActions.sol";
import {IBalancerVault, IConvergentCurvePool} from "../../helper/ConvergentCurvePoolHelper.sol";

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

    function getPoolTokens(
        bytes32
    ) external view returns (address[] memory, uint256[] memory, uint256 lastChangeBlock) {
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
    MockProvider codex;
    MockProvider moneta;
    MockProvider publican;
    MockProvider mockVault;
    VaultEPTActions VaultActions;
    MockProvider fiat;
    BalancerVaultMock balancerVault;
    MockProvider ccp;

    address me = address(this);
    bytes32 poolId = bytes32("somePoolId");

    address internal underlierUSDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    address internal trancheUSDC_V4_yvUSDC_17DEC21 = address(0x76a34D72b9CF97d972fB0e390eB053A37F211c74);

    uint256 underlierScale = uint256(1e6);
    uint256 tokenScale = uint256(1e6);
    uint256 percentFee = 1e16;

    function setUp() public {
        fiat = new MockProvider();
        codex = new MockProvider();
        moneta = new MockProvider();
        publican = new MockProvider();
        mockVault = new MockProvider();
        ccp = new MockProvider();
        balancerVault = new BalancerVaultMock(address(ccp));

        VaultActions = new VaultEPTActions(address(codex), address(moneta), address(fiat), address(publican));

        mockVault.givenSelectorReturnResponse(
            IVault.token.selector,
            MockProvider.ReturnData({success: true, data: abi.encode(trancheUSDC_V4_yvUSDC_17DEC21)}),
            false
        );

        mockVault.givenSelectorReturnResponse(
            IVault.underlierToken.selector,
            MockProvider.ReturnData({success: true, data: abi.encode(underlierUSDC)}),
            false
        );

        mockVault.givenSelectorReturnResponse(
            IVault.underlierScale.selector,
            MockProvider.ReturnData({success: true, data: abi.encode(uint256(1e6))}),
            false
        );

        mockVault.givenSelectorReturnResponse(
            IVault.tokenScale.selector,
            MockProvider.ReturnData({success: true, data: abi.encode(uint256(1e6))}),
            false
        );
    }

    function test_underlierToPToken() public {
        address[] memory tokens = new address[](2);
        tokens[0] = underlierUSDC;
        tokens[1] = trancheUSDC_V4_yvUSDC_17DEC21;

        uint256[] memory balances = new uint256[](2);
        balances[0] = 1e6;
        balances[1] = 2e6;

        balancerVault.setTokensBalance(tokens, balances);

        ccp.givenSelectorReturnResponse(
            IConvergentCurvePool.totalSupply.selector,
            MockProvider.ReturnData({success: true, data: abi.encode(uint256(88))}),
            false
        );

        ccp.givenSelectorReturnResponse(
            IConvergentCurvePool.percentFee.selector,
            MockProvider.ReturnData({success: true, data: abi.encode(percentFee)}),
            false
        );

        uint256 quote = uint256(1100000000000000000);

        ccp.givenQueryReturnResponse(
            abi.encodeWithSelector(
                IConvergentCurvePool.solveTradeInvariant.selector,
                WAD,
                wdiv(balances[0], underlierScale),
                add(wdiv(balances[1], tokenScale), uint256(88)),
                true
            ),
            MockProvider.ReturnData({success: true, data: abi.encode(quote)}),
            false
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

        ccp.givenSelectorReturnResponse(
            IConvergentCurvePool.totalSupply.selector,
            MockProvider.ReturnData({success: true, data: abi.encode(uint256(88))}),
            false
        );

        ccp.givenSelectorReturnResponse(
            IConvergentCurvePool.percentFee.selector,
            MockProvider.ReturnData({success: true, data: abi.encode(percentFee)}),
            false
        );

        uint256 quote = uint256(900000000000000000);

        ccp.givenQueryReturnResponse(
            abi.encodeWithSelector(
                IConvergentCurvePool.solveTradeInvariant.selector,
                WAD,
                add(wdiv(balances[1], tokenScale), uint256(88)),
                wdiv(balances[0], underlierScale),
                true
            ),
            MockProvider.ReturnData({success: true, data: abi.encode(quote)}),
            false
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
