// SGSMM Vault event ABI — mirror of contracts/src/SGSMMVault.sol

export const SGSMMVaultAbi = [
  {
    type: "event",
    anonymous: false,
    name: "MirrorEntered",
    inputs: [
      { indexed: true, name: "wallet", type: "address" },
      { indexed: false, name: "amount", type: "uint256" },
      { indexed: false, name: "newDeployedSleeve", type: "uint256" },
    ],
  },
  {
    type: "event",
    anonymous: false,
    name: "MirrorExited",
    inputs: [
      { indexed: true, name: "wallet", type: "address" },
      { indexed: false, name: "amountReturned", type: "uint256" },
      { indexed: false, name: "pnl", type: "int256" },
    ],
  },
] as const;
