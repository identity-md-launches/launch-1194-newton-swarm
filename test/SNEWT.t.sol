// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "../vendor/forge-std/src/Test.sol";
import {SNEWT} from "../src/SNEWT.sol";

contract SNEWTTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    SNEWT token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        token = new SNEWT();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Newton Swarm");
        assertEq(token.symbol(), "SNEWT");
        assertEq(token.decimals(), 18);
    }

    function test_mintsTheWholeSupplyToTheDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function test_deploymentEmitsTransferFromZero() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), address(this), SUPPLY);
        new SNEWT();
    }

    function test_transferMovesExactlyTheAmount() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(this), alice, 1 ether);
        assertTrue(token.transfer(alice, 1 ether));
        assertEq(token.balanceOf(alice), 1 ether);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SNEWT.InsufficientBalance.selector, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.expectRevert(SNEWT.ZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(address(this), alice, 5 ether);
        assertTrue(token.approve(alice, 5 ether));
        assertEq(token.allowance(address(this), alice), 5 ether);

        vm.prank(alice);
        assertTrue(token.transferFrom(address(this), bob, 2 ether));
        assertEq(token.balanceOf(bob), 2 ether);
        assertEq(token.allowance(address(this), alice), 3 ether);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        token.approve(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SNEWT.InsufficientAllowance.selector, 1 ether, 2 ether));
        token.transferFrom(address(this), bob, 2 ether);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 7 ether);
        assertEq(token.allowance(address(this), alice), type(uint256).max);
    }

    function test_approveZeroSpenderReverts() public {
        vm.expectRevert(SNEWT.ZeroAddress.selector);
        token.approve(address(0), 1);
    }

    /// @dev The shapes a hidden mint usually takes. None may exist, from anyone, including the deployer.
    function test_noMintOrAdminSelectorsExist() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "pause()",
            "setMinter(address)",
            "initialize(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], address(this), 1));
            assertFalse(ok, signatures[i]);
            assertEq(token.totalSupply(), SUPPLY, signatures[i]);
        }
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory code = address(token).code;
        for (uint256 i = 0; i < code.length; i++) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(this));
        amount = bound(amount, 0, SUPPLY);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
