// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice File-header validation for the logo deliverables, not a launch contract.
/// @dev PNG CRCs, decoding and opacity are checked separately by the image inspector.
library LogoPng {
    error InvalidPng();
    error InvalidDimensions();

    function validate(bytes memory png) internal pure {
        if (png.length < 57) revert InvalidPng();
        bytes8 signature;
        assembly ("memory-safe") {
            signature := mload(add(png, 32))
        }
        if (signature != hex"89504e470d0a1a0a") revert InvalidPng();
        if (u32(png, 8) != 13 || u32(png, 12) != 0x49484452) revert InvalidPng();
        if (u32(png, 16) != 1024 || u32(png, 20) != 1024) revert InvalidDimensions();
        uint8 color = uint8(png[25]);
        if (uint8(png[24]) != 8 || (color != 2 && color != 3 && color != 6)) revert InvalidPng();
        if (png[26] != 0 || png[27] != 0 || png[28] != 0) revert InvalidPng();

        bool hasData = false;
        uint256 cursor = 33;
        while (cursor + 12 <= png.length) {
            uint256 size = u32(png, cursor);
            uint32 kind = u32(png, cursor + 4);
            if (size > png.length - cursor - 12) revert InvalidPng();
            if (kind == 0x49444154 && size > 0) hasData = true; // IDAT
            if (kind == 0x6163544c) revert InvalidPng(); // Animated PNG is not a still logo.
            cursor += size + 12;
            if (kind == 0x49454e44) {
                if (size != 0 || !hasData || cursor != png.length) revert InvalidPng();
                return;
            }
        }
        revert InvalidPng();
    }

    function u32(bytes memory data, uint256 offset) private pure returns (uint32 value) {
        assembly ("memory-safe") {
            value := shr(224, mload(add(add(data, 32), offset)))
        }
    }
}
