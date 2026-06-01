// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SGSMMVault} from "../../src/SGSMMVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MockCustodian
 * @notice Minimal contract-custodian stand-in for SGSMMVault unit tests.
 * @dev Mirrors the dual role the real MirrorExecutor plays at the vault boundary:
 *      it is BOTH the EXECUTOR_ROLE caller AND the `custodian` contract that
 *      receives the sleeve. This lets the vault's enter/exit accounting be tested
 *      in isolation under the new custody model (sleeve -> contract; exit pulled
 *      from the contract) without wiring the full executor / decision-log graph.
 *
 *      - {enter}  calls {SGSMMVault.enterMirror}; because this contract is the
 *                 configured custodian, the sleeve is transferred straight back
 *                 here (msg.sender == custodian).
 *      - {exit}   approves the vault and calls {SGSMMVault.exitMirror}; the vault
 *                 PULLS via transferFrom from this contract (the custodian), never
 *                 from an EOA. Approval is reset to 0 afterward.
 *
 *      It has CODE (so it satisfies {setCustodian}'s contract-only requirement)
 *      and is deliberately NOT an EOA — that distinction is the whole point of the
 *      C-1 custody fix.
 */
contract MockCustodian {
    using SafeERC20 for IERC20;

    SGSMMVault public immutable vault;
    IERC20 public immutable asset;

    constructor(SGSMMVault vault_) {
        vault = vault_;
        asset = IERC20(vault_.asset());
    }

    /// @notice Open a mirror position; the sleeve lands on THIS contract.
    function enter(address wallet, uint256 amount) external returns (uint256 positionId) {
        positionId = vault.enterMirror(wallet, amount);
    }

    /// @notice Return funds to the vault; the vault pulls `amountReturned` from here.
    function exit(address wallet, uint256 positionId, uint256 amountReturned)
        external
        returns (uint256 realizedAssets)
    {
        asset.forceApprove(address(vault), amountReturned);
        realizedAssets = vault.exitMirror(wallet, positionId, amountReturned);
        asset.forceApprove(address(vault), 0);
    }
}
