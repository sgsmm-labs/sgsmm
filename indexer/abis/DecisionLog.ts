// SGSMM DecisionLog event ABI — mirror of contracts/src/DecisionLog.sol

export const DecisionLogAbi = [
  {
    type: "event",
    anonymous: false,
    name: "Decision",
    inputs: [
      { indexed: true, name: "cycle", type: "uint64" },
      { indexed: true, name: "wallet", type: "address" },
      { indexed: true, name: "action", type: "uint8" },
      { indexed: false, name: "sortinoMicros", type: "int128" },
      { indexed: false, name: "sleevePctBps", type: "uint32" },
      { indexed: false, name: "navAfter", type: "uint256" },
      { indexed: false, name: "reasonCode", type: "uint32" },
    ],
  },
  {
    type: "event",
    anonymous: false,
    name: "VaultFrozen",
    inputs: [
      { indexed: true, name: "cycle", type: "uint64" },
      { indexed: false, name: "vaultDrawdownBps", type: "uint256" },
      { indexed: false, name: "freezeUntilTimestamp", type: "uint256" },
    ],
  },
  {
    type: "event",
    anonymous: false,
    name: "VaultUnfrozen",
    inputs: [{ indexed: true, name: "cycle", type: "uint64" }],
  },
] as const;
