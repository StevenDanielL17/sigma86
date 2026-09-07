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

    /**
     * @notice THE CRITICAL C-2 PATH: Abort mid-schedule, then withdraw remaining tokens.
     * Schedule has 3 ticks. Execute tick 0 (success). Execute tick 1 (abort). 
     * Confirm PAUSED. Call withdrawRemaining. Confirm balance transferred.
     */
    function testAbortMidScheduleThenWithdraw() public {
        // Deploy a mock ERC20 token and fund the vault
        MockERC20 token = new MockERC20();
        token.mint(address(vault), 600); // fund vault with 600 tokens

        uint256[] memory sizes = new uint256[](3);
        sizes[0] = 100;
        sizes[1] = 200;
        sizes[2] = 300;

        vm.prank(owner);
        vault.startSchedule(sizes);

        // Execute tick 0 successfully
        vm.prank(upkeepAgent);
        vault.performUpkeep("0x1234");
        assertEq(vault.currentTick(), 1);
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.ACTIVE));

        // ABORT mid-schedule (after 1 of 3 ticks)
        vm.prank(owner);
        vault.abortSchedule();
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.PAUSED));

        // Check vault still holds remaining balance
        uint256 vaultBalance = token.balanceOf(address(vault));
        assertTrue(vaultBalance > 0, "Vault must hold remaining tokens");

        // Withdraw remaining tokens back to owner
        address recipient = address(42);
        vm.prank(owner);
        vault.withdrawRemaining(address(token), recipient);

        // Confirm funds were transferred
        assertEq(token.balanceOf(recipient), vaultBalance);
        assertEq(token.balanceOf(address(vault)), 0);
    }
}

// Minimal ERC20 mock for the withdraw test
contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
