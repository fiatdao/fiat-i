// SPDX-License-Identifier: GPL-3.0-or-later

// Copyright (C) 2015, 2016, 2017  DappHub, LLC

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.

// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity >=0.5.8;

import {DSAuth, DSMath} from "./DSToken.sol";

contract DSNote {
    event LogNote(
        bytes4 indexed sig,
        address indexed guy,
        bytes32 indexed foo,
        bytes32 indexed bar,
        uint256 wad,
        bytes fax
    ) anonymous;

    modifier note() {
        bytes32 foo;
        bytes32 bar;
        uint256 wad;

        assembly {
            foo := calldataload(4)
            bar := calldataload(36)
            wad := callvalue()
        }

        _;

        emit LogNote(msg.sig, msg.sender, foo, bar, wad, msg.data);
    }
}

contract DSThing is DSAuth, DSNote, DSMath {
    function S(string memory s) internal pure returns (bytes4) {
        return bytes4(keccak256(abi.encodePacked(s)));
    }
}

contract DSValue is DSThing {
    bool public has;
    bytes32 public val;

    function peek() public view returns (bytes32, bool) {
        return (val, has);
    }

    function read() public view returns (bytes32) {
        bytes32 wut;
        bool haz;
        (wut, haz) = peek();
        require(haz, "haz-not");
        return wut;
    }

    function poke(bytes32 wut) public note auth {
        val = wut;
        has = true;
    }

    function void() public note auth {
        // unset the value
        has = false;
    }
}
