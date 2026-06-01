// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SGSMMVault} from "./SGSMMVault.sol";
import {DecisionLog} from "./DecisionLog.sol";
import {AgentIdentityNFT} from "./AgentIdentityNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title MirrorExecutor
 * @notice The on-chain enforcement layer for SGSMM policy.
 * @dev Single authorized agent EOA submits decisions. Executor:
 *      - Calls Vault.enterMirror / exitMirror (policy caps enforced in vault)
 *      - Emits decisions to DecisionLog
 *      - Optionally updates AgentIdentityNFT reputation metadata
 *
 *      The actual off-chain trading (interacting with Lendle / Agni / etc.)
 *      happens at the agent layer. Executor commits the on-chain accounting
 *      so independent observers can verify policy adherence.
 */
contract MirrorExecutor is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    SGSMMVault public immutable vault;
    DecisionLog public immutable decisionLog;
    AgentIdentityNFT public immutable identity;
    uint256 public immutable agentId;

    event AgentExecuted(
        address indexed wallet,
        DecisionLog.Action action,
        int128 sortinoMicros,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Surfaces the vault position id assigned to a fresh entry so off-chain
    ///         agents can reference it later when defunding/unwinding.
    event MirrorPositionOpened(address indexed wallet, uint256 indexed positionId, uint256 amount);

    error UnknownAction();

    constructor(
        SGSMMVault vault_,
        DecisionLog decisionLog_,
        AgentIdentityNFT identity_,
        uint256 agentId_,
        address admin,
        address agent
    ) {
        vault = vault_;
        decisionLog = decisionLog_;
        identity = identity_;
        agentId = agentId_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AGENT_ROLE, agent);
    }

    /// @notice Cycle start — advances the DecisionLog cycle counter.
    function advanceCycle() external onlyRole(AGENT_ROLE) returns (uint64) {
        return decisionLog.advanceCycle();
    }

    /// @notice Enter a mirror position for `wallet` with `amount` of vault asset.
    /// @return positionId The vault ledger id for this entry (echoed via event too).
    function executeEnter(
        address wallet,
        uint256 amount,
        int128 sortinoMicros,
        uint32 sleevePctBps,
        uint32 reasonCode
    ) external onlyRole(AGENT_ROLE) returns (uint256 positionId) {
        positionId = vault.enterMirror(wallet, amount, msg.sender);
        // navAfter is read from the vault directly inside logDecision (not forged here).
        decisionLog.logDecision(
            wallet, DecisionLog.Action.Enter, sortinoMicros, sleevePctBps, reasonCode
        );
        emit MirrorPositionOpened(wallet, positionId, amount);
        emit AgentExecuted(wallet, DecisionLog.Action.Enter, sortinoMicros, amount, 0);
    }

    /// @notice Exit a mirror position by its vault `positionId`. Agent must pre-approve
    ///         this executor's transfer; the executor then approves the vault to pull
    ///         `amountReturned`. The vault settles against its recorded principal and
    ///         the measured balance delta, so `amountReturned` here is only an upper
    ///         bound on what the vault credits.
    function executeExit(
        address wallet,
        uint256 positionId,
        uint256 amountReturned,
        DecisionLog.Action action,
        int128 sortinoMicros,
        uint32 reasonCode
    ) external onlyRole(AGENT_ROLE) {
        if (action != DecisionLog.Action.Defund && action != DecisionLog.Action.EmergencyUnwind) {
            revert UnknownAction();
        }

        IERC20 asset = IERC20(vault.asset());
        asset.safeTransferFrom(msg.sender, address(this), amountReturned);
        asset.forceApprove(address(vault), amountReturned);
        uint256 realizedAssets = vault.exitMirror(wallet, positionId, amountReturned);

        decisionLog.logDecision(wallet, action, sortinoMicros, 0, reasonCode);

        emit AgentExecuted(wallet, action, sortinoMicros, 0, realizedAssets);
    }

    /// @notice Log a HOLD or SKIP decision without modifying vault state.
    function executeNoOp(
        address wallet,
        DecisionLog.Action action,
        int128 sortinoMicros,
        uint32 reasonCode
    ) external onlyRole(AGENT_ROLE) {
        if (action != DecisionLog.Action.Hold && action != DecisionLog.Action.Skip) {
            revert UnknownAction();
        }
        decisionLog.logDecision(wallet, action, sortinoMicros, 0, reasonCode);
        emit AgentExecuted(wallet, action, sortinoMicros, 0, 0);
    }

    /// @notice Update on-chain reputation metadata on the AgentIdentityNFT.
    function updateAgentMetadata(string calldata key, bytes calldata value)
        external
        onlyRole(AGENT_ROLE)
    {
        identity.setMetadata(agentId, key, value);
    }
}
