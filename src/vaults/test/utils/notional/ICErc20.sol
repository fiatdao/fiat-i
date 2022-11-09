// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.4;

import "./IErc20.sol";

interface ICErc20 is IErc20 {
    function mint(uint256 mintAmount) external returns (uint256);

    function redeem(uint256 redeemTokens) external returns (uint256);

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);

    function borrow(uint256 borrowAmount) external returns (uint256);

    function repayBorrow(uint256 repayAmount) external returns (uint256);

    function repayBorrowBehalf(address borrower, uint256 repayAmount) external returns (uint256);

    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        ICErc20 cTokenCollateral
    ) external returns (uint256);
}
