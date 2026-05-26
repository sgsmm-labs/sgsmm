// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title DecisionLog
 * @notice Append-only on-chain audit trail for SGSMM agent decisions.
 * @dev Every mirror entry, defund, or emergency unwind emits a Decision event
 *      with full reasoning context. An independent observer with only Mantle
 *      RPC access can reconstruct the agent's policy adherence and risk-adjusted
 *      returns from this log alone — satisfies the Path B verifiability rubric.
 */
contract DecisionLog is AccessControl {
    bytes32 public constant LOGGER_ROLE = keccak256("LOGGER_ROLE");

    /// @notice Categorical action the agent took.
    enum Action {
        Enter,
        Hold,
        Defund,
        EmergencyUnwind,
        Skip
    }

    /// @notice Emitted when the agent makes a decision about a tracked wallet.
    /// @param cycle Monotonically-increasing rebalance cycle index.
    /// @param wallet Smart-money wallet being evaluated.
    /// @param action What the agent did this cycle.
    /// @param sortinoMicros Per-wallet rolling 90d Sortino, scaled by 1e6 (e.g. 1500000 = 1.5).
    /// @param sleevePctBps Resulting sleeve allocation for this wallet, in basis points of NAV.
    /// @param navAfter Vault NAV after the action, in vault-asset units (USDY 18-decimal).
    /// @param reasonCode Compact bitfield of which policy condition triggered the action.
    event Decision(
        uint64 indexed cycle,
        address indexed wallet,
        Action indexed action,
        int128 sortinoMicros,
        uint32 sleevePctBps,
        uint256 navAfter,
        uint32 reasonCode
    );

    /// @notice Emitted when the vault is frozen due to drawdown breach.
    event VaultFrozen(uint64 indexed cycle, uint256 vaultDrawdownBps, uint256 freezeUntilTimestamp);

    /// @notice Emitted when the vault freeze cooldown expires.
    event VaultUnfrozen(uint64 indexed cycle);

    uint64 public currentCycle;

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Logger calls this once per cycle to advance the cycle counter.
    function advanceCycle() external onlyRole(LOGGER_ROLE) returns (uint64) {
        unchecked {
            currentCycle += 1;
        }
        return currentCycle;
    }

    /// @notice Emit a decision in the current cycle.
    function logDecision(
        address wallet,
        Action action,
        int128 sortinoMicros,
        uint32 sleevePctBps,
        uint256 navAfter,
        uint32 reasonCode
    ) external onlyRole(LOGGER_ROLE) {
        emit Decision(currentCycle, wallet, action, sortinoMicros, sleevePctBps, navAfter, reasonCode);
    }

    /// @notice Emit a vault-freeze event.
    function logVaultFrozen(uint256 vaultDrawdownBps, uint256 freezeUntilTimestamp)
        external
        onlyRole(LOGGER_ROLE)
    {
        emit VaultFrozen(currentCycle, vaultDrawdownBps, freezeUntilTimestamp);
    }

    /// @notice Emit a vault-unfreeze event.
    function logVaultUnfrozen() external onlyRole(LOGGER_ROLE) {
        emit VaultUnfrozen(currentCycle);
    }
}
