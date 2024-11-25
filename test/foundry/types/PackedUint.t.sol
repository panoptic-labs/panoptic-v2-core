// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PackedUintLibrary} from "@types/PackedUint.sol";

contract PackedUintTest is Test {
    using PackedUintLibrary for uint256;
    using PackedUintLibrary for uint128;

    function testPack256To128() public {
        assertEq(uint256(0).pack(), 0);
        assertEq(uint256(1).pack(), (2 ** 119) << (8 + 0));
        assertEq(uint256(type(uint256).max).pack(), (uint128(type(uint120).max) << 8) + 255);

        // Test some random values
        for (uint i = 0; i < 100; i++) {
            uint256 value = uint256(keccak256(abi.encode(i)));
            uint128 packed = value.pack();
            uint8 n = value.mostSignificantBit();
            uint128 e = value.getMantissaX119(n);
            assertEq(uint128(packed), (e << 8) + n);
        }
    }

    function testPack256To128_packFuzz(uint256 x) public {
        uint128 packed = x.pack();
        uint8 n = x.mostSignificantBit();
        uint128 e = x.getMantissaX119(n);
        if (x == 0) {
            assertEq(packed, 0);
        } else {
            assertEq(uint128(packed), (e << 8) + n);
        }

        uint256 newX = uint256(keccak256(abi.encode(x)));
        packed = newX.pack();
        n = newX.mostSignificantBit();
        e = newX.getMantissaX119(n);
        assertEq(uint128(packed), (e << 8) + n);
    }

    function testPackUnpack() public {
        uint128 packed = uint256(0).pack();
        assertEq(packed.unpack(), 0);
        packed = uint256(1).pack();
        assertEq(packed.unpack(), 1);
        packed = uint256(type(uint256).max).pack();
        assertApproxEqAbs(packed.unpack(), type(uint256).max, 2 ** (256 - 120) - 1);
    }

    function testPackUnpack_packFuzz(uint256 x) public {
        uint128 packed = uint256(x).pack();
        uint8 n = x.mostSignificantBit();
        if (n >= 119) {
            uint256 ppp = packed.unpack();
            assertApproxEqAbs(packed.unpack(), x, 2 ** (n - 119));
            assertApproxEqRel(packed.unpack(), x, 1); // accurate within 1/1e18
        } else {
            assertEq(packed.unpack(), x);
        }
    }

    function testAdd() public {
        uint128 a = uint256(1).pack();
        uint128 b = uint128(2).pack();
        assertEq(PackedUintLibrary.add(a, b).unpack(), 3);

        a = uint256(type(uint256).max).pack();
        b = uint256(70000 + uint256(type(uint136).max)).pack();

        vm.expectRevert("Addition overflow");
        PackedUintLibrary.add(a, b);
    }

    function testAdd_packFuzz(uint128 x, uint128 y) public {
        x = (x % 256) + uint128(uint256(keccak256(abi.encode(x))) << 8);
        y = (y % 256) + uint128(uint256(keccak256(abi.encode(y))) << 8);
        vm.assume((x > 256) && (y > 256));
        if (x.unpack() > type(uint256).max - y.unpack()) {
            vm.expectRevert("Addition overflow");
            PackedUintLibrary.add(x, y);
        } else {
            uint128 add0 = PackedUintLibrary.add(x, y);
            assertApproxEqRel(add0.unpack(), x.unpack() + y.unpack(), 1);
        }
    }

    function testSub() public {
        uint128 a = uint128(3).pack();
        uint128 b = uint128(2).pack();
        assertEq(PackedUintLibrary.sub(a, b).unpack(), 1);

        a = uint128(1).pack();
        b = uint128(2).pack();
        vm.expectRevert("Underflow");
        PackedUintLibrary.sub(a, b);
    }

    function testSub_packFuzz(uint128 x, uint128 y) public {
        x = (x % 256) + uint128(uint256(keccak256(abi.encode(x))) << 8);
        y = (y % 256) + uint128(uint256(keccak256(abi.encode(y))) << 8);
        vm.assume((x > 256) && (y > 256));

        if (x.unpack() < y.unpack()) {
            vm.expectRevert("Underflow");
            PackedUintLibrary.sub(x, y);
        } else {
            uint128 sub0 = PackedUintLibrary.sub(x, y);
            assertApproxEqRel(sub0.unpack(), x.unpack() - y.unpack(), 1);
        }
    }

    function testMul() public {
        uint128 a = uint128(3).pack();
        uint128 b = uint128(2).pack();
        assertEq(PackedUintLibrary.mul(a, b).unpack(), 6);

        a = (type(uint256).max).pack();
        b = (type(uint256).max).pack();
        vm.expectRevert("Multiplication overflow");
        PackedUintLibrary.mul(a, b);
    }

    function testMul_packFuzz(uint128 x, uint128 y) public {
        x = (x % 256) + uint128(uint256(keccak256(abi.encode(x))) << 8);
        y = (y % 256) + uint128(uint256(keccak256(abi.encode(y))) << 8);
        console.log("xu, yu", x.unpack(), y.unpack());
        vm.assume((x > 256) && (y > 256));
        if (x.unpack() == 0 || y.unpack() == 0) {
            assertEq(PackedUintLibrary.mul(x, y).unpack(), 0);
        } else if (
            (x.unpack() > type(uint256).max / y.unpack()) ||
            (y.unpack() > type(uint256).max / x.unpack())
        ) {
            console2.log("expect overflox");
            vm.expectRevert("Multiplication overflow");
            PackedUintLibrary.mul(x, y);
        } else {
            console2.log("expect NO overflox");
            assertApproxEqRel(PackedUintLibrary.mul(x, y).unpack(), x.unpack() * y.unpack(), 1);
        }
    }

    function testDiv() public {
        uint128 a = uint256(6).pack();
        uint128 b = uint256(2).pack();
        assertEq(PackedUintLibrary.div(a, b).unpack(), 3);

        a = uint256(7).pack();
        b = uint256(2).pack();
        assertEq(PackedUintLibrary.div(a, b).unpack(), 3); // Integer division rounds down

        a = uint128(1).pack();
        b = uint128(0).pack();
        vm.expectRevert("Division by zero");
        PackedUintLibrary.div(a, b);
    }

    function testDiv_packFuzz(uint128 x, uint128 y) public {
        x = (x % 256) + uint128(uint256(keccak256(abi.encode(x))) << 8);
        y = (y % 256) + uint128(uint256(keccak256(abi.encode(y))) << 8);
        vm.assume((x > 256) && (y > 256));

        if (y.unpack() == 0) {
            vm.expectRevert("Division by zero");
            PackedUintLibrary.div(x, y);
        } else {
            assertApproxEqRel(PackedUintLibrary.div(x, y).unpack(), x.unpack() / y.unpack(), 1);
        }
    }

    function testMostSignificantBit() public {
        assertEq(PackedUintLibrary.mostSignificantBit(0), 0);
        assertEq(PackedUintLibrary.mostSignificantBit(1), 0);
        assertEq(PackedUintLibrary.mostSignificantBit(2), 1);
        assertEq(PackedUintLibrary.mostSignificantBit(3), 1);
        assertEq(PackedUintLibrary.mostSignificantBit(4), 2);
        assertEq(PackedUintLibrary.mostSignificantBit(7), 2);
        assertEq(PackedUintLibrary.mostSignificantBit(8), 3);
        assertEq(PackedUintLibrary.mostSignificantBit(type(uint256).max), 255);
    }
}
