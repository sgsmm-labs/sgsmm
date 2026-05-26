// Mantle L1StandardBridgeProxy (Ethereum mainnet, Optimism-bedrock style)
// ETHBridgeInitiated emitted when a wallet locks ETH on L1 for Mantle-side mint.

export const L1StandardBridgeAbi = [
  {
    type: "event",
    anonymous: false,
    name: "ETHBridgeInitiated",
    inputs: [
      { indexed: true, name: "from", type: "address" },
      { indexed: true, name: "to", type: "address" },
      { indexed: false, name: "amount", type: "uint256" },
      { indexed: false, name: "extraData", type: "bytes" },
    ],
  },
] as const;
