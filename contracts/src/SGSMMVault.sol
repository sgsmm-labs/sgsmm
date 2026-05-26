// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title SGSMMVault
 * @notice ERC-4626 vault for the Sortino-Gated Smart Money Mirror.
 * @dev Capital partition (per docs-private/strategy-spec.md):
 *      - 60% floor (always kept as the underlying asset, e.g. USDY)
 *      - 30% deployable sleeve (executor moves to/from mirror positions)
 *      - 10% reserve buffer (never deployable)
 *
 *      The vault tracks an internal accounting of deployed sleeve capital
 *      ("borrowed" by the MirrorExecutor for off-chain execution). NAV
 *      includes both vault-held assets + outstanding deployed sleeve.
 */
contract SGSMMVault is ERC4626, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // Allocation policy (basis points, denominator = 10_000)
    uint16 public constant FLOOR_BPS = 6_000;        // 60%
    uint16 public constant SLEEVE_DEPLOYABLE_BPS = 3_000; // 30%
    uint16 public constant RESERVE_BPS = 1_000;      // 10%

    // Position sizing caps
    uint16 public constant PER_POSITION_CAP_BPS = 800;  // 8%
    uint16 public constant PER_WALLET_CAP_BPS = 1_200;  // 12%
    uint16 public constant SLEEVE_TOTAL_CAP_BPS = 4_000; // 40% (matches strategy spec)

    /// @notice Total assets currently deployed to mirror positions (outstanding).
    uint256 public deployedSleeve;

    /// @notice Per-wallet outstanding mirror exposure.
    mapping(address => uint256) public walletExposure;

    /// @notice Per-wallet position counter (number of distinct entries open).
    mapping(address => uint256) public walletPositionCount;

    event MirrorEntered(address indexed wallet, uint256 amount, uint256 newDeployedSleeve);
    event MirrorExited(address indexed wallet, uint256 amountReturned, int256 pnl);

    error SizingCapExceeded(uint256 attempted, uint256 cap, string capName);
    error VaultIsPaused();
    error NothingToExit();

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
    /// @dev Reverts if any policy cap would be exceeded.
    function enterMirror(address wallet, uint256 amount, address executorRecipient)
        external
        whenNotPaused
        onlyRole(EXECUTOR_ROLE)
    {
        if (amount == 0) revert NothingToExit();

        uint256 nav = totalAssets();
        uint256 navBps = (amount * 10_000) / nav;

        // Per-position cap
        if (navBps > PER_POSITION_CAP_BPS) {
            revert SizingCapExceeded(navBps, PER_POSITION_CAP_BPS, "per_position");
        }

        // Per-wallet cap
        uint256 walletAfter = walletExposure[wallet] + amount;
        uint256 walletBps = (walletAfter * 10_000) / nav;
        if (walletBps > PER_WALLET_CAP_BPS) {
            revert SizingCapExceeded(walletBps, PER_WALLET_CAP_BPS, "per_wallet");
        }

        // Sleeve total cap
        uint256 sleeveAfter = deployedSleeve + amount;
        uint256 sleeveBps = (sleeveAfter * 10_000) / nav;
        if (sleeveBps > SLEEVE_TOTAL_CAP_BPS) {
            revert SizingCapExceeded(sleeveBps, SLEEVE_TOTAL_CAP_BPS, "sleeve_total");
        }

        // Update accounting
        walletExposure[wallet] = walletAfter;
        walletPositionCount[wallet] += 1;
        deployedSleeve = sleeveAfter;

        // Transfer to executor recipient (off-chain agent EOA or sub-strategy contract)
        IERC20(asset()).safeTransfer(executorRecipient, amount);

        emit MirrorEntered(wallet, amount, sleeveAfter);
    }

    /// @notice Executor returns capital to the vault after exiting a mirror.
    /// @dev The amountReturned can differ from the original entry — that's the PnL.
    function exitMirror(address wallet, uint256 originalAmount, uint256 amountReturned)
        external
        onlyRole(EXECUTOR_ROLE)
    {
        if (walletExposure[wallet] < originalAmount) revert NothingToExit();
        if (walletPositionCount[wallet] == 0) revert NothingToExit();

        // Pull return amount from executor caller (must approve vault first)
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amountReturned);

        walletExposure[wallet] -= originalAmount;
        walletPositionCount[wallet] -= 1;
        deployedSleeve -= originalAmount;

        int256 pnl = int256(amountReturned) - int256(originalAmount);
        emit MirrorExited(wallet, amountReturned, pnl);
    }

    /// @notice Pause new mirror entries (admin or pauser only).
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
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
