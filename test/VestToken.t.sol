// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VestToken} from "../src/VestToken.sol";

contract VestTokenTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;

    VestToken internal token;
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(deployer);
        token = new VestToken();
    }

    // ---------------------------------------------------------------- metadata & supply

    function test_Metadata() public view {
        assertEq(token.name(), "Vest Demo");
        assertEq(token.symbol(), "VDEMO");
        assertEq(token.decimals(), 18);
    }

    function test_MintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_EmitsTransferFromZeroOnDeploy() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        new VestToken();
    }

    function test_NoMintOrBurnEntryPoints() public {
        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", alice, 1);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1);
        calls[2] = abi.encodeWithSignature("burn(uint256)", 1);
        calls[3] = abi.encodeWithSignature("burn(address,uint256)", deployer, 1);
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok, "unexpected mint/burn entry point");
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- transfer

    function test_Transfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, 100);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 100));
        assertEq(token.balanceOf(deployer), SUPPLY - 100);
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_TransferZeroAmount() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_RevertWhen_TransferExceedsBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VestToken.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_RevertWhen_TransferToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(VestToken.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------- approve / transferFrom

    function test_ApproveAndTransferFrom() public {
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, alice, 500);
        vm.prank(deployer);
        assertTrue(token.approve(alice, 500));
        assertEq(token.allowance(deployer, alice), 500);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 300));
        assertEq(token.balanceOf(bob), 300);
        assertEq(token.balanceOf(deployer), SUPPLY - 300);
        assertEq(token.allowance(deployer, alice), 200);
    }

    function test_InfiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_RevertWhen_TransferFromExceedsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(VestToken.ERC20InsufficientAllowance.selector, alice, 10, 11));
        token.transferFrom(deployer, bob, 11);
    }

    function test_RevertWhen_TransferFromExceedsBalance() public {
        vm.prank(alice);
        token.approve(bob, 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(VestToken.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transferFrom(alice, bob, 1);
    }

    function test_RevertWhen_ApproveZeroSpender() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(VestToken.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_TransferConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
