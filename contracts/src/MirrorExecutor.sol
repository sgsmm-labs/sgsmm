// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SGSMMVault} from "./SGSMMVault.sol";
import {DecisionLog} from "./DecisionLog.sol";
import {AgentIdentityNFT} from "./AgentIdentityNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Minimal swap-router surface (Uniswap-V2-style) used to deploy the sleeve
///      into a venue. Only routers explicitly whitelisted by governance may be
///      called, and only with whitelisted tokens. Output tokens land back in
///      THIS contract (the custodian) — never an EOA.
interface ISwapRouter {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}

/**
 * @title MirrorExecutor
 * @notice On-chain enforcement layer AND sole custodian of the deployed sleeve.
 *
 * @dev CUSTODY MODEL (C-1 RESOLVED — user funds are NEVER held by an EOA):
 *
 *      This CONTRACT is the vault's `custodian`. {SGSMMVault.enterMirror} sends
 *      the deployable sleeve here (the vault has no caller-supplied recipient).
 *      From here the sleeve has EXACTLY two fund-moving exits:
 *
 *        (a) {deployToVenue} — AGENT_ROLE swaps the sleeve through a router that
 *            is in `routerWhitelist`, with tokenIn/tokenOut both in
 *            `tokenWhitelist`. The swap output (`to`) is hard-coded to
 *            address(this): proceeds stay IN this custodian. The agent picks the
 *            amount and minOut but CANNOT choose the destination.
 *
 *        (b) {executeExit} — returns funds to the vault. This contract approves
 *            the vault and the vault PULLS via transferFrom. There is no
 *            transferFrom from an EOA and no transfer to a caller-supplied
 *            address.
 *
 *      HARD CUSTODY INVARIANT (enforced + audited):
 *        NO function in this executor transfers the asset (or any whitelisted
 *        token) to `msg.sender` or to a caller-supplied address. Fund flows are
 *        exactly:
 *            vault -> custodian(this)                  [SGSMMVault.enterMirror]
 *            custodian -> whitelisted router -> custodian  [deployToVenue]
 *            custodian -> vault                        [executeExit, vault pulls]
 *        A compromised AGENT_ROLE key can ONLY swap within whitelisted venues
 *        (output returning here) or return funds to the vault. It CANNOT extract
 *        funds to an address it controls.
 *
 *      Governance (DEFAULT_ADMIN_ROLE, the TimelockController on mainnet) owns
 *      the router/token whitelists and role administration. AGENT_ROLE is the
 *      hot operational key and is deliberately limited to the two exits above
 *      plus non-custodial bookkeeping (DecisionLog / AgentIdentityNFT writes).
 *
 *      The `agentId` is the ERC-8004 agent identity reference. On mainnet this is
 *      the Mantle-ISSUED agent id (see AgentIdentityNFT for the dev stand-in note).
 */
contract MirrorExecutor is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    SGSMMVault public immutable vault;
    DecisionLog public immutable decisionLog;
    AgentIdentityNFT public immutable identity;
    uint256 public agentId;

    /// @notice Routers AGENT_ROLE may swap through. Governance-controlled.
    mapping(address => bool) public routerWhitelist;

    /// @notice Tokens that may appear as tokenIn/tokenOut of a venue swap. Governance-controlled.
    mapping(address => bool) public tokenWhitelist;

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

    /// @notice Emitted when the sleeve is swapped through a whitelisted venue.
    /// @dev `to` is always address(this); proceeds stay in the custodian.
    event VenueDeployed(
        address indexed router,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    event RouterWhitelistUpdated(address indexed router, bool allowed);
    event TokenWhitelistUpdated(address indexed token, bool allowed);
    event AgentIdUpdated(uint256 previousAgentId, uint256 newAgentId);

    error UnknownAction();
    error RouterNotWhitelisted(address router);
    error TokenNotWhitelisted(address token);
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientSleeveBalance(uint256 have, uint256 want);

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

    // ---------------------------------------------------------------------
    // Governance: whitelists + agent identity (DEFAULT_ADMIN_ROLE only)
    // ---------------------------------------------------------------------

    /// @notice Governance allow/deny a swap router for {deployToVenue}.
    function setRouterWhitelist(address router, bool allowed)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (router == address(0)) revert ZeroAddress();
        routerWhitelist[router] = allowed;
        emit RouterWhitelistUpdated(router, allowed);
    }

    /// @notice Governance allow/deny a token as swap input/output for {deployToVenue}.
    function setTokenWhitelist(address token, bool allowed)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0)) revert ZeroAddress();
        tokenWhitelist[token] = allowed;
        emit TokenWhitelistUpdated(token, allowed);
    }

    /// @notice Governance points this executor at the canonical (Mantle-ISSUED on
    ///         mainnet) ERC-8004 agent id. See AgentIdentityNFT for the dev stand-in.
    function setAgentId(uint256 newAgentId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit AgentIdUpdated(agentId, newAgentId);
        agentId = newAgentId;
    }

    // ---------------------------------------------------------------------
    // Cycle / decision bookkeeping (non-custodial)
    // ---------------------------------------------------------------------

    /// @notice Cycle start — advances the DecisionLog cycle counter.
    function advanceCycle() external onlyRole(AGENT_ROLE) returns (uint64) {
        return decisionLog.advanceCycle();
    }

    /// @notice Enter a mirror position for `wallet` with `amount` of vault asset.
    /// @dev The vault sends the sleeve to THIS contract (the custodian) — there is
    ///      no recipient argument and no EOA in the fund path. The agent later
    ///      deploys the held sleeve via {deployToVenue} or returns it via
    ///      {executeExit}.
    /// @return positionId The vault ledger id for this entry (echoed via event too).
    function executeEnter(
        address wallet,
        uint256 amount,
        int128 sortinoMicros,
        uint32 sleevePctBps,
        uint32 reasonCode
    ) external onlyRole(AGENT_ROLE) returns (uint256 positionId) {
        positionId = vault.enterMirror(wallet, amount);
        // navAfter is read from the vault directly inside logDecision (not forged here).
        decisionLog.logDecision(
            wallet, DecisionLog.Action.Enter, sortinoMicros, sleevePctBps, reasonCode
        );
        emit MirrorPositionOpened(wallet, positionId, amount);
        emit AgentExecuted(wallet, DecisionLog.Action.Enter, sortinoMicros, amount, 0);
    }

    /// @notice Swap part of the held sleeve through a whitelisted venue; proceeds
    ///         stay in this custodian.
    /// @dev CUSTODY-SAFE DEPLOYMENT. AGENT_ROLE only. Reverts unless `router` is in
    ///      `routerWhitelist` and both `tokenIn`/`tokenOut` are in `tokenWhitelist`.
    ///      The swap recipient is hard-coded to address(this): the agent can choose
    ///      the size and slippage bound but NOT the destination, so it cannot route
    ///      proceeds to an address it controls. nonReentrant; CEI-friendly
    ///      (forceApprove reset to 0 after the swap).
    /// @param router Whitelisted swap router.
    /// @param tokenIn Whitelisted input token currently held here.
    /// @param tokenOut Whitelisted output token (proceeds remain here).
    /// @param amountIn Exact input amount to swap.
    /// @param minOut Minimum acceptable output (slippage guard).
    /// @return amountOut Output received by this custodian.
    function deployToVenue(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) external onlyRole(AGENT_ROLE) nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();
        if (!routerWhitelist[router]) revert RouterNotWhitelisted(router);
        if (!tokenWhitelist[tokenIn]) revert TokenNotWhitelisted(tokenIn);
        if (!tokenWhitelist[tokenOut]) revert TokenNotWhitelisted(tokenOut);

        IERC20 inToken = IERC20(tokenIn);
        IERC20 outToken = IERC20(tokenOut);

        uint256 inBal = inToken.balanceOf(address(this));
        if (inBal < amountIn) revert InsufficientSleeveBalance(inBal, amountIn);

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        // Approve exactly amountIn to the router, swap with proceeds returning HERE,
        // then reset the allowance to 0 (defence-in-depth against leftover approvals).
        uint256 outBefore = outToken.balanceOf(address(this));
        inToken.forceApprove(router, amountIn);
        ISwapRouter(router).swapExactTokensForTokens(
            amountIn, minOut, path, address(this), block.timestamp
        );
        inToken.forceApprove(router, 0);

        // Measure realized output via balance delta (defends against fee-on-transfer
        // / non-standard return values rather than trusting the router's return).
        amountOut = outToken.balanceOf(address(this)) - outBefore;

        emit VenueDeployed(router, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @notice Exit a mirror position by its vault `positionId`, returning funds to
    ///         the vault.
    /// @dev CUSTODY-SAFE RETURN. This contract holds the asset; it approves the vault
    ///      and the vault PULLS via transferFrom inside {exitMirror}. There is NO
    ///      transferFrom from an EOA and NO transfer to a caller-supplied address.
    ///      The vault settles against its recorded principal and the measured balance
    ///      delta, so `amountReturned` is only an upper bound on what the vault
    ///      credits. nonReentrant; the approval is reset to 0 afterward.
    /// @param amountReturned Amount of asset to make available to the vault to pull
    ///        (must be <= this contract's asset balance).
    function executeExit(
        address wallet,
        uint256 positionId,
        uint256 amountReturned,
        DecisionLog.Action action,
        int128 sortinoMicros,
        uint32 reasonCode
    ) external onlyRole(AGENT_ROLE) nonReentrant {
        if (action != DecisionLog.Action.Defund && action != DecisionLog.Action.EmergencyUnwind) {
            revert UnknownAction();
        }

        IERC20 asset = IERC20(vault.asset());
        uint256 bal = asset.balanceOf(address(this));
        if (bal < amountReturned) revert InsufficientSleeveBalance(bal, amountReturned);

        // Custodian approves the vault to PULL the returned funds. No EOA is involved.
        asset.forceApprove(address(vault), amountReturned);
        uint256 realizedAssets = vault.exitMirror(wallet, positionId, amountReturned);
        asset.forceApprove(address(vault), 0);

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
