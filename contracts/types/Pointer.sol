// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

type Pointer is uint256;

using PointerLibrary for Pointer global;

library PointerLibrary {
    function createPointer(
        address _location,
        uint48 _start,
        uint48 _size
    ) internal pure returns (Pointer) {
        return
            Pointer.wrap((uint256(_size) << 208) + (uint256(_start) << 160) + uint160(_location));
    }

    function location(Pointer self) internal pure returns (address) {
        return address(uint160(Pointer.unwrap(self)));
    }

    function start(Pointer self) internal pure returns (uint48) {
        return uint48(Pointer.unwrap(self) >> 160);
    }

    function size(Pointer self) internal pure returns (uint48) {
        return uint48(Pointer.unwrap(self) >> 208);
    }

    function data(Pointer self) internal view returns (bytes memory) {
        address _location = self.location();
        uint256 _start = self.start();
        uint256 _size = self.size();

        bytes memory pointerData = new bytes(_size);

        assembly {
            extcodecopy(_location, add(pointerData, 0x20), _start, _size)
        }

        return pointerData;
    }

    function dataStr(Pointer self) internal view returns (string memory) {
        return string(data(self));
    }
}
