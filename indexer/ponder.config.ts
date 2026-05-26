import { createConfig } from "ponder";

import { LendlePoolAbi } from "./abis/LendlePool";
import { L1StandardBridgeAbi } from "./abis/L1StandardBridge";
import { DecisionLogAbi } from "./abis/DecisionLog";
import { SGSMMVaultAbi } from "./abis/SGSMMVault";

// Mantle Mainnet: 5000, Mantle Sepolia: 5003.
// Cross-chain: Ethereum Mainnet (1) for L1 bridge event indexing.
//
// The startBlock for each contract is set to ~7 days of blocks back for
// fast dev iteration. Production deploy should set wider windows.

const MANTLE_MAINNET_LATEST = 95_840_000; // anchor point May 2026; update via cast block-number
const ETH_MAINNET_LATEST = 25_180_000;

// Block-time approximations for relative startBlock math
const MANTLE_BLOCKS_PER_DAY = 43_200; // ~2s blocks
const ETH_BLOCKS_PER_DAY = 7_200;     // ~12s blocks

const SEVEN_DAYS = 7;

export default createConfig({
  chains: {
    mantle: {
      id: 5000,
      rpc: process.env.PONDER_RPC_URL_5000 ?? "https://rpc.mantle.xyz",
    },
    ethereum: {
      id: 1,
      rpc: process.env.PONDER_RPC_URL_1 ?? "https://ethereum-rpc.publicnode.com",
    },
  },
  contracts: {
    LendlePool: {
      chain: "mantle",
      abi: LendlePoolAbi,
      address: "0xCFa5aE7c2CE8Fadc6426C1ff872cA45378Fb7cF3",
      startBlock: MANTLE_MAINNET_LATEST - MANTLE_BLOCKS_PER_DAY * SEVEN_DAYS,
    },
    L1StandardBridge: {
      chain: "ethereum",
      abi: L1StandardBridgeAbi,
      address: "0x95fC37A27a2f68e3A647CDc081F0A89bb47c3012",
      startBlock: ETH_MAINNET_LATEST - ETH_BLOCKS_PER_DAY * SEVEN_DAYS,
    },
    // SGSMM contracts — addresses filled after Phase 4 Sepolia deploy.
    // Comment out until deployed; uncomment + supply addresses post-deploy.
    // DecisionLog: {
    //   chain: "mantleSepolia",
    //   abi: DecisionLogAbi,
    //   address: process.env.DECISION_LOG_ADDRESS as `0x${string}`,
    //   startBlock: Number(process.env.DECISION_LOG_START_BLOCK ?? 0),
    // },
    // SGSMMVault: {
    //   chain: "mantleSepolia",
    //   abi: SGSMMVaultAbi,
    //   address: process.env.SGSMM_VAULT_ADDRESS as `0x${string}`,
    //   startBlock: Number(process.env.SGSMM_VAULT_START_BLOCK ?? 0),
    // },
  },
});
