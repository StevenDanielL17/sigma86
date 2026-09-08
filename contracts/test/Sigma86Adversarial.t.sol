// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Sigma86Vault.sol";

// ─────────────────────────────────────────────────────────────────────────────
// ADVERSARIAL TEST SUITE
// Purpose: Deliberately try to break things that SHOULD fail.
// If any of these tests PASS (green), it means the contract is broken.
// Every test here is designed to catch a silent-pass bug.
// ─────────────────────────────────────────────────────────────────────────────

contract MockOneInchRouter {
    uint256 public returnAmount;
    constructor(uint256 _ret) { returnAmount = _ret; }
    function setReturn(uint256 _ret) external { returnAmount = _ret; }
    fallback() external payable {
        uint256 ret = returnAmount;
        assembly { mstore(0x00, ret) mstore(0x20, ret) return(0x00, 0x40) }
    }
}

contract MockChainlink {
    int256 public price;
    constructor(int256 _p) { price = _p; }
    function setPrice(int256 _p) external { price = _p; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, 0, block.timestamp, 1);
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) external returns (bool) {
        require(balanceOf[msg.sender] >= amt);
        balanceOf[msg.sender] -= amt; balanceOf[to] += amt;
        return true;
    }
}

contract Sigma86AdversarialTest is Test {
    // Oracle: $10 = 1_000_000_000 (8 dec). amountToSwap=1e18.
    // expectedReturn = (1e18 * 1e9) / 1e20 = 10_000_000 USDC units
    // minReturn at 100bps = 9_900_000
    int256 constant PRICE_10_USD = 1_000_000_000;
    uint256 constant ABOVE_MIN   = 15_000_000; // > 9_900_000 → should PASS
    uint256 constant BELOW_MIN   = 5_000_000;  // < 9_900_000 → should FAIL oracle

    address owner    = address(1);
    address upkeeper = address(2);

    // ── ADVERSARIAL 1: Oracle check actually blocks bad fills ─────────────────
    // Prove the oracle check is NOT a no-op by confirming failedAmount increments
    // when router returns below minReturn.
    function testOracleCheckActuallyBlocks() public {
        MockOneInchRouter router = new MockOneInchRouter(BELOW_MIN);
        MockChainlink oracle = new MockChainlink(PRICE_10_USD);

        vm.prank(owner);
        Sigma86Vault vault = new Sigma86Vault(upkeeper, address(router), address(oracle), 100);

        uint256[] memory s = new uint256[](1);
        s[0] = 1e18;
        vm.prank(owner); vault.startSchedule(s);
        vm.prank(upkeeper); vault.performUpkeep("0x");

        // MUST accumulate in failedAmount — proves oracle blocked it
        assertEq(vault.failedAmount(), 1e18, "Oracle must block bad fill");
        // MUST stay IDLE after the single tick completes (even if failed)
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.IDLE));
    }

    // ── ADVERSARIAL 2: Oracle check actually passes good fills ───────────────
    // Prove the oracle check is NOT an always-reject by confirming failedAmount=0
    // when router returns above minReturn.
    function testOracleCheckActuallyAllows() public {
        MockOneInchRouter router = new MockOneInchRouter(ABOVE_MIN);
        MockChainlink oracle = new MockChainlink(PRICE_10_USD);

        vm.prank(owner);
        Sigma86Vault vault = new Sigma86Vault(upkeeper, address(router), address(oracle), 100);

        uint256[] memory s = new uint256[](1);
        s[0] = 1e18;
        vm.prank(owner); vault.startSchedule(s);
        vm.prank(upkeeper); vault.performUpkeep("0x");

        // MUST be zero — proves oracle let the good fill through
        assertEq(vault.failedAmount(), 0, "Oracle must allow good fill");
        assertEq(uint256(vault.currentState()), uint256(Sigma86Vault.State.IDLE));
    }

    // ── ADVERSARIAL 3: Exact boundary — return equal to minReturn passes ──────
    function testOracleBoundaryExactlyAtMinReturn() public {
        uint256 exactMinReturn = 9_900_000; // exactly at threshold
        MockOneInchRouter router = new MockOneInchRouter(exactMinReturn);
        MockChainlink oracle = new MockChainlink(PRICE_10_USD);

        vm.prank(owner);
        Sigma86Vault vault = new Sigma86Vault(upkeeper, address(router), address(oracle), 100);

        uint256[] memory s = new uint256[](1);
        s[0] = 1e18;
        vm.prank(owner); vault.startSchedule(s);
        vm.prank(upkeeper); vault.performUpkeep("0x");

        assertEq(vault.failedAmount(), 0, "Exact minReturn boundary must pass");
    }

    // ── ADVERSARIAL 4: One below boundary fails ───────────────────────────────
    function testOracleBoundaryOneBelowFails() public {
        uint256 oneBelowMinReturn = 9_899_999;
        MockOneInchRouter router = new MockOneInchRouter(oneBelowMinReturn);
        MockChainlink oracle = new MockChainlink(PRICE_10_USD);

        vm.prank(owner);
        Sigma86Vault vault = new Sigma86Vault(upkeeper, address(router), address(oracle), 100);

        uint256[] memory s = new uint256[](1);
        s[0] = 1e18;
        vm.prank(owner); vault.startSchedule(s);
        vm.prank(upkeeper); vault.performUpkeep("0x");

        assertEq(vault.failedAmount(), 1e18, "One below minReturn must fail");
    }

    // ── ADVERSARIAL 5: Non-owner cannot call startSchedule ───────────────────
    function testNonOwnerCannotStartSchedule() public {
        MockOneInchRouter router = new MockOneInchRouter(ABOVE_MIN);
        MockChainlink oracle = new MockChainlink(PRICE_10_USD);

        vm.prank(owner);
        Sigma86Vault vault = new Sigma86Vault(upkeeper, address(router), address(oracle), 100);

        uint256[] memory s = new uint256[](1);
        s[0] = 1e18;

        address attacker = address(99);
        vm.prank(attacker);
        vm.expectRevert("Not owner");
        vault.startSchedule(s);
    }

    // ── ADVERSARIAL 6: Non-upkeeper cannot fire performUpkeep ───────────────
    function testNonUpkeeperCannotPerformUpkeep() public {
        MockOneInchRouter router = new MockOneInchRouter(ABOVE_MIN);
        MockChainlink oracle = new MockChainlink(PRICE_10_USD);

        vm.prank(owner);
        Sigma86Vault vault = new Sigma86Vault(upkeeper, address(router), address(oracle), 100);

        uint256[] memory s = new uint256[](1);
        s[0] = 1e18;
        vm.prank(owner); vault.startSchedule(s);

        address attacker = address(99);
        vm.prank(attacker);
        vm.expectRevert("Not upkeep agent");
        vault.performUpkeep("0x");
    }

    // ── ADVERSARIAL 7: withdrawRemaining blocked when ACTIVE (not PAUSED) ────
    function testWithdrawBlockedWhenActive() public {
        MockOneInchRouter router = new MockOneInchRouter(ABOVE_MIN);
        MockChainlink oracle = new MockChainlink(PRICE_10_USD);
        MockERC20 token = new MockERC20();

        vm.prank(owner);
        Sigma86Vault vault = new Sigma86Vault(upkeeper, address(router), address(oracle), 100);
        token.mint(address(vault), 1e18);

        uint256[] memory s = new uint256[](2);
        s[0] = 1e18; s[1] = 1e18;
        vm.prank(owner); vault.startSchedule(s);

        // Should revert — vault is ACTIVE, not PAUSED
        vm.prank(owner);
        vm.expectRevert("Invalid state");
        vault.withdrawRemaining(address(token), owner);
    }

    // ── ADVERSARIAL 8: updateSchedule blocked to non-owner ───────────────────
    function testUpdateScheduleBlockedToNonOwner() public {
        MockOneInchRouter router = new MockOneInchRouter(ABOVE_MIN);
        MockChainlink oracle = new MockChainlink(PRICE_10_USD);

        vm.prank(owner);
        Sigma86Vault vault = new Sigma86Vault(upkeeper, address(router), address(oracle), 100);

        uint256[] memory s = new uint256[](2);
        s[0] = 1e18; s[1] = 1e18;
        vm.prank(owner); vault.startSchedule(s);

        uint256[] memory revised = new uint256[](2);
        revised[0] = 5e17; revised[1] = 5e17;

        address attacker = address(99);
        vm.prank(attacker);
        vm.expectRevert("Not owner");
        vault.updateSchedule(revised);
    }

    // ── ADVERSARIAL 9: Invalid oracle price (negative) reverts ───────────────
    function testNegativeOraclePriceReverts() public {
        MockOneInchRouter router = new MockOneInchRouter(ABOVE_MIN);
        MockChainlink oracle = new MockChainlink(-1); // negative price

        vm.prank(owner);
        Sigma86Vault vault = new Sigma86Vault(upkeeper, address(router), address(oracle), 100);

        uint256[] memory s = new uint256[](1);
        s[0] = 1e18;
        vm.prank(owner); vault.startSchedule(s);

        vm.prank(upkeeper);
        vm.expectRevert("Invalid oracle price");
        vault.performUpkeep("0x");
    }
}
