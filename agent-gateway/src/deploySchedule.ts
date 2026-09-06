import { createPublicClient, createWalletClient, http, parseAbi } from 'viem';
import { mainnet } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';

/**
 * Hyper-Latency Execution Pipeline for Sigma86
 * Connects to Flashbots RPC to bypass public mempool and execute the AC schedule.
 */

const FLASHBOTS_RPC = 'https://rpc.flashbots.net';

const VAULT_ABI = parseAbi([
  'function startSchedule(uint256[] memory _tradeSizes) external'
]);

/**
 * Programmatically submits the calculated schedule to the Vault via MEV-Share/Flashbots
 */
export async function deploySchedule(tradeSizes: number[], privateKey: `0x${string}`, contractAddress: `0x${string}`) {
  console.log('Initiating Hyper-Latency Schedule Deployment...');
  
  const account = privateKeyToAccount(privateKey);
  
  // We use Viem for hyper-optimized RPC interactions instead of bloated Ethers.js
  const publicClient = createPublicClient({
    chain: mainnet,
    transport: http(FLASHBOTS_RPC)
  });

  const walletClient = createWalletClient({
    account,
    chain: mainnet,
    transport: http(FLASHBOTS_RPC)
  });
  
  // Convert JS numbers to BigInts for EVM compatibility (assuming 18 decimals)
  const formattedSizes = tradeSizes.map(size => BigInt(Math.floor(size * 1e18)));

  try {
    const { request } = await publicClient.simulateContract({
      address: contractAddress,
      abi: VAULT_ABI,
      functionName: 'startSchedule',
      args: [formattedSizes],
      account
    });

    const hash = await walletClient.writeContract(request);
    console.log(`🚀 Transaction deployed to Flashbots: ${hash}`);
    
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    console.log(`✅ Status: ${receipt.status === 'success' ? 'Confirmed' : 'Reverted'}`);
    
  } catch (error) {
    console.error('❌ Deployment Failed:', error);
  }
}
