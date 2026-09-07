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

interface AutomationCompatibleInterface {
    function checkUpkeep(bytes calldata checkData) external view returns (bool upkeepNeeded, bytes memory performData);
    function performUpkeep(bytes calldata performData) external;
}

interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

contract Sigma86Vault is AutomationCompatibleInterface {
    enum State { IDLE, ACTIVE, PAUSED }
    State public currentState;

    uint256[] public tradeSizes;
    uint256 public currentTick;
    uint256 public failedAmount;

    address public owner;
    address public upkeepAgent;
    address public oneInchRouter;
    
    // Trust Boundary Parameters
    address public priceFeed;
    uint256 public maxSlippageBps;

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

    constructor(address _upkeepAgent, address _oneInchRouter, address _priceFeed, uint256 _maxSlippageBps) {
        owner = msg.sender;
        upkeepAgent = _upkeepAgent;
        oneInchRouter = _oneInchRouter;
        priceFeed = _priceFeed;
        maxSlippageBps = _maxSlippageBps;
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

    function checkUpkeep(bytes calldata checkData) external view override returns (bool upkeepNeeded, bytes memory performData) {
        upkeepNeeded = (currentState == State.ACTIVE && currentTick < tradeSizes.length);
        performData = checkData;
    }

    function performUpkeep(bytes calldata performData) external override onlyUpkeepAgent {
        executeTick(performData);
    }

    /**
     * @notice Triggered by Chainlink Upkeep to execute the next trade in the schedule
     * @param swapData The raw transaction payload from the 1inch API (includes selector)
     */
    function executeTick(bytes calldata swapData) public inState(State.ACTIVE) {
        require(msg.sender == upkeepAgent || msg.sender == address(this), "Not authorized");
        require(currentTick < tradeSizes.length, "Schedule completed");
        
        uint256 amountToSwap = tradeSizes[currentTick];
        address router = oneInchRouter;
        bool success;
        uint256 returnAmount;
        
        // HYPER-LATENCY EXECUTION CORE
        // Bypassing Solidity's ABI encoder and try/catch memory overhead
        assembly {
            let ptr := mload(0x40)
            calldatacopy(ptr, swapData.offset, swapData.length)
            
            // Call 1inch router and write the first 32 bytes of return data (returnAmount) to memory 0x00
            success := call(gas(), router, 0, ptr, swapData.length, 0x00, 0x20)
            if success {
                returnAmount := mload(0x00)
            }
        }
        
        // ON-CHAIN TRUST BOUNDARY: Oracle Slippage Verification
        if (success) {
            (, int256 oraclePrice, , , ) = AggregatorV3Interface(priceFeed).latestRoundData();
            require(oraclePrice > 0, "Invalid oracle price");
            
            // amountToSwap is in 1e18 token units. oraclePrice is in 1e8 (Chainlink USD feeds).
            // Expected USDC return (6 decimals): (amountToSwap * price) / (1e18 * 1e8 / 1e6) = / 1e20
            uint256 expectedReturn = (amountToSwap * uint256(oraclePrice)) / 1e20;
            uint256 minReturn = (expectedReturn * (10000 - maxSlippageBps)) / 10000;
            
            if (returnAmount < minReturn) {
                // The off-chain solver's payload resulted in terrible slippage.
                // Intentional failure to prevent vault drain.
                success = false; 
            }
        }
        
        if (success) {
            emit TickExecuted(currentTick, amountToSwap);
        } else {
            failedAmount += amountToSwap;
            emit SwapFailed(currentTick, amountToSwap, "Slippage tolerance exceeded or call failed");
        }
        
        currentTick++;
        
        if (currentTick >= tradeSizes.length) {
            currentState = State.IDLE;
        }
    }

    /**
     * @notice Mid-flight re-optimization checkpoint: allows the off-chain solver to update
     *         the remaining execution schedule based on realized volatility.
     * @param _newTradeSizes Updated array of trade sizes from current tick onwards.
     */
    function updateSchedule(uint256[] memory _newTradeSizes) external onlyOwner inState(State.ACTIVE) {
        // Replace remaining ticks with the re-optimized schedule
        uint256 remaining = tradeSizes.length - currentTick;
        require(_newTradeSizes.length == remaining, "New schedule must match remaining ticks");
        for (uint256 i = 0; i < remaining; i++) {
            tradeSizes[currentTick + i] = _newTradeSizes[i];
        }
    }

    /**
     * @notice Allows owner to withdraw remaining tokens if the schedule is PAUSED.
     *         This is the critical recovery path after abortSchedule() is called.
     * @param token The ERC20 token address to withdraw.
     * @param recipient The address to send remaining funds to.
     */
    function withdrawRemaining(address token, address recipient) external onlyOwner inState(State.PAUSED) {
        // Low-level ERC20 balanceOf + transfer
        (bool ok, bytes memory bal) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", address(this)));
        require(ok, "balanceOf failed");
        uint256 balance = abi.decode(bal, (uint256));
        if (balance > 0) {
            (bool sent, ) = token.call(abi.encodeWithSignature("transfer(address,uint256)", recipient, balance));
            require(sent, "Transfer failed");
        }
    }

    /**
     * @notice Allows the owner to update the upkeep agent address.
     *         Required in case the Chainlink Keeper registry changes the caller.
     */
    function updateUpkeepAgent(address _newAgent) external onlyOwner {
        upkeepAgent = _newAgent;
    }
}
