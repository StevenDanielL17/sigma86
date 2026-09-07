// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Sigma86Vault.sol";

// ─────────────────────────────────────────────────────────────────────────────
// MOCKS
// ─────────────────────────────────────────────────────────────────────────────

contract MockOneInchRouter {
    bool public shouldFail;
    uint256 public returnAmountOverride;

    // Default: 5_000_000 = 5 USDC (6 dec). Realistic for ~0.3-1 token at $10 oracle price.
    // Oracle check: amountToSwap=1e18 → expectedReturn=(1e18*1e9)/1e20=10_000_000, minReturn=9_900_000 at 100bps.
    // 5_000_000 < 9_900_000 → FAILS oracle (for "low returnAmount" tests).
    // For "pass" tests: set to 15_000_000 (above minReturn).
    constructor() { returnAmountOverride = 15_000_000; }

    function setShouldFail(bool _v) external { shouldFail = _v; }
    function setReturnAmount(uint256 _v) external { returnAmountOverride = _v; }

    fallback() external payable {
        if (shouldFail) revert("Mock swap failed");
        uint256 ret = returnAmountOverride;
        assembly {
            mstore(0x00, ret)
            mstore(0x20, ret)
            return(0x00, 0x40)
        }
    }
}

contract MockChainlinkOracle {
    int256 public answer;
    constructor(int256 _answer) { answer = _answer; }
    function setAnswer(int256 _answer) external { answer = _answer; }
    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    ) { return (1, answer, 0, block.timestamp, 1); }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// INTEGRATION TEST SUITE
// ─────────────────────────────────────────────────────────────────────────────

contract Sigma86IntegrationTest is Test {
    Sigma86Vault vault;
    MockOneInchRouter router;
    MockChainlinkOracle oracle;
    MockERC20 token;

    address owner     = address(1);
    address upkeeper  = address(2);
    address recipient = address(42);

    // Oracle: $10.00 with 8 decimals. amountToSwap in 1e18 units.
    // expectedReturn = (amountToSwap * oraclePrice) / 1e20
    // For amountToSwap = 1e18 (1 token), expectedReturn = (1e18 * 1000000000) / 1e20 = 10 USDC units (6 dec)
    // returnAmount from router mock = 100 by default → much larger than minReturn → passes
    int256 constant ORACLE_PRICE = 1_000_000_000; // $10.00 in 8 decimals

    function setUp() public {
        vm.startPrank(owner);
        router  = new MockOneInchRouter();
        oracle  = new MockChainlinkOracle(ORACLE_PRICE);
        token   = new MockERC20();
        vault   = new Sigma86Vault(upkeeper, address(router), address(oracle), 100); // 100 bps = 1%
        vm.stopPrank();
    }

    // ─── SUITE 1: Full pipeline — solver schedule → vault → keeper → completion ─

    /// @notice Simulates the full demo path: solver outputs 3-tick schedule,
    ///         submitted to vault, keeper fires 3 times, vault reaches IDLE.
    function testFullPipelineStartToCompletion() public {
        // Off-chain solver output: 3 trade sizes (in token wei, 1e18)
        uint256[] memory schedule = new uint256[](3);
        schedule[0] = 3e17;  // 0.3 tokens
        schedule[1] = 4e17;  // 0.4 tokens
        schedule[2] = 3e17;  // 0.3 tokens

        vm.prank(owner);
        vault.startSchedule(schedule);
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.ACTIVE));

        // Keeper fires tick 0
        vm.prank(upkeeper);
        vault.performUpkeep("0xdeadbeef");
        assertEq(vault.currentTick(), 1);
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.ACTIVE));

        // Keeper fires tick 1
        vm.prank(upkeeper);
        vault.performUpkeep("0xdeadbeef");
        assertEq(vault.currentTick(), 2);

        // Keeper fires tick 2 — should complete schedule
        vm.prank(upkeeper);
        vault.performUpkeep("0xdeadbeef");
        assertEq(vault.currentTick(), 3);
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.IDLE));
        assertEq(vault.failedAmount(), 0);
    }

    // ─── SUITE 2: Oracle rejection mid-schedule ──────────────────────────────

    /// @notice Oracle rejects the fill when router returns below minReturn.
    ///         - amountToSwap=1e18, oraclePrice=$10 (1e9, 8dec)
    ///         - expectedReturn = (1e18 * 1e9) / 1e20 = 10_000_000 USDC units
    ///         - minReturn at 100bps = 9_900_000
    ///         - Router returning 5_000_000 is BELOW minReturn → oracle rejects
    ///         - Router returning 15_000_000 is ABOVE minReturn → oracle passes
    function testOracleRejectsMidSchedule() public {
        // Set router to return below minReturn — oracle rejects ticks 0 and 1
        router.setReturnAmount(5_000_000);

        uint256[] memory schedule = new uint256[](3);
        schedule[0] = 1e18;
        schedule[1] = 1e18;
        schedule[2] = 1e18;

        vm.prank(owner);
        vault.startSchedule(schedule);

        // Tick 0: oracle rejects (5M < 9.9M minReturn)
        vm.prank(upkeeper);
        vault.performUpkeep("0xdeadbeef");
        assertEq(vault.failedAmount(), 1e18, "Tick 0 should be in failedAmount");
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.ACTIVE), "Must stay ACTIVE");
        assertEq(vault.currentTick(), 1);

        // Tick 1: oracle rejects again
        vm.prank(upkeeper);
        vault.performUpkeep("0xdeadbeef");
        assertEq(vault.failedAmount(), 2e18, "Both ticks should accumulate");

        // Fix router — now returns 15M, above minReturn
        router.setReturnAmount(15_000_000);

        // Tick 2: oracle passes, schedule completes
        vm.prank(upkeeper);
        vault.performUpkeep("0xdeadbeef");
        assertEq(vault.failedAmount(), 2e18, "failedAmount unchanged after success");
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.IDLE));
    }

    // ─── SUITE 3: Abort near-completion (tick N-1 of N) ─────────────────────

    /// @notice Abort at tick 2 of 3 (near-complete, not clean boundary).
    ///         Withdraw remaining token balance back to DAO treasury.
    function testAbortNearCompletionThenWithdraw() public {
        token.mint(address(vault), 3e18);

        uint256[] memory schedule = new uint256[](3);
        schedule[0] = 1e18;
        schedule[1] = 1e18;
        schedule[2] = 1e18;

        vm.prank(owner);
        vault.startSchedule(schedule);

        // Execute tick 0
        vm.prank(upkeeper);
        vault.performUpkeep("0xdeadbeef");

        // Execute tick 1
        vm.prank(upkeeper);
        vault.performUpkeep("0xdeadbeef");
        assertEq(vault.currentTick(), 2);
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.ACTIVE));

        // ABORT with only 1 tick remaining — messy near-complete state
        vm.prank(owner);
        vault.abortSchedule();
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.PAUSED));

        // Vault still holds the un-executed token balance
        uint256 remaining = token.balanceOf(address(vault));
        assertTrue(remaining > 0, "Vault must hold remaining balance after near-complete abort");

        // Withdraw remaining to DAO treasury
        vm.prank(owner);
        vault.withdrawRemaining(address(token), recipient);

        assertEq(token.balanceOf(address(vault)), 0, "Vault must be empty after withdraw");
        assertEq(token.balanceOf(recipient), remaining, "Recipient must receive full remaining balance");
    }

    // ─── SUITE 4: Race condition — consecutive keeper calls ──────────────────

    /// @notice Two keeper calls fire back-to-back in the same block.
    ///         Second call on a completed (IDLE) vault must revert cleanly, not corrupt state.
    function testConsecutiveKeeperCallsAfterCompletion() public {
        uint256[] memory schedule = new uint256[](1);
        schedule[0] = 1e18;

        vm.prank(owner);
        vault.startSchedule(schedule);

        // First call completes the schedule
        vm.prank(upkeeper);
        vault.performUpkeep("0xdeadbeef");
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.IDLE));

        // Second call on a now-IDLE vault must revert (not silently corrupt state)
        vm.prank(upkeeper);
        vm.expectRevert("Invalid state");
        vault.performUpkeep("0xdeadbeef");
    }

    // ─── SUITE 5: checkUpkeep returns false when paused (Keeper won't fire) ──

    /// @notice After abort, checkUpkeep must return false so Keeper stops firing.
    function testCheckUpkeepReturnsFalseWhenPaused() public {
        uint256[] memory schedule = new uint256[](2);
        schedule[0] = 1e18;
        schedule[1] = 1e18;

        vm.prank(owner);
        vault.startSchedule(schedule);

        (bool needed,) = vault.checkUpkeep("");
        assertTrue(needed, "Should need upkeep when ACTIVE");

        vm.prank(owner);
        vault.abortSchedule();

        (bool neededAfterAbort,) = vault.checkUpkeep("");
        assertFalse(neededAfterAbort, "Must NOT need upkeep when PAUSED");
    }

    // ─── SUITE 6: updateSchedule mid-flight re-optimization ──────────────────

    /// @notice Mid-flight re-optimization: after tick 0, owner submits a revised
    ///         schedule for the remaining 2 ticks. Execution resumes on new plan.
    function testMidFlightReoptimization() public {
        uint256[] memory initial = new uint256[](3);
        initial[0] = 1e18;
        initial[1] = 2e18; // original plan
        initial[2] = 2e18; // original plan

        vm.prank(owner);
        vault.startSchedule(initial);

        // Execute tick 0
        vm.prank(upkeeper);
        vault.performUpkeep("0xdeadbeef");
        assertEq(vault.currentTick(), 1);

        // Solver re-optimizes for remaining 2 ticks based on new volatility
        uint256[] memory revised = new uint256[](2);
        revised[0] = 1e17; // revised — much smaller
        revised[1] = 9e17; // revised — back-loaded

        vm.prank(owner);
        vault.updateSchedule(revised);

        // Verify the schedule was updated
        assertEq(vault.tradeSizes(1), 1e17, "Tick 1 should be revised");
        assertEq(vault.tradeSizes(2), 9e17, "Tick 2 should be revised");

        // Execute revised tick 1
        vm.prank(upkeeper);
        vault.performUpkeep("0xdeadbeef");
        assertEq(vault.currentTick(), 2);

        // Execute revised tick 2 — completes
        vm.prank(upkeeper);
        vault.performUpkeep("0xdeadbeef");
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.IDLE));
    }
}
