// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SGSMMVault
 * @notice ERC-4626 vault for the Sortino-Gated Smart Money Mirror.
 * @dev CAPITAL PARTITION (single source of truth — reconciled with strategy spec):
 *
 *        | Tranche            | Share | Behaviour                                            |
 *        |--------------------|-------|------------------------------------------------------|
 *        | Floor              |  60%  | Always retained as the underlying asset (e.g. USDY). |
 *        | Deployable sleeve  |  30%  | Target sleeve the executor mirrors into positions.   |
 *        | Reserve buffer     |  10%  | Never deployable; redemption / incident cushion.     |
 *
 *      Floor (60%) + Reserve (10%) = 70% of NAV that must remain liquid inside
 *      the vault at all times. The remaining 30% is the *target* sleeve.
 *
 *      A hard SLEEVE_TOTAL_CAP_BPS (40%) bounds the *maximum* sleeve under
 *      transient conditions (e.g. NAV dipped after capital was already
 *      deployed). The 40% ceiling and the 70% retained-liquidity floor are
 *      intentionally distinct: 40% + 60% = 100% with no contradiction — the
 *      30% figure is the steady-state target, 40% is the never-exceed ceiling,
 *      and the 70% retained-liquidity invariant is what is actually enforced on
 *      every {enterMirror}. (The previous NatSpec implied a 110% over-allocation;
 *      that is corrected here.)
 *
 *      NAV ACCOUNTING: totalAssets() = vault-held balance + outstanding
 *      deployedSleeve. The sleeve is "borrowed" by the MirrorExecutor for
 *      off-chain execution; settlement is reconciled in {exitMirror} against an
 *      on-chain per-position ledger using the *measured* balance delta, never a
 *      caller-asserted figure.
 *
 *      SECURITY / CUSTODY NOTE (C-1, deferred): enterMirror transfers the sleeve
 *      to an `executorRecipient` (the agent EOA / sub-strategy). This custody
 *      model is pending a product decision and is tracked as an open item; the
 *      hardening in this contract bounds and audits that flow but does not
 *      remove the trust placed in the recipient.
 */
contract SGSMMVault is ERC4626, AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // Allocation policy (basis points, denominator = 10_000)
    uint16 public constant FLOOR_BPS = 6_000; // 60% — always retained as asset
    uint16 public constant SLEEVE_DEPLOYABLE_BPS = 3_000; // 30% — steady-state target sleeve
    uint16 public constant RESERVE_BPS = 1_000; // 10% — never-deployable buffer

    /// @notice Minimum fraction of NAV that must stay liquid in the vault (floor + reserve).
    uint16 public constant RETAINED_LIQUID_BPS = FLOOR_BPS + RESERVE_BPS; // 70%

    // Position sizing caps
    uint16 public constant PER_POSITION_CAP_BPS = 800; // 8%
    uint16 public constant PER_WALLET_CAP_BPS = 1_200; // 12%
    uint16 public constant SLEEVE_TOTAL_CAP_BPS = 4_000; // 40% hard ceiling (never-exceed)

    /// @dev ERC-4626 virtual-share decimals offset. A non-zero offset makes the
    ///      classic first-depositor inflation/donation attack economically
    ///      unviable by scaling the virtual shares (see OZ ERC4626 docs).
    uint8 private constant DECIMALS_OFFSET = 6;

    /// @notice Total assets currently deployed to mirror positions (outstanding).
    /// @dev INVARIANT: deployedSleeve == Σ walletExposure[w] == Σ open position principals.
    uint256 public deployedSleeve;

    /// @notice Per-wallet outstanding mirror exposure (sum of that wallet's open principals).
    mapping(address => uint256) public walletExposure;

    /// @notice Per-wallet position counter (number of distinct entries open).
    mapping(address => uint256) public walletPositionCount;

    /// @notice Monotonic position-id nonce per wallet (used to key the ledger).
    mapping(address => uint256) public walletNextPositionId;

    /// @notice Per-position recorded principal: positionPrincipal[wallet][positionId].
    /// @dev Recorded in {enterMirror}, consumed (zeroed) in {exitMirror}. A non-zero
    ///      value means the position is open. exitMirror trusts THIS, not the caller.
    mapping(address => mapping(uint256 => uint256)) public positionPrincipal;

    event MirrorEntered(
        address indexed wallet, uint256 indexed positionId, uint256 amount, uint256 newDeployedSleeve
    );
    event MirrorExited(
        address indexed wallet,
        uint256 indexed positionId,
        uint256 principal,
        uint256 realizedAssets,
        int256 pnl
    );

    error SizingCapExceeded(uint256 attempted, uint256 cap, string capName);
    error RetainedLiquidityBreached(uint256 wouldRetain, uint256 required);
    error ZeroAmount();
    error NothingToEnter();
    error NothingToExit();
    error NavIsZero();
    error ZeroSharesMinted();
    error PositionNotOpen();

    constructor(IERC20 asset_, address admin)
        ERC20(
            string.concat("SGSMM Vault Share - ", IERC20Metadata(address(asset_)).symbol()),
            string.concat("sgs", IERC20Metadata(address(asset_)).symbol())
        )
        ERC4626(asset_)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
    }

    /// @inheritdoc ERC4626
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + deployedSleeve;
    }

    /// @notice Executor pulls capital from the vault to deploy to a mirror position.
    /// @dev Reverts if any policy cap or the retained-liquidity floor would be breached.
    ///      CEI: all accounting state is written before the external asset transfer.
    ///      nonReentrant + whenNotPaused (paused halts new entries).
    /// @return positionId The ledger id for this entry; pass it back to {exitMirror}.
    function enterMirror(address wallet, uint256 amount, address executorRecipient)
        external
        whenNotPaused
        nonReentrant
        onlyRole(EXECUTOR_ROLE)
        returns (uint256 positionId)
    {
        if (amount == 0) revert ZeroAmount();

        uint256 nav = totalAssets();
        if (nav == 0) revert NavIsZero();

        // Conservative (ceil) cap math: an entry is rejected unless it fits the cap
        // even after rounding up, so rounding can never let an entry exceed a cap.
        // navBps = ceil(amount * 10_000 / nav).
        uint256 navBps = Math.mulDiv(amount, 10_000, nav, Math.Rounding.Ceil);
        if (navBps > PER_POSITION_CAP_BPS) {
            revert SizingCapExceeded(navBps, PER_POSITION_CAP_BPS, "per_position");
        }

        // Per-wallet cap (ceil).
        uint256 walletAfter = walletExposure[wallet] + amount;
        uint256 walletBps = Math.mulDiv(walletAfter, 10_000, nav, Math.Rounding.Ceil);
        if (walletBps > PER_WALLET_CAP_BPS) {
            revert SizingCapExceeded(walletBps, PER_WALLET_CAP_BPS, "per_wallet");
        }

        // Sleeve total cap (ceil) — hard 40% never-exceed ceiling.
        uint256 sleeveAfter = deployedSleeve + amount;
        uint256 sleeveBps = Math.mulDiv(sleeveAfter, 10_000, nav, Math.Rounding.Ceil);
        if (sleeveBps > SLEEVE_TOTAL_CAP_BPS) {
            revert SizingCapExceeded(sleeveBps, SLEEVE_TOTAL_CAP_BPS, "sleeve_total");
        }

        // Capital partition enforcement: after sending out `amount`, the vault must
        // still retain >= 70% of NAV (floor 60% + reserve 10%) as liquid asset.
        // require(balance - amount >= 70% * nav). Computed without underflow.
        uint256 liquidBalance = IERC20(asset()).balanceOf(address(this));
        uint256 requiredRetained = Math.mulDiv(RETAINED_LIQUID_BPS, nav, 10_000, Math.Rounding.Ceil);
        if (liquidBalance < amount || liquidBalance - amount < requiredRetained) {
            revert RetainedLiquidityBreached(
                liquidBalance < amount ? 0 : liquidBalance - amount, requiredRetained
            );
        }

        // ---- Effects (state writes) before interaction (CEI) ----
        positionId = walletNextPositionId[wallet];
        walletNextPositionId[wallet] = positionId + 1;
        positionPrincipal[wallet][positionId] = amount;
        walletExposure[wallet] = walletAfter;
        walletPositionCount[wallet] += 1;
        deployedSleeve = sleeveAfter;

        // ---- Interaction ----
        // Transfer to executor recipient (off-chain agent EOA or sub-strategy contract).
        IERC20(asset()).safeTransfer(executorRecipient, amount);

        emit MirrorEntered(wallet, positionId, amount, sleeveAfter);
    }

    /// @notice Executor returns capital to the vault after exiting a mirror position.
    /// @dev Settlement integrity:
    ///        - The principal is read from the on-chain ledger (positionPrincipal),
    ///          NOT trusted from the caller.
    ///        - Realized assets are MEASURED as the actual balance delta around the
    ///          transferFrom, so a fee-on-transfer / partial transfer cannot inflate
    ///          the credited amount.
    ///        - Accounting is reduced by the recorded principal, preserving the
    ///          invariant deployedSleeve == Σ walletExposure.
    ///      CEI: the external transferFrom happens first (it is the value being
    ///      settled and is measured), then all ledger state is finalized; the call
    ///      is nonReentrant. Redemptions/returns intentionally stay OPEN even while
    ///      paused so capital can always flow back to the vault during an incident
    ///      (pause only blocks NEW entries via {enterMirror}).
    /// @param amountReturned Amount the caller intends to return (must be pre-approved).
    /// @return realizedAssets The measured assets actually received by the vault.
    function exitMirror(address wallet, uint256 positionId, uint256 amountReturned)
        external
        nonReentrant
        onlyRole(EXECUTOR_ROLE)
        returns (uint256 realizedAssets)
    {
        uint256 principal = positionPrincipal[wallet][positionId];
        if (principal == 0) revert PositionNotOpen();

        IERC20 assetToken = IERC20(asset());

        // Measure the ACTUAL received amount via balance delta (defends against
        // fee-on-transfer tokens and a caller over-stating amountReturned).
        uint256 balBefore = assetToken.balanceOf(address(this));
        if (amountReturned > 0) {
            assetToken.safeTransferFrom(msg.sender, address(this), amountReturned);
        }
        uint256 balAfter = assetToken.balanceOf(address(this));
        realizedAssets = balAfter - balBefore;

        // ---- Effects: finalize ledger using the RECORDED principal ----
        // walletExposure[wallet] >= principal always holds by construction (it is the
        // sum of open principals), so this subtraction cannot underflow.
        positionPrincipal[wallet][positionId] = 0;
        walletExposure[wallet] -= principal;
        walletPositionCount[wallet] -= 1;
        deployedSleeve -= principal;

        int256 pnl = int256(realizedAssets) - int256(principal);
        emit MirrorExited(wallet, positionId, principal, realizedAssets, pnl);
    }

    /// @notice Pause new mirror entries (admin or pauser only).
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @dev ERC-4626 deposit/mint choke-point. Overriding {_deposit} covers BOTH
    ///      {deposit} and {mint}. Two hardenings:
    ///        1. whenNotPaused — depositor inflow halts during an incident.
    ///        2. Revert if zero shares would be minted for a non-zero deposit,
    ///           closing the first-depositor / dust rounding hole (belt-and-suspenders
    ///           alongside the non-zero {_decimalsOffset}).
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        whenNotPaused
    {
        if (assets > 0 && shares == 0) revert ZeroSharesMinted();
        super._deposit(caller, receiver, assets, shares);
    }

    /// @dev Non-zero virtual-share offset to neutralize inflation/donation attacks.
    function _decimalsOffset() internal pure override returns (uint8) {
        return DECIMALS_OFFSET;
    }

    /// @notice Required override to disambiguate AccessControl + ERC165 surfaces.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
