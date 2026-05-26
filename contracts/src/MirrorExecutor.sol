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
    function executeEnter(
        address wallet,
        uint256 amount,
        int128 sortinoMicros,
        uint32 sleevePctBps,
        uint32 reasonCode
    ) external onlyRole(AGENT_ROLE) {
        vault.enterMirror(wallet, amount, msg.sender);
        decisionLog.logDecision(
            wallet,
            DecisionLog.Action.Enter,
            sortinoMicros,
            sleevePctBps,
            vault.totalAssets(),
            reasonCode
        );
        emit AgentExecuted(wallet, DecisionLog.Action.Enter, sortinoMicros, amount, 0);
    }

    /// @notice Exit a mirror position. Agent must pre-approve vault to pull `amountReturned`.
    function executeExit(
        address wallet,
        uint256 originalAmount,
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
        vault.exitMirror(wallet, originalAmount, amountReturned);

        decisionLog.logDecision(
            wallet, action, sortinoMicros, 0, vault.totalAssets(), reasonCode
        );

        emit AgentExecuted(wallet, action, sortinoMicros, originalAmount, amountReturned);
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
        decisionLog.logDecision(
            wallet, action, sortinoMicros, 0, vault.totalAssets(), reasonCode
        );
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
