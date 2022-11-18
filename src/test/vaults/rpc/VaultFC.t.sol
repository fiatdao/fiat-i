// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC20Metadata} from "openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "openzeppelin/contracts/utils/Strings.sol";

import {Codex} from "../../../core/Codex.sol";
import {Collybus} from "../../../core/Collybus.sol";
import {WAD, add, sub, mul, wmul, wdiv} from "../../../core/utils/Math.sol";

import {DateTime} from "../../utils/notional/DateTime.sol";
import {SafeInt256} from "../../utils/notional/SafeInt256.sol";
import {NotionalProxy} from "../../utils/notional/NotionalProxy.sol";
import {ICToken} from "../../utils/notional/ICToken.sol";
import {EncodeDecode, TokenType, CashGroupSettings, Constants, BalanceActionWithTrades, DepositActionType, AccountContext, PortfolioAsset, Token} from "../../utils/notional/EncodeDecode.sol";

import {TestERC20} from "../../../test/utils/TestERC20.sol";

import {VaultFC} from "../../../vaults/VaultFC.sol";

interface INotional {
    struct MarketParameters {
        bytes32 storageSlot;
        uint256 maturity;
        // Total amount of fCash available for purchase in the market.
        int256 totalfCash;
        // Total amount of cash available for purchase in the market.
        int256 totalAssetCash;
        // Total amount of liquidity tokens (representing a claim on liquidity) in the market.
        int256 totalLiquidity;
        // This is the previous annualized interest rate in RATE_PRECISION that the market traded
        // at. This is used to calculate the rate anchor to smooth interest rates over time.
        uint256 lastImpliedRate;
        // Time lagged version of lastImpliedRate, used to value fCash assets at market rates while
        // remaining resistent to flash loan attacks.
        uint256 oracleRate;
        // This is the timestamp of the previous trade
        uint256 previousTradeTime;
    }

    function getActiveMarkets(uint16 currencyId) external view returns (MarketParameters[] memory);
}

contract NotionalMinter is ERC1155Holder {
    using SafeERC20 for IERC20;
    using SafeInt256 for int256;

    address internal constant ETH_ADDRESS = address(0);
    /// address to the NotionalV2 system
    NotionalProxy public NotionalV2;

    /// @dev Storage slot for fCash id. Read only and set on initialization
    uint256 private _fCashId;

    /// @notice Constructor is called only on deployment to set the Notional address, rest of state
    /// is initialized on the proxy.
    constructor(
        address _notional,
        uint16 currencyId,
        uint40 maturity
    ) {
        NotionalV2 = NotionalProxy(_notional);
        CashGroupSettings memory cashGroup = NotionalV2.getCashGroup(currencyId);
        require(cashGroup.maxMarketIndex > 0, "Invalid currency");
        // This includes idiosyncratic fCash maturities
        require(DateTime.isValidMaturity(cashGroup.maxMarketIndex, maturity, block.timestamp), "Invalid maturity");

        _fCashId = EncodeDecode.encodeERC1155Id(currencyId, maturity, Constants.FCASH_ASSET_TYPE);
    }

    /***** Mint Methods *****/

    /// @notice Lends the corresponding fCash amount to the current contract and credits the
    /// receiver with the corresponding amount of fCash shares. Will transfer cash from the
    /// msg.sender. Uses the underlying token.
    /// @param fCashAmount amount of fCash to purchase (lend)
    /// @param receiver address to receive the fCash shares
    function mintFromUnderlying(uint256 fCashAmount, address receiver) external payable {
        (
            uint8 marketIndex,
            ,
            /* int256 assetCashInternal */
            int256 underlyingCashInternal
        ) = _calculateMint(fCashAmount);
        require(underlyingCashInternal < 0, "Trade error");
        (IERC20 token, int256 underlyingPrecision) = getUnderlyingToken();

        uint256 depositAmount = SafeInt256.toUint(
            EncodeDecode.convertToExternal(underlyingCashInternal.neg(), underlyingPrecision)
        );

        _executeLendTradeAndMint(token, depositAmount, true, marketIndex, fCashAmount, receiver);
    }

    /// @notice Lends the corresponding fCash amount to the current contract and credits the
    /// receiver with the corresponding amount of fCash shares. Will transfer cash from the
    /// msg.sender. Uses the asset token (cToken).
    /// @param fCashAmount amount of fCash to purchase (lend)
    /// @param receiver address to receive the fCash shares
    function mintFromAsset(uint256 fCashAmount, address receiver) external {
        (
            uint8 marketIndex,
            int256 assetCashInternal, /* int256 underlyingCashInternal*/

        ) = _calculateMint(fCashAmount);
        require(assetCashInternal < 0, "Trade error");
        (
            IERC20 token,
            int256 underlyingPrecision, /* */

        ) = getAssetToken();

        uint256 depositAmount = SafeInt256.toUint(
            EncodeDecode.convertToExternal(assetCashInternal.neg(), underlyingPrecision)
        );

        _executeLendTradeAndMint(token, depositAmount, false, marketIndex, fCashAmount, receiver);
    }

    /// @notice Calculates the amount of asset cash or underlying cash required to lend
    function _calculateMint(uint256 fCashAmount)
        internal
        returns (
            uint8 marketIndex,
            int256 assetCashInternal,
            int256 underlyingCashInternal
        )
    {
        require(!hasMatured(), "fCash matured");
        (
            IERC20 assetToken, /* */
            ,
            TokenType tokenType
        ) = getAssetToken();
        if (tokenType == TokenType.cToken || tokenType == TokenType.cETH) {
            // Accrue interest on cTokens first so calculate trade returns the appropriate
            // amount
            ICToken(address(assetToken)).accrueInterest();
        }

        marketIndex = getMarketIndex();
        (assetCashInternal, underlyingCashInternal) = NotionalV2.getCashAmountGivenfCashAmount(
            getCurrencyId(),
            int88(SafeInt256.toInt(fCashAmount)),
            marketIndex,
            block.timestamp
        );

        return (marketIndex, _adjustForRounding(assetCashInternal), _adjustForRounding(underlyingCashInternal));
    }

    /// @dev adjust the returned cash values for potential rounding issues in calculations
    function _adjustForRounding(int256 x) private pure returns (int256) {
        int256 y = (x < 1e7) ? int256(1) : (x / 1e7);
        return x - y;
    }

    /// @dev Executes a lend trade and mints fCash shares back to the lender
    function _executeLendTradeAndMint(
        IERC20 token,
        uint256 depositAmountExternal,
        bool isUnderlying,
        uint8 marketIndex,
        uint256 _fCashAmount,
        address receiver
    ) internal {
        require(_fCashAmount <= uint256(type(uint88).max), "");
        uint88 fCashAmount = uint88(_fCashAmount);

        // TODO: need to handle ETH here
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), depositAmountExternal);

        BalanceActionWithTrades[] memory action = new BalanceActionWithTrades[](1);
        action[0].actionType = isUnderlying ? DepositActionType.DepositUnderlying : DepositActionType.DepositAsset;
        action[0].depositActionAmount = depositAmountExternal;
        action[0].currencyId = getCurrencyId();
        action[0].withdrawEntireCashBalance = true;
        action[0].redeemToUnderlying = true;
        action[0].trades = new bytes32[](1);
        action[0].trades[0] = EncodeDecode.encodeLendTrade(marketIndex, fCashAmount, 0);

        token.safeApprove(address(NotionalV2), depositAmountExternal);
        NotionalV2.batchBalanceAndTradeAction(address(this), action);

        uint256 balanceAfter = token.balanceOf(address(this));

        NotionalV2.safeTransferFrom(
            address(this), // Sending from this contract
            receiver, // Where to send the fCash
            getfCashId(), // fCash identifier
            fCashAmount, // Amount of fCash to send
            new bytes(0)
        );

        // Send any residuals from lending back to the sender
        uint256 residual = balanceAfter - balanceBefore;
        if (residual > 0) token.safeTransfer(msg.sender, residual);
    }

    /// @notice This hook will be called every time this contract receives fCash, will validate that
    /// this is the correct fCash and then mint the corresponding amount of wrapped fCash tokens
    /// back to the user.
    function onERC1155Received(
        address _operator,
        address _from,
        uint256 _id,
        uint256 _value,
        bytes calldata _data
    ) public view override returns (bytes4) {
        // Only accept erc1155 transfers from NotionalV2
        require(msg.sender == address(NotionalV2), "Invalid caller");
        // Only accept the fcash id that corresponds to the listed currency and maturity
        uint256 fCashID = getfCashId();
        require(_id == fCashID, "Invalid fCash asset");
        // Protect against signed value underflows
        require(int256(_value) > 0, "Invalid value");

        // Double check the account's position, these are not strictly necessary and add gas costs
        // but might be good safe guards
        AccountContext memory ac = NotionalV2.getAccountContext(address(this));
        require(ac.hasDebt == 0x00, "Incurred debt");
        PortfolioAsset[] memory assets = NotionalV2.getAccountPortfolio(address(this));
        require(assets.length == 1, "Invalid assets");
        require(
            EncodeDecode.encodeERC1155Id(assets[0].currencyId, assets[0].maturity, assets[0].assetType) == fCashID,
            "Invalid portfolio asset"
        );

        // Update per account fCash balance, calldata from the ERC1155 call is
        // passed via the ERC777 interface.
        bytes memory userData;
        bytes memory operatorData;
        if (_operator == _from) userData = _data;
        else operatorData = _data;

        // We don't require a recipient ack here to maintain compatibility
        // with contracts that don't support ERC777
        // _mint(_from, _value, userData, operatorData, false);

        // This will allow the fCash to be accepted
        return this.onERC1155Received.selector;
    }

    /// @dev Do not accept batches of fCash
    function onERC1155BatchReceived(
        address, /* _operator */
        address, /* _from */
        uint256[] calldata, /* _ids */
        uint256[] calldata, /* _values */
        bytes calldata /* _data */
    ) public pure override returns (bytes4) {
        return 0;
    }

    /***** View Methods  *****/

    /// @notice Returns the underlying fCash ID of the token
    function getfCashId() public view returns (uint256) {
        return _fCashId;
    }

    /// @notice Returns the underlying fCash maturity of the token
    function getMaturity() public view returns (uint40 maturity) {
        (
            ,
            /* */
            maturity, /* */

        ) = EncodeDecode.decodeERC1155Id(_fCashId);
    }

    /// @notice True if the fCash has matured, assets mature exactly on the block time
    function hasMatured() public view returns (bool) {
        return getMaturity() <= block.timestamp;
    }

    /// @notice Returns the underlying fCash currency
    function getCurrencyId() public view returns (uint16 currencyId) {
        (
            currencyId, /* */ /* */
            ,

        ) = EncodeDecode.decodeERC1155Id(_fCashId);
    }

    /// @notice Returns the components of the fCash idd
    function getDecodedID() public view returns (uint16 currencyId, uint40 maturity) {
        (
            currencyId,
            maturity, /* */

        ) = EncodeDecode.decodeERC1155Id(_fCashId);
    }

    /// @notice fCash is always denominated in 8 decimal places
    function decimals() public pure returns (uint8) {
        return 8;
    }

    /// @notice Returns the current market index for this fCash asset. If this returns
    /// zero that means it is idiosyncratic and cannot be traded.
    function getMarketIndex() public view returns (uint8) {
        (uint256 marketIndex, bool isIdiosyncratic) = DateTime.getMarketIndex(
            Constants.MAX_TRADED_MARKET_INDEX,
            getMaturity(),
            block.timestamp
        );

        if (isIdiosyncratic) return 0;
        // Market index as defined does not overflow this conversion
        return uint8(marketIndex);
    }

    /// @notice Returns the token and precision of the token that this token settles
    /// to. For example, fUSDC will return the USDC token address and 1e6. The zero
    /// address will represent ETH.
    function getUnderlyingToken() public view returns (IERC20 underlyingToken, int256 underlyingPrecision) {
        uint16 currencyId = getCurrencyId();
        return _getUnderlyingToken(currencyId);
    }

    /// @dev Called during initialization to set token name and symbol
    function _getUnderlyingToken(uint16 currencyId)
        private
        view
        returns (IERC20 underlyingToken, int256 underlyingPrecision)
    {
        (Token memory asset, Token memory underlying) = NotionalV2.getCurrency(currencyId);

        if (asset.tokenType == TokenType.NonMintable) {
            // In this case the asset token is the underlying
            return (IERC20(asset.tokenAddress), asset.decimals);
        } else {
            return (IERC20(underlying.tokenAddress), underlying.decimals);
        }
    }

    /// @notice Returns the asset token which the fCash settles to. This will be an interest
    /// bearing token like a cToken or aToken.
    function getAssetToken()
        public
        view
        returns (
            IERC20 underlyingToken,
            int256 underlyingPrecision,
            TokenType tokenType
        )
    {
        (
            Token memory asset, /* Token memory underlying */

        ) = NotionalV2.getCurrency(getCurrencyId());

        return (IERC20(asset.tokenAddress), asset.decimals, asset.tokenType);
    }
}

contract VaultSY_ModifyPositionCollateralizationTest is Test, ERC1155Holder {
    Codex internal codex;
    address internal collybus = address(0xc0111b115);
    VaultFC internal vault;
    NotionalMinter internal minterfDAI_1;
    NotionalMinter internal minterfDAI_2;

    INotional.MarketParameters cDAIMarket;

    address internal me = address(this);
    uint256 ONE_USDC = 1e6;
    uint256 ONE_FCASH = 1e8;

    IERC20 internal DAI = IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F); // DAI
    IERC20 internal USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC

    address internal cDAI = address(0x5d3a536E4D6DbD6114cc1Ead35777bAB948E3643);
    address internal cUSDC = address(0x39AA39c021dfbaE8faC545936693aC917d5E7563);
    address internal notional = address(0x1344A36A1B56144C3Bc62E7757377D288fDE0369);

    uint256 internal fCashId_1;
    uint256 internal fCashId_2;

    function _mintUSDC(address to, uint256 amount) internal {
        // USDC minters
        vm.store(address(USDC), keccak256(abi.encode(address(this), uint256(12))), bytes32(uint256(1)));
        // USDC minterAllowed
        vm.store(address(USDC), keccak256(abi.encode(address(this), uint256(13))), bytes32(uint256(type(uint256).max)));
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(USDC).call(abi.encodeWithSignature(sig, to, amount));
        assert(ok);
    }

    function _mintDAI(address to, uint256 amount) internal {
        vm.store(address(DAI), keccak256(abi.encode(address(address(this)), uint256(0))), bytes32(uint256(1)));
        string memory sig = "mint(address,uint256)";
        (bool ok, ) = address(DAI).call(abi.encodeWithSignature(sig, to, amount));
        assert(ok);
    }

    function _mintCDAI(uint256 amount) internal {
        DAI.approve(cDAI, amount);
        (bool ok, ) = cDAI.call(abi.encodeWithSignature("mint(uint256)", amount));
        assert(ok);
    }

    function _mintCUSDC(uint256 amount) internal {
        USDC.approve(cUSDC, amount);
        (bool ok, ) = cUSDC.call(abi.encodeWithSignature("mint(uint256)", amount));
        assert(ok);
    }

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

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 13627845);

        codex = new Codex();
        
        // vault = new VaultFC(address(codex), address(collybus), notional, cDAI, uint256(86400 * 6 * 5 * 3), 2);
        vault = new VaultFC(address(codex), collybus, notional, address(DAI), uint256(86400 * 6 * 5 * 3), 2);

        codex.setParam("globalDebtCeiling", uint256(1000 ether));
        codex.setParam(address(vault), "debtCeiling", uint256(1000 ether));
        codex.allowCaller(codex.modifyBalance.selector, address(vault));
        codex.init(address(vault));

        _mintDAI(me, 2000 ether);
        _mintCDAI(2000 ether);

        INotional.MarketParameters[] memory markets = INotional(notional).getActiveMarkets(2);

        minterfDAI_1 = new NotionalMinter(notional, 2, uint40(markets[0].maturity));
        fCashId_1 = minterfDAI_1.getfCashId();

        minterfDAI_2 = new NotionalMinter(notional, 2, uint40(markets[1].maturity));
        fCashId_2 = minterfDAI_2.getfCashId();

        IERC20(cDAI).approve(address(minterfDAI_1), type(uint256).max);
        IERC20(cDAI).approve(address(minterfDAI_2), type(uint256).max);
        minterfDAI_1.mintFromAsset(1000 * ONE_FCASH, me);
        minterfDAI_2.mintFromAsset(1000 * ONE_FCASH, me);
        IERC1155(notional).setApprovalForAll(address(vault), true);
    }

    function test_enter() public {
        uint256 initialBalance = IERC1155(notional).balanceOf(me, fCashId_1);
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), fCashId_1);

        vault.enter(fCashId_1, me, 1000 * ONE_FCASH);

        assertEq(codex.balances(address(vault), fCashId_1, me), 1000 * WAD);
        assertEq(IERC1155(notional).balanceOf(me, fCashId_1), initialBalance - 1000 * ONE_FCASH);
        assertEq(IERC1155(notional).balanceOf(address(vault), fCashId_1), vaultInitialBalance + 1000 * ONE_FCASH);
    }

    function testFail_enter_multiple_maturities() public {
        uint256 initialBalance = IERC1155(notional).balanceOf(me, fCashId_1);
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), fCashId_1);

        vault.enter(fCashId_1, me, 1000 * ONE_FCASH);

        assertEq(codex.balances(address(vault), fCashId_1, me), 1000 * WAD);
        assertEq(IERC1155(notional).balanceOf(me, fCashId_1), initialBalance - 1000 * ONE_FCASH);
        assertEq(IERC1155(notional).balanceOf(address(vault), fCashId_1), vaultInitialBalance + 1000 * ONE_FCASH);

        uint256 initialBalance2 = IERC1155(notional).balanceOf(me, fCashId_2);
        uint256 vaultInitialBalance2 = IERC1155(notional).balanceOf(address(vault), fCashId_2);

        vault.enter(fCashId_2, me, 1000 * ONE_FCASH);

        assertEq(codex.balances(address(vault), fCashId_2, me), 1000 * WAD);
        assertEq(IERC1155(notional).balanceOf(me, fCashId_2), initialBalance2 - 1000 * ONE_FCASH);
        assertEq(IERC1155(notional).balanceOf(address(vault), fCashId_2), vaultInitialBalance2 + 1000 * ONE_FCASH);
    }

    function test_exit() public {
        vault.enter(fCashId_1, me, 1000 * ONE_FCASH);

        uint256 initialBalance = IERC1155(notional).balanceOf(me, fCashId_1);
        uint256 vaultInitialBalance = IERC1155(notional).balanceOf(address(vault), fCashId_1);
        uint256 codexBalance = codex.balances(address(vault), fCashId_1, me);

        vault.exit(fCashId_1, me, 500 * ONE_FCASH);

        assertEq(codex.balances(address(vault), fCashId_1, me), codexBalance - 500 * WAD);
        assertEq(IERC1155(notional).balanceOf(me, fCashId_1), initialBalance + 500 * ONE_FCASH);
        assertEq(IERC1155(notional).balanceOf(address(vault), fCashId_1), vaultInitialBalance - 500 * ONE_FCASH);
    }

    function test_redeems() public {
        vault.enter(fCashId_1, me, 1000 * ONE_FCASH);

        // warp to maturity
        vm.warp(vault.maturity(fCashId_1) + 1);

        assertGt(vault.redeems(fCashId_1, 500 * ONE_FCASH, 0), 0);
        assertGt(vault.redeems(fCashId_1, 500 * ONE_FCASH, 3e28), vault.redeems(fCashId_1, 500 * ONE_FCASH, 0));
    }

    function test_redeemAndExit() public {
        vault.enter(fCashId_1, me, 1000 * ONE_FCASH);

        uint256 underlierBalance1 = IERC20(vault.underlierToken()).balanceOf(me);
        uint256 collateralBalance = codex.balances(address(vault), fCashId_1, me);

        // warp to maturity
        vm.warp(vault.maturity(fCashId_1) + 1);

        uint256 redeems = vault.redeems(fCashId_1, 500 * ONE_FCASH, 0);

        // exit 50%
        uint256 redeemed = vault.redeemAndExit(fCashId_1, me, 500 * ONE_FCASH);
        uint256 underlierBalance2 = IERC20(vault.underlierToken()).balanceOf(me);
        // should have burned all fCash already
        assertEq(IERC1155(notional).balanceOf(address(vault), fCashId_1), 0);
        // should have accounted for exiting 500 fCash
        assertEq(codex.balances(address(vault), fCashId_1, me), collateralBalance - 500 * WAD);
        // should have received proportional amount of underlier
        assertEq(redeems, underlierBalance2 - underlierBalance1);
        assertEq(redeems, redeemed);

        // exit remaining 50%
        vault.redeemAndExit(fCashId_1, me, 250 * ONE_FCASH);

        assertGt(IERC20(vault.underlierToken()).balanceOf(me), underlierBalance2);
        assertEq(IERC1155(notional).balanceOf(address(vault), fCashId_1), 0);
    }

    function test_fairPrice_face() public {
        uint256 fairPriceExpected = 100;
        bytes memory query = abi.encodeWithSelector(
            Collybus.read.selector,
            address(vault),
            vault.underlierToken(),
            fCashId_1,
            block.timestamp,
            true
        );
        
        vm.mockCall(collybus, query, abi.encode(uint256(fairPriceExpected)));

        uint256 fairPriceReturned = vault.fairPrice(fCashId_1, true, true);
        assertEq(fairPriceReturned, fairPriceExpected);
    }

    function test_fairPrice_no_face() public {
        uint256 fairPriceExpected = 99;
        bytes memory query = abi.encodeWithSelector(
            Collybus.read.selector,
            address(vault),
            vault.underlierToken(),
            fCashId_1,
            vault.maturity(fCashId_1),
            true
        );
        
        vm.mockCall(collybus, query, abi.encode(uint256(fairPriceExpected)));

        uint256 fairPriceReturned = vault.fairPrice(fCashId_1, true, false);
        assertEq(fairPriceReturned, fairPriceExpected);
    }
}
