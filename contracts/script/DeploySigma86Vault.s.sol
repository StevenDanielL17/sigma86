// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Sigma86Vault.sol";

/**
 * @title DeploySigma86Vault
 * @notice Automated multi-chain deployment script for Sigma86Vault on Ethereum Sepolia, Arbitrum Sepolia, and Mainnet.
 */
contract DeploySigma86Vault is Script {
    struct NetworkConfig {
        address upkeepAgent;
        address oneInchRouter;
        address priceFeed;
        uint256 maxSlippageBps;
        uint256 maxOracleDelay;
    }

    function getNetworkConfig() internal view returns (NetworkConfig memory config) {
        uint256 chainId = block.chainid;

        // 1. Ethereum Sepolia Testnet (ChainID: 11155111)
        if (chainId == 11155111) {
            config.upkeepAgent = vm.envOr("UPKEEP_AGENT", address(0x86EFBD0b6736Bed994962f9797049422A3A8E8Ad)); // Chainlink Automation 2.1 Registry
            config.oneInchRouter = vm.envOr("ONE_INCH_ROUTER", address(0x111111125421cA6dc452d289314280a0f8842A65)); // 1inch v6 Router
            config.priceFeed = vm.envOr("PRICE_FEED", address(0x694AA1769357215DE4FAC081bf1f309aDC325306)); // Chainlink ETH/USD Sepolia
            config.maxSlippageBps = 100; // 1.00%
            config.maxOracleDelay = 86400; // 24h for testnet heartbeat variance
        }
        // 2. Arbitrum Sepolia Testnet (ChainID: 421614)
        else if (chainId == 421614) {
            config.upkeepAgent = vm.envOr("UPKEEP_AGENT", address(0x86EFBD0b6736Bed994962f9797049422A3A8E8Ad));
            config.oneInchRouter = vm.envOr("ONE_INCH_ROUTER", address(0x111111125421cA6dc452d289314280a0f8842A65));
            config.priceFeed = vm.envOr("PRICE_FEED", address(0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165)); // Chainlink ETH/USD Arb Sepolia
            config.maxSlippageBps = 100;
            config.maxOracleDelay = 86400;
        }
        // 3. Ethereum Mainnet (ChainID: 1)
        else if (chainId == 1) {
            config.upkeepAgent = vm.envOr("UPKEEP_AGENT", address(0x02777053d6764996e594c3E88AF1D58D5363a2e6)); // Automation Registry 2.1
            config.oneInchRouter = vm.envOr("ONE_INCH_ROUTER", address(0x111111125421cA6dc452d289314280a0f8842A65)); // 1inch v6 Router
            config.priceFeed = vm.envOr("PRICE_FEED", address(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419)); // Chainlink ETH/USD Mainnet
            config.maxSlippageBps = 100;
            config.maxOracleDelay = 3600; // 1h mainnet heartbeat
        }
        // 4. Default / Local Anvil (ChainID: 31337 or others)
        else {
            config.upkeepAgent = vm.envOr("UPKEEP_AGENT", msg.sender);
            config.oneInchRouter = vm.envOr("ONE_INCH_ROUTER", address(0x111111125421cA6dc452d289314280a0f8842A65));
            config.priceFeed = vm.envOr("PRICE_FEED", address(0x694AA1769357215DE4FAC081bf1f309aDC325306));
            config.maxSlippageBps = 100;
            config.maxOracleDelay = 86400;
        }
    }

    function run() external returns (address vaultAddress) {
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerPrivateKey);

        NetworkConfig memory config = getNetworkConfig();

        console.log("===================================================================================");
        console.log("= SIGMA86 VAULT: INSTITUTIONAL TESTNET DEPLOYMENT                                  =");
        console.log("===================================================================================");
        console.log("Deployer Address:    ", deployer);
        console.log("Chain ID:            ", block.chainid);
        console.log("Upkeep Agent:        ", config.upkeepAgent);
        console.log("1inch Router:        ", config.oneInchRouter);
        console.log("Price Feed:          ", config.priceFeed);
        console.log("Max Slippage:        ", config.maxSlippageBps, "bps");
        console.log("Max Oracle Delay:    ", config.maxOracleDelay, "seconds");

        vm.startBroadcast(deployerPrivateKey);

        Sigma86Vault vault = new Sigma86Vault(
            config.upkeepAgent,
            config.oneInchRouter,
            config.priceFeed,
            config.maxSlippageBps
        );

        if (config.maxOracleDelay != 3600) {
            vault.setMaxOracleDelay(config.maxOracleDelay);
        }

        vm.stopBroadcast();

        vaultAddress = address(vault);
        console.log("-----------------------------------------------------------------------------------");
        console.log("Sigma86Vault deployed successfully!");
        console.log("Contract Address:    ", vaultAddress);
        console.log("State:               ", "IDLE");
        console.log("Owner:               ", vault.owner());
        console.log("Next step: Register this contract on https://automation.chain.link/ to trigger performUpkeep.");
        console.log("===================================================================================");
    }
}
