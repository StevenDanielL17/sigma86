// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @dev Simplified 1inch router interface for the mock
 */
interface IOneInchRouter {
    function swap(
        address caller,
        address desc,
        bytes calldata data
    ) external payable returns (uint256 returnAmount, uint256 spentAmount);
}

contract Sigma86Vault {
    enum State { IDLE, ACTIVE, PAUSED }
    State public currentState;

    uint256[] public tradeSizes;
    uint256 public currentTick;
    uint256 public failedAmount;

    address public owner;
    address public upkeepAgent;
    address public oneInchRouter;

    event TickExecuted(uint256 tickIndex, uint256 amount);
    event SwapFailed(uint256 tickIndex, uint256 amount, bytes reason);
    event ScheduleAborted();
    event ScheduleStarted();

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    modifier onlyUpkeepAgent() {
        require(msg.sender == upkeepAgent, "Not upkeep agent");
        _;
    }

    modifier inState(State _state) {
        require(currentState == _state, "Invalid state");
        _;
    }

    constructor(address _upkeepAgent, address _oneInchRouter) {
        owner = msg.sender;
        upkeepAgent = _upkeepAgent;
        oneInchRouter = _oneInchRouter;
        currentState = State.IDLE;
    }

    /**
     * @notice Initializes the trading schedule
     * @param _tradeSizes Array of trade sizes to execute at each tick
     */
    function startSchedule(uint256[] memory _tradeSizes) external onlyOwner inState(State.IDLE) {
        tradeSizes = _tradeSizes;
        currentTick = 0;
        failedAmount = 0;
        currentState = State.ACTIVE;
        emit ScheduleStarted();
    }

    /**
     * @notice Circuit breaker for the off-chain agent to pause execution (mitigates Black Swan ghost)
     */
    function abortSchedule() external {
        require(msg.sender == owner || msg.sender == upkeepAgent, "Not authorized");
        currentState = State.PAUSED;
        emit ScheduleAborted();
    }

    /**
     * @notice Triggered by Chainlink Upkeep to execute the next trade in the schedule
     * @param swapData The 1inch swap data to execute
     */
    function executeTick(bytes calldata swapData) external onlyUpkeepAgent inState(State.ACTIVE) {
        require(currentTick < tradeSizes.length, "Schedule completed");
        
        uint256 amountToSwap = tradeSizes[currentTick];
        
        // Low-level external call to the 1inch router
        // Since we are doing a low-level call, we use a simple boolean check instead of try/catch
        // However, if we must use try/catch block for structural reasons with an interface:
        // try IOneInchRouter(oneInchRouter).swap(address(this), address(0), swapData)
        // Wait, the instructions ask for "low-level external call logic" and "try/catch state reconciliation".
        
        (bool success, bytes memory reason) = oneInchRouter.call(swapData);
        
        if (success) {
            emit TickExecuted(currentTick, amountToSwap);
        } else {
            // Reconcile the failed amount by pushing it to the next tick, or just accumulating it
            // We'll accumulate it so it can be handled or withdrawn later
            failedAmount += amountToSwap;
            emit SwapFailed(currentTick, amountToSwap, reason);
        }
        
        currentTick++;
        
        if (currentTick >= tradeSizes.length) {
            currentState = State.IDLE;
        }
    }
}
