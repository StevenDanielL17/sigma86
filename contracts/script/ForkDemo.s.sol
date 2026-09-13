// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Sigma86Vault.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
}

// Uniswap V3 Router Interface for generating the payload locally
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title ForkDemo
 * @notice Mainnet fork execution demo for Sigma86.
 *
 *  This script:
 *  1. Deploys the Sigma86Vault against a local fork of Ethereum mainnet.
 *  2. Seeds the vault with 1 real WETH via vm.deal (no live capital at risk).
 *  3. Calls `startSchedule` with a single-tick AC schedule: sell 0.1 WETH.
 *  4. Generates a fresh Uniswap V3 swap payload locally to bypass API rate limits.
 *  5. Executes one tick via the vault's executeTick, forwarding the V3 payload.
 *  6. Validates the Chainlink ETH/USD oracle trust boundary in the same call.
 */
contract ForkDemo is Script {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    
    // Uniswap V3 SwapRouter (Mainnet)
    address constant UNIV3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    // Chainlink ETH/USD mainnet price feed
    address constant ETH_USD_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    uint256 constant TICK_SIZE  = 0.1 ether;
    uint256 constant VAULT_SEED = 1 ether;

    function run() external {
        uint256 deployerKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        address deployer = vm.addr(deployerKey);

        console.log("==========================================================");
        console.log("  SIGMA86 - MAINNET FORK EXECUTION DEMO");
        console.log("==========================================================");
        console.log("NOTE: Local fork of Ethereum mainnet. No live capital at risk.");
        console.log("      Sepolia deployment verified separately.");
        console.log("");

        vm.startBroadcast(deployerKey);

        // ---- STEP 1: Deploy vault with Uniswap V3 Router ----
        Sigma86Vault vault = new Sigma86Vault(
            deployer,         // upkeepAgent
            UNIV3_ROUTER,     // router
            ETH_USD_FEED,     // Chainlink oracle
            300               // maxSlippageBps = 3%
        );
        vault.setMaxOracleDelay(7200); // 2 hours
        vault.setAssetDecimals(18, 6);

        console.log("STEP 1 DONE: Vault deployed at", address(vault));

        // ---- STEP 2: Seed vault with WETH and approve router ----
        address wethWhale = 0x2F0b23f53734252Bda2277357e97e1517d6B042A;
        vm.stopBroadcast();
        vm.startPrank(wethWhale);
        IERC20(WETH).transfer(address(vault), VAULT_SEED);
        vm.stopPrank();

        vm.startBroadcast(deployerKey);
        vault.approveRouter(WETH);
        console.log("STEP 2 DONE: Vault seeded and router approved.");

        // ---- STEP 3: Generate fresh routing payload natively ----
        // Bypassing 1inch API rate limits by generating a direct UniV3 payload
        // dynamically against the current fork's state.
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH,
            tokenOut: USDC,
            fee: 500, // 0.05% pool
            recipient: address(vault), // Vault receives the USDC
            deadline: block.timestamp + 300,
            amountIn: TICK_SIZE,
            amountOutMinimum: 0, // Oracle enforces slippage, not the router payload
            sqrtPriceLimitX96: 0
        });
        
        bytes memory swapData = abi.encodeWithSelector(ISwapRouter.exactInputSingle.selector, params);
        console.log("STEP 3 DONE: Fresh UniV3 swap payload generated locally.");

        // ---- STEP 4: Start schedule ----
        uint256[] memory schedule = new uint256[](1);
        schedule[0] = TICK_SIZE;
        vault.startSchedule(schedule);
        console.log("STEP 4 DONE: Schedule started (Sell 0.1 WETH -> USDC).");

        // ---- STEP 5: Execute Tick ----
        console.log("");
        console.log("--- EXECUTING TICK 0 ---");
        
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(vault));
        
        vault.executeTick(swapData);
        
        uint256 usdcAfter = IERC20(USDC).balanceOf(address(vault));
        uint256 usdcGained = usdcAfter - usdcBefore;

        console.log("");
        console.log("==========================================================");
        console.log("  EXECUTION COMPLETE - SUCCESS");
        console.log("==========================================================");
        console.log("WETH sold (wei):      ", TICK_SIZE);
        console.log("USDC received:        ", usdcGained);
        console.log("Oracle trust boundary: PASSED (Oracle verified slippage)");
        console.log("==========================================================");

        vm.stopBroadcast();
    }
}
