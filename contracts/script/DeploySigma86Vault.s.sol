// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Sigma86Vault.sol";

contract DeploySigma86Vault is Script {
    function run() external {
        // Read the private key from the environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        vm.startBroadcast(deployerPrivateKey);

        // Dummy addresses for Testnet integration
        address upkeepAgent = 0x02777053d6764996e594c3E88AF1D58D5363a2e6; // Chainlink Automation Registry mock
        address oneInchRouter = 0x1111111254EEB25477B68fb85Ed929f73A960582; // 1inch v5 Router
        address priceFeed = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Arbitrum Sepolia ETH/USD mock
        uint256 maxSlippageBps = 100; // 1%

        // Deploy the Vault
        Sigma86Vault vault = new Sigma86Vault(upkeepAgent, oneInchRouter, priceFeed, maxSlippageBps);

        console.log("Sigma86Vault deployed to:", address(vault));

        vm.stopBroadcast();
    }
}
