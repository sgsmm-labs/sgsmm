// Lendle (Aave V2 fork on Mantle) — subset of IPool ABI relevant to SGSMM indexing.
// Full ABI: query mantlescan.xyz/address/0xCFa5aE7c2CE8Fadc6426C1ff872cA45378Fb7cF3#code

export const LendlePoolAbi = [
  {
    type: "event",
    anonymous: false,
    name: "Deposit",
    inputs: [
      { indexed: true, name: "reserve", type: "address" },
      { indexed: false, name: "user", type: "address" },
      { indexed: true, name: "onBehalfOf", type: "address" },
      { indexed: false, name: "amount", type: "uint256" },
      { indexed: true, name: "referral", type: "uint16" },
    ],
  },
  {
    type: "event",
    anonymous: false,
    name: "Withdraw",
    inputs: [
      { indexed: true, name: "reserve", type: "address" },
      { indexed: true, name: "user", type: "address" },
      { indexed: true, name: "to", type: "address" },
      { indexed: false, name: "amount", type: "uint256" },
    ],
  },
  {
    type: "event",
    anonymous: false,
    name: "Borrow",
    inputs: [
      { indexed: true, name: "reserve", type: "address" },
      { indexed: false, name: "user", type: "address" },
      { indexed: true, name: "onBehalfOf", type: "address" },
      { indexed: false, name: "amount", type: "uint256" },
      { indexed: false, name: "borrowRateMode", type: "uint256" },
      { indexed: false, name: "borrowRate", type: "uint256" },
      { indexed: true, name: "referral", type: "uint16" },
    ],
  },
  {
    type: "event",
    anonymous: false,
    name: "Repay",
    inputs: [
      { indexed: true, name: "reserve", type: "address" },
      { indexed: true, name: "user", type: "address" },
      { indexed: true, name: "repayer", type: "address" },
      { indexed: false, name: "amount", type: "uint256" },
    ],
  },
  {
    type: "event",
    anonymous: false,
    name: "LiquidationCall",
    inputs: [
      { indexed: true, name: "collateralAsset", type: "address" },
      { indexed: true, name: "debtAsset", type: "address" },
      { indexed: true, name: "user", type: "address" },
      { indexed: false, name: "debtToCover", type: "uint256" },
      { indexed: false, name: "liquidatedCollateralAmount", type: "uint256" },
      { indexed: false, name: "liquidator", type: "address" },
      { indexed: false, name: "receiveAToken", type: "bool" },
    ],
  },
] as const;
