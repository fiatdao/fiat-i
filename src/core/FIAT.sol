// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.4;

import {ERC20} from "openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";

import {IFIATExcl} from "../interfaces/IFIAT.sol";

import {Guarded} from "./utils/Guarded.sol";

/// @title Fixed Income Asset Token (FIAT)
/// @notice `FIAT` is the protocol's stable asset which can be redeemed for `Credit` via `Moneta`
contract FIAT is Guarded, ERC20Permit, IFIATExcl {
    constructor() Guarded() ERC20("Fixed Income Asset Token", "FIAT") ERC20Permit("Fixed Income Asset Token") {}

    /// ======== Minting and Burning ======== ///

    /// @notice Increases the totalSupply by `amount` and transfers the new tokens to `to`
    /// @dev Sender has to be allowed to call this method
    /// @param to Address to which tokens should be credited to
    /// @param amount Amount of tokens to be minted [wad]
    function mint(address to, uint256 amount) external override checkCaller {
        _mint(to, amount);
    }

    /// @notice Decreases the totalSupply by `amount` and using the tokens from `from`
    /// @dev If `from` is not the caller, caller needs to have sufficient allowance from `from`,
    /// `amount` is then deducted from the caller's allowance
    /// @param from Address from which tokens should be burned from
    /// @param amount Amount of tokens to be burned [wad]
    function burn(address from, uint256 amount) public virtual {
        _spendAllowance(from, _msgSender(), amount);
        _burn(from, amount);
    }

    /// @notice Overrides `_spendAllowance` behaviour exempting the case where owner == spender
    function _spendAllowance(
        address owner,
        address spender,
        uint256 amount
    ) internal override {
        if (owner == spender) return;
        super._spendAllowance(owner, spender, amount);
    }
}
