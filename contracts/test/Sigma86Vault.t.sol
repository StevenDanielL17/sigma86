// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Sigma86Vault.sol";

contract MockOneInchRouter {
    bool public shouldFail;

    function setShouldFail(bool _shouldFail) external {
        shouldFail = _shouldFail;
    }

    // Since the Vault uses assembly `call`, we mock a generic fallback or specific swap selector
    fallback() external payable {
        if (shouldFail) {
            revert("Mock swap failed");
        }
        // Return 100 as the returnAmount (32 bytes) and 100 as spentAmount (32 bytes)
        assembly {
            mstore(0x00, 100)
            mstore(0x20, 100)
            return(0x00, 0x40)
        }
    }
}

contract MockChainlinkOracle {
    int256 public answer = 100000000; // e.g. $1.00 with 8 decimals

    function setAnswer(int256 _answer) external {
        answer = _answer;
    }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 _answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return (1, answer, 0, 0, 1);
    }
}

contract Sigma86VaultTest is Test {
    Sigma86Vault vault;
    MockOneInchRouter router;
    MockChainlinkOracle oracle;
    address owner = address(1);
    address upkeepAgent = address(2);

    event TickExecuted(uint256 tickIndex, uint256 amount);
    event SwapFailed(uint256 tickIndex, uint256 amount, bytes reason);

    function setUp() public {
        vm.startPrank(owner);
        router = new MockOneInchRouter();
        oracle = new MockChainlinkOracle();
        vault = new Sigma86Vault(upkeepAgent, address(router), address(oracle), 100);
        vm.stopPrank();
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
