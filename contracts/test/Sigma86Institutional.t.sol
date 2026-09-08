// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Sigma86Vault.sol";

contract MockRouter {
    uint256 public returnAmount;
    bool public shouldFail;
    bool public zeroBytesReturn;

    constructor(uint256 _ret) {
        returnAmount = _ret;
    }

    function setReturn(uint256 _ret) external {
        returnAmount = _ret;
    }

    function setShouldFail(bool _fail) external {
        shouldFail = _fail;
    }

    function setZeroBytesReturn(bool _zero) external {
        zeroBytesReturn = _zero;
    }

    receive() external payable {}

    fallback() external payable {
        if (shouldFail) revert("Mock swap failed");
        if (zeroBytesReturn) {
            return;
        }
        uint256 ret = returnAmount;
        assembly {
            mstore(0x00, ret)
            mstore(0x20, ret)
            return(0x00, 0x40)
        }
    }
}

contract MockOracleWithDecimals {
    int256 public price;
    uint8 public feedDecimals;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;
    uint256 public updatedAt;

    constructor(int256 _p, uint8 _dec) {
        price = _p;
        feedDecimals = _dec;
        updatedAt = block.timestamp;
    }

    function setPrice(int256 _p) external {
        price = _p;
    }

    function setRounds(uint80 _roundId, uint80 _answeredInRound) external {
        roundId = _roundId;
        answeredInRound = _answeredInRound;
    }

    function setUpdatedAt(uint256 _t) external {
        updatedAt = _t;
    }

    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint256 ts = updatedAt > 0 ? updatedAt : block.timestamp;
        return (roundId, price, 0, ts, answeredInRound);
    }
}

contract InstitutionalMockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt, "Insufficient balance");
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Sigma86InstitutionalTest is Test {
    Sigma86Vault vault;
    MockRouter router;
    MockOracleWithDecimals oracle;
    InstitutionalMockERC20 token;

    address owner = address(1);
    address upkeeper = address(2);
    address safeMultisig = address(3);
    address treasuryRecipient = address(42);

    int256 constant PRICE_10_USD = 1_000_000_000; // $10.00 with 8 decimals
    uint256 constant PASSING_RETURN = 15_000_000;  // 15 USDC (above 9.9M minReturn)
    uint256 constant FAILING_RETURN = 5_000_000;   // 5 USDC (below 9.9M minReturn)

    event CircuitBreakerTriggered(uint256 indexed tickIndex, string reason);
    event ScheduleAborted();
    event ScheduleResumed();
    event ScheduleUpdated(uint256 indexed currentTick, uint256 newRemainingTicks);
    event WithdrawalProposed(address indexed token, address indexed recipient, uint256 releaseTime);
    event WithdrawalExecuted(address indexed token, address indexed recipient, uint256 amount);
    event WithdrawalCancelled(address indexed token, address indexed recipient);

    function setUp() public {
        vm.startPrank(owner);
        router = new MockRouter(PASSING_RETURN);
        oracle = new MockOracleWithDecimals(PRICE_10_USD, 8);
        token = new InstitutionalMockERC20();
        vault = new Sigma86Vault(upkeeper, address(router), address(oracle), 100);
        vm.stopPrank();
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 1. AUTOMATED DYNAMIC CIRCUIT BREAKER TESTS
    // ─────────────────────────────────────────────────────────────────────────

    function testDynamicCircuitBreakerTripsAfterConsecutiveFailures() public {
        router.setReturn(FAILING_RETURN); // Cause oracle slippage failures

        uint256[] memory schedule = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            schedule[i] = 1e18;
        }

        vm.prank(owner);
        vault.startSchedule(schedule);

        // Tick 0 fails (consecutive = 1)
        vm.prank(upkeeper);
        vault.performUpkeep("0x");
        assertEq(vault.consecutiveFailures(), 1);
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.ACTIVE));

        // Tick 1 fails (consecutive = 2)
        vm.prank(upkeeper);
        vault.performUpkeep("0x");
        assertEq(vault.consecutiveFailures(), 2);
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.ACTIVE));

        // Tick 2 fails (consecutive = 3 == maxConsecutiveFailures) -> Dynamic circuit breaker trips!
        vm.expectEmit(true, true, true, true);
        emit CircuitBreakerTriggered(2, "Consecutive slippage breaches exceeded safety limit");
        vm.expectEmit(true, true, true, true);
        emit ScheduleAborted();

        vm.prank(upkeeper);
        vault.performUpkeep("0x");

        assertEq(vault.consecutiveFailures(), 3);
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.PAUSED), "Vault must automatically transition to PAUSED");

        // Subsequent upkeep must revert because vault is paused
        vm.prank(upkeeper);
        vm.expectRevert("Invalid state");
        vault.performUpkeep("0x");
    }

    function testCircuitBreakerResetOnSuccess() public {
        router.setReturn(FAILING_RETURN);

        uint256[] memory schedule = new uint256[](4);
        for (uint256 i = 0; i < 4; i++) {
            schedule[i] = 1e18;
        }

        vm.prank(owner);
        vault.startSchedule(schedule);

        // Ticks 0 and 1 fail (consecutive = 2)
        vm.prank(upkeeper);
        vault.performUpkeep("0x");
        vm.prank(upkeeper);
        vault.performUpkeep("0x");
        assertEq(vault.consecutiveFailures(), 2);

        // Tick 2 succeeds!
        router.setReturn(PASSING_RETURN);
        vm.prank(upkeeper);
        vault.performUpkeep("0x");

        // Consecutive failures must reset to 0
        assertEq(vault.consecutiveFailures(), 0, "Consecutive failures must reset to 0 upon successful tick execution");
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.ACTIVE));
    }

    function testResumeScheduleAfterPause() public {
        uint256[] memory schedule = new uint256[](3);
        schedule[0] = 1e18;
        schedule[1] = 1e18;
        schedule[2] = 1e18;

        vm.prank(owner);
        vault.startSchedule(schedule);

        // Abort to PAUSED
        vm.prank(owner);
        vault.abortSchedule();
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.PAUSED));

        // Non-owner cannot resume
        vm.prank(address(99));
        vm.expectRevert("Not owner");
        vault.resumeSchedule();

        // Owner resumes schedule
        vm.expectEmit(true, true, true, true);
        emit ScheduleResumed();
        vm.prank(owner);
        vault.resumeSchedule();
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.ACTIVE));

        // Upkeeper can continue execution
        vm.prank(upkeeper);
        vault.performUpkeep("0x");
        assertEq(vault.currentTick(), 1);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 2. MULTI-SIGNATURE & GNOSIS SAFE TIMELOCK HARDENING
    // ─────────────────────────────────────────────────────────────────────────

    function testTimelockGuardedWithdrawal() public {
        token.mint(address(vault), 1000e18);

        uint256[] memory schedule = new uint256[](2);
        schedule[0] = 500e18;
        schedule[1] = 500e18;

        vm.prank(owner);
        vault.startSchedule(schedule);
        vm.prank(owner);
        vault.abortSchedule();

        // Enable 2-day institutional timelock (Gnosis Safe governance delay)
        uint256 twoDays = 2 days;
        vm.prank(owner);
        vault.setTimelockDelay(twoDays);
        assertEq(vault.timelockDelay(), twoDays);

        // Immediate withdrawal attempt must revert
        vm.prank(owner);
        vm.expectRevert("Withdrawal not proposed");
        vault.withdrawRemaining(address(token), treasuryRecipient);

        // Propose withdrawal
        uint256 expectedReleaseTime = block.timestamp + twoDays;
        vm.expectEmit(true, true, true, true);
        emit WithdrawalProposed(address(token), treasuryRecipient, expectedReleaseTime);

        vm.prank(owner);
        vault.proposeWithdrawal(address(token), treasuryRecipient);

        // Attempt withdrawal before timelock expiry (1 day elapsed)
        vm.warp(block.timestamp + 1 days);
        vm.prank(owner);
        vm.expectRevert("Timelock not expired");
        vault.withdrawRemaining(address(token), treasuryRecipient);

        // Warp to exact expiry
        vm.warp(expectedReleaseTime);

        vm.expectEmit(true, true, true, true);
        emit WithdrawalExecuted(address(token), treasuryRecipient, 1000e18);

        vm.prank(owner);
        vault.withdrawRemaining(address(token), treasuryRecipient);

        assertEq(token.balanceOf(treasuryRecipient), 1000e18);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function testCancelWithdrawalProposal() public {
        uint256[] memory schedule = new uint256[](1);
        schedule[0] = 100e18;
        vm.prank(owner);
        vault.startSchedule(schedule);
        vm.prank(owner);
        vault.abortSchedule();

        vm.prank(owner);
        vault.setTimelockDelay(1 days);

        vm.prank(owner);
        vault.proposeWithdrawal(address(token), treasuryRecipient);

        // Cancel proposal
        vm.expectEmit(true, true, true, true);
        emit WithdrawalCancelled(address(token), treasuryRecipient);
        vm.prank(owner);
        vault.cancelWithdrawal(address(token), treasuryRecipient);

        // Warping after expiry still fails because proposal was cancelled
        vm.warp(block.timestamp + 2 days);
        vm.prank(owner);
        vm.expectRevert("Withdrawal not proposed");
        vault.withdrawRemaining(address(token), treasuryRecipient);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 3. DECIMAL-NORMALIZED CROSS-ASSET ORACLE MATH
    // ─────────────────────────────────────────────────────────────────────────

    function testCrossAssetDecimalNormalization18to18() public {
        // Test cross-asset: TokenIn (18 dec, e.g. WETH), TokenOut (18 dec, e.g. DAI), Oracle (8 dec)
        vm.prank(owner);
        vault.setAssetDecimals(18, 18);

        // Price: $2,000.00 = 200,000,000,000 (8 dec)
        // 1 TokenIn = 1e18
        // expectedReturn = (1e18 * 2000e8 * 1e18) / (1e18 * 1e8) = 2000e18 DAI units
        uint256 expected = vault.calculateExpectedReturn(1e18, 2000e8);
        assertEq(expected, 2000e18);
    }

    function testCrossAssetDecimalNormalization6to6() public {
        // TokenIn (6 dec, e.g. USDT), TokenOut (6 dec, e.g. USDC), Oracle (8 dec)
        vm.prank(owner);
        vault.setAssetDecimals(6, 6);

        // Price: $1.00 = 100,000,000 (8 dec)
        // 100 USDT = 100e6
        // expectedReturn = (100e6 * 1e8 * 1e6) / (1e6 * 1e8) = 100e6 USDC units
        uint256 expected = vault.calculateExpectedReturn(100e6, 1e8);
        assertEq(expected, 100e6);
    }

    function testCrossAssetDecimalNormalization8to6() public {
        // TokenIn (8 dec, e.g. WBTC), TokenOut (6 dec, e.g. USDC), Oracle (8 dec)
        vm.prank(owner);
        vault.setAssetDecimals(8, 6);

        // WBTC price = $60,000 = 60_000e8
        // 1 WBTC = 1e8
        // expectedReturn = (1e8 * 60_000e8 * 1e6) / (1e8 * 1e8) = 60_000e6 USDC units
        uint256 expected = vault.calculateExpectedReturn(1e8, 60_000e8);
        assertEq(expected, 60_000e6);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 4. MID-FLIGHT RE-OPTIMIZATION WITH ARBITRARY SCHEDULE RESIZING
    // ─────────────────────────────────────────────────────────────────────────

    function testMidFlightScheduleExtensionAndCompression() public {
        uint256[] memory initial = new uint256[](3);
        initial[0] = 1e18;
        initial[1] = 1e18;
        initial[2] = 1e18;

        vm.prank(owner);
        vault.startSchedule(initial);

        // Execute tick 0
        vm.prank(upkeeper);
        vault.performUpkeep("0x");
        assertEq(vault.currentTick(), 1);

        // Re-optimize and extend: instead of 2 ticks remaining, solver expands to 4 smaller ticks
        uint256[] memory extended = new uint256[](4);
        extended[0] = 5e17;
        extended[1] = 5e17;
        extended[2] = 5e17;
        extended[3] = 5e17;

        vm.expectEmit(true, true, true, true);
        emit ScheduleUpdated(1, 4);
        vm.prank(owner);
        vault.updateSchedule(extended);

        // Verify state
        assertEq(vault.getRemainingTicks(), 4);
        uint256[] memory activeSchedule = vault.getSchedule();
        assertEq(activeSchedule.length, 5); // 1 executed + 4 revised
        assertEq(activeSchedule[0], 1e18); // executed history preserved
        assertEq(activeSchedule[1], 5e17);
        assertEq(activeSchedule[4], 5e17);

        // Execute all 4 remaining ticks to completion
        for (uint256 i = 0; i < 4; i++) {
            vm.prank(upkeeper);
            vault.performUpkeep("0x");
        }

        assertEq(vault.currentTick(), 5);
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.IDLE));
        assertEq(vault.getRemainingTicks(), 0);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // 5. ADVANCED TRUST BOUNDARY & STALENESS ATTACK TESTS
    // ─────────────────────────────────────────────────────────────────────────

    function testStaleOracleRoundReverts() public {
        // Oracle answers round 1 for roundId 2 (answeredInRound < roundId)
        oracle.setRounds(2, 1);

        uint256[] memory schedule = new uint256[](1);
        schedule[0] = 1e18;

        vm.prank(owner);
        vault.startSchedule(schedule);

        vm.prank(upkeeper);
        vm.expectRevert("Stale round");
        vault.performUpkeep("0x");
    }

    function testStaleOracleTimestampReverts() public {
        uint256 maxDelay = 1 hours;
        vm.prank(owner);
        vault.setMaxOracleDelay(maxDelay);
        assertEq(vault.maxOracleDelay(), maxDelay);

        uint256[] memory schedule = new uint256[](1);
        schedule[0] = 1e18;

        vm.prank(owner);
        vault.startSchedule(schedule);

        // Oracle updatedAt is 2 hours behind block.timestamp
        oracle.setUpdatedAt(block.timestamp);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(upkeeper);
        vm.expectRevert("Oracle price stale");
        vault.performUpkeep("0x");
    }

    function testZeroByteRouterReturnHandledSafely() public {
        // Router returns 0 bytes instead of 32 bytes (simulating silent or non-standard router)
        router.setZeroBytesReturn(true);

        uint256[] memory schedule = new uint256[](1);
        schedule[0] = 1e18;

        vm.prank(owner);
        vault.startSchedule(schedule);

        // Vault should not read stale scratch space, should detect 0 returnAmount, and record failure
        vm.prank(upkeeper);
        vault.performUpkeep("0x");

        assertEq(vault.failedAmount(), 1e18, "Zero return data must be treated as failed swap");
        assertEq(vault.consecutiveFailures(), 1);
    }

    function testUpdateScheduleWhilePausedAndResume() public {
        // Vault fails 3 times and trips automated circuit breaker
        router.setReturn(FAILING_RETURN);

        uint256[] memory schedule = new uint256[](4);
        schedule[0] = 1e18;
        schedule[1] = 1e18;
        schedule[2] = 1e18;
        schedule[3] = 1e18;

        vm.prank(owner);
        vault.startSchedule(schedule);

        // Trip circuit breaker
        for (uint256 i = 0; i < 3; i++) {
            vm.prank(upkeeper);
            vault.performUpkeep("0x");
        }
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.PAUSED));
        assertEq(vault.currentTick(), 3);

        // Update schedule while PAUSED to re-optimize remaining 1 tick into 2 smaller slices
        uint256[] memory reoptimized = new uint256[](2);
        reoptimized[0] = 5e17;
        reoptimized[1] = 5e17;

        vm.prank(owner);
        vault.updateSchedule(reoptimized);
        assertEq(vault.getRemainingTicks(), 2);

        // Resume schedule
        vm.prank(owner);
        vault.resumeSchedule();
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.ACTIVE));
        assertEq(vault.consecutiveFailures(), 0);

        // Fix router and execute remaining ticks
        router.setReturn(PASSING_RETURN);
        vm.prank(upkeeper);
        vault.performUpkeep("0x");
        vm.prank(upkeeper);
        vault.performUpkeep("0x");

        assertEq(vault.currentTick(), 5);
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.IDLE));
    }

    function testWithdrawRemainingInIdleState() public {
        // Fund vault
        token.mint(address(vault), 1000e18);

        uint256[] memory schedule = new uint256[](1);
        schedule[0] = 1e18;

        vm.prank(owner);
        vault.startSchedule(schedule);

        // Complete schedule -> transitions to IDLE
        vm.prank(upkeeper);
        vault.performUpkeep("0x");
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.IDLE));

        // Owner can withdraw remaining funds in IDLE state without faking an abort
        vm.prank(owner);
        vault.withdrawRemaining(address(token), treasuryRecipient);

        assertEq(token.balanceOf(treasuryRecipient), 1000e18);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function testSetAssetDecimalsExceedingLimitReverts() public {
        vm.prank(owner);
        vm.expectRevert("Invalid decimals");
        vault.setAssetDecimals(37, 18);
    }

    function testSetMaxSlippageBps() public {
        vm.prank(owner);
        vault.setMaxSlippageBps(250);
        assertEq(vault.maxSlippageBps(), 250);

        vm.prank(owner);
        vm.expectRevert("Invalid bps");
        vault.setMaxSlippageBps(10001);
    }
}
