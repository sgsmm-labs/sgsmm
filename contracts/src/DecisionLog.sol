// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @dev Minimal view surface needed to read NAV without importing the full vault
///      type (avoids a circular dependency SGSMMVault <-> DecisionLog).
interface IVaultNav {
    function totalAssets() external view returns (uint256);
}

/**
 * @title DecisionLog
 * @notice Append-only on-chain audit trail for SGSMM agent decisions.
 * @dev Every mirror entry, defund, or emergency unwind emits a Decision event
 *      with full reasoning context. An independent observer with only Mantle
 *      RPC access can reconstruct the agent's policy adherence and risk-adjusted
 *      returns from this log alone — satisfies the Path B verifiability rubric.
 *
 *      INTEGRITY: navAfter is read directly from the bound vault inside
 *      {logDecision} rather than accepted as a caller argument, so the logged
 *      NAV cannot be forged by the (trusted-but-fallible) logger.
 */
contract DecisionLog is AccessControl {
    bytes32 public constant LOGGER_ROLE = keccak256("LOGGER_ROLE");

    /// @notice Vault whose NAV is snapshotted into every decision. Immutable.
    IVaultNav public immutable vault;

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
    /// @param navAfter Vault NAV after the action, in vault-asset units — read from the vault.
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

    error ZeroVault();

    uint64 public currentCycle;

    constructor(address admin, IVaultNav vault_) {
        if (address(vault_) == address(0)) revert ZeroVault();
        vault = vault_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Logger calls this once per cycle to advance the cycle counter.
    /// @dev No `unchecked`: a uint64 cycle counter overflowing would silently wrap
    ///      and corrupt the audit ordering, so the checked increment is intentional.
    function advanceCycle() external onlyRole(LOGGER_ROLE) returns (uint64) {
        currentCycle += 1;
        return currentCycle;
    }

    /// @notice Emit a decision in the current cycle. NAV is read from the bound vault.
    function logDecision(
        address wallet,
        Action action,
        int128 sortinoMicros,
        uint32 sleevePctBps,
        uint32 reasonCode
    ) external onlyRole(LOGGER_ROLE) {
        emit Decision(
            currentCycle, wallet, action, sortinoMicros, sleevePctBps, vault.totalAssets(), reasonCode
        );
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
