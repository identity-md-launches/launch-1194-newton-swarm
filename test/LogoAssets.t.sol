// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LogoPng} from "../src/LogoPng.sol";

interface VmLogo {
    function readFileBinary(string calldata path) external view returns (bytes memory);
    function expectRevert(bytes4 selector) external;
}

/// @notice These tests inspect the actual delivered PNGs, without an RPC or dependencies.
/// @dev They do not claim to test the financial launch described as branding context.
contract LogoAssetsTest {
    VmLogo private constant vm = VmLogo(address(uint160(uint256(keccak256("hevm cheat code")))));

    function testMascotPng() public view {
        LogoPng.validate(vm.readFileBinary("logos/logo-1.png"));
    }

    function testGeometricPng() public view {
        LogoPng.validate(vm.readFileBinary("logos/logo-2.png"));
    }

    function testLettermarkPng() public view {
        LogoPng.validate(vm.readFileBinary("logos/logo-3.png"));
    }

    function testEmblemPng() public view {
        LogoPng.validate(vm.readFileBinary("logos/logo-4.png"));
    }

    function testMemePng() public view {
        LogoPng.validate(vm.readFileBinary("logos/logo-5.png"));
    }

    function testSelectedLogoIsTheGeometricOption() public view {
        bytes memory chosen = vm.readFileBinary("artifacts/logo.png");
        LogoPng.validate(chosen);
        require(keccak256(chosen) == keccak256(vm.readFileBinary("logos/logo-2.png")), "wrong primary logo");
    }

    function testFiveDifferentImages() public view {
        string[5] memory paths =
            ["logos/logo-1.png", "logos/logo-2.png", "logos/logo-3.png", "logos/logo-4.png", "logos/logo-5.png"];
        bytes32[5] memory hashes;
        for (uint256 i; i < paths.length; ++i) {
            hashes[i] = keccak256(vm.readFileBinary(paths[i]));
            for (uint256 j; j < i; ++j) {
                require(hashes[i] != hashes[j], "duplicate option");
            }
        }
    }

    function validateExternal(bytes memory png) external pure {
        LogoPng.validate(png);
    }

    function testRejectsNonPng() public {
        bytes memory png = vm.readFileBinary("logos/logo-2.png");
        png[0] = 0;
        vm.expectRevert(LogoPng.InvalidPng.selector);
        this.validateExternal(png);
    }

    function testRejectsMissingImageData() public {
        // Valid header followed immediately by IEND, without compressed pixels.
        bytes memory png = vm.readFileBinary("logos/logo-2.png");
        bytes memory empty = new bytes(57);
        for (uint256 i; i < 33; ++i) {
            empty[i] = png[i];
        }
        empty[37] = 0x49;
        empty[38] = 0x45;
        empty[39] = 0x4e;
        empty[40] = 0x44;
        vm.expectRevert(LogoPng.InvalidPng.selector);
        this.validateExternal(empty);
    }

    function testRejectsTruncatedChunk() public {
        bytes memory png = vm.readFileBinary("logos/logo-2.png");
        png[33] = 0x7f; // First chunk claims far more bytes than are in the file.
        vm.expectRevert(LogoPng.InvalidPng.selector);
        this.validateExternal(png);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzzRejectsWrongWidth(uint32 width) public {
        if (width == 1024) width = 1025;
        bytes memory png = vm.readFileBinary("logos/logo-2.png");
        png[16] = bytes1(uint8(width >> 24));
        png[17] = bytes1(uint8(width >> 16));
        png[18] = bytes1(uint8(width >> 8));
        png[19] = bytes1(uint8(width));
        vm.expectRevert(LogoPng.InvalidDimensions.selector);
        this.validateExternal(png);
    }
}
