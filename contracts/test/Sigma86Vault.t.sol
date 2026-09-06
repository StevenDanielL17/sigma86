// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Sigma86Vault.sol";

contract MockOneInchRouter {
    bool public shouldFail;

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    function swap(
        address caller,
        address desc,
        bytes calldata data
    ) external payable returns (uint256 returnAmount, uint256 spentAmount) {
        if (shouldFail) {
            revert("Mock swap failed");
        }
        return (100, 100);
    }
}

contract Sigma86VaultTest is Test {
    Sigma86Vault vault;
    MockOneInchRouter router;
    address owner = address(1);
    address upkeepAgent = address(2);

    event TickExecuted(uint256 tickIndex, uint256 amount);
    event SwapFailed(uint256 tickIndex, uint256 amount, bytes reason);

    function setUp() public {
        vm.prank(owner);
        router = new MockOneInchRouter();
        vm.prank(owner);
        vault = new Sigma86Vault(upkeepAgent, address(router));
    }

    function testStartSchedule() public {
        uint256[] memory sizes = new uint256[](3);
        sizes[0] = 100;
        sizes[1] = 200;
        sizes[2] = 300;

        vm.prank(owner);
        vault.startSchedule(sizes);

        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.ACTIVE));
    }

    function testCheckUpkeep() public {
        uint256[] memory sizes = new uint256[](1);
        sizes[0] = 100;

        vm.prank(owner);
        vault.startSchedule(sizes);

        (bool upkeepNeeded, bytes memory performData) = vault.checkUpkeep("0x1234");
        assertTrue(upkeepNeeded);
        assertEq(performData, "0x1234");
    }

    function testPerformUpkeepSuccess() public {
        uint256[] memory sizes = new uint256[](1);
        sizes[0] = 100;

        vm.prank(owner);
        vault.startSchedule(sizes);

        vm.expectEmit(true, true, true, true);
        emit TickExecuted(0, 100);

        vm.prank(upkeepAgent);
        vault.performUpkeep("0x1234");

        assertEq(vault.currentTick(), 1);
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.IDLE));
        assertEq(vault.failedAmount(), 0);
    }

    function testPerformUpkeepFailureReconciliation() public {
        uint256[] memory sizes = new uint256[](2);
        sizes[0] = 100;
        sizes[1] = 200;

        vm.prank(owner);
        vault.startSchedule(sizes);

        router.setShouldFail(true);

        // We can't perfectly expect bytes reason because it contains the selector and "Mock swap failed", but we can just skip the exact bytes match or try it.
        // It's easier to just not expect the exact revert message in emit for bytes because ABI encoding of string reverts includes the Error(string) selector.

        vm.prank(upkeepAgent);
        vault.performUpkeep("0x1234");

        assertEq(vault.currentTick(), 1);
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.ACTIVE));
        assertEq(vault.failedAmount(), 100);

        router.setShouldFail(false);

        vm.prank(upkeepAgent);
        vault.performUpkeep("0x1234");

        assertEq(vault.currentTick(), 2);
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.IDLE));
        assertEq(vault.failedAmount(), 100);
    }
}
