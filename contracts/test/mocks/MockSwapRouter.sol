// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Mintable surface the router uses to materialise swap output.
interface IMintableToken {
    function mint(address to, uint256 amount) external;
}

/**
 * @title MockSwapRouter
 * @notice Uniswap-V2-style router stand-in for MirrorExecutor custody tests.
 * @dev Implements the exact {swapExactTokensForTokens} selector the executor's
 *      ISwapRouter interface targets. It PULLS `amountIn` of `path[0]` from the
 *      caller (the executor must have approved it) and delivers
 *      `amountIn * rateNum / rateDen` of `path[1]` to `to` by minting fresh
 *      output tokens (output token must be an IMintableToken, e.g. MockUSDY).
 *
 *      Crucially the router HONOURS the `to` argument the executor passes. The
 *      executor hard-codes `to = address(this)` (the custodian), so a faithful
 *      router that simply respects `to` is exactly what proves the proceeds stay
 *      in the custodian — there is no need for the mock to force the destination.
 *
 *      `rateNum/rateDen` lets a test model profit (rate > 1), loss (rate < 1), or
 *      a 1:1 swap (default). `minOut` is enforced so slippage-guard reverts can be
 *      exercised too.
 */
contract MockSwapRouter {
    using SafeERC20 for IERC20;

    uint256 public rateNum = 1;
    uint256 public rateDen = 1;

    error DeadlinePassed();
    error InsufficientOutput(uint256 out, uint256 minOut);
    error BadPath();

    /// @notice Configure the output:input ratio (output = amountIn * num / den).
    function setRate(uint256 num, uint256 den) external {
        require(den != 0, "den=0");
        rateNum = num;
        rateDen = den;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        if (block.timestamp > deadline) revert DeadlinePassed();
        if (path.length < 2) revert BadPath();

        // Pull the input from the caller (executor must have approved this router).
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);

        uint256 amountOut = (amountIn * rateNum) / rateDen;
        if (amountOut < amountOutMin) revert InsufficientOutput(amountOut, amountOutMin);

        // Deliver output to the caller-chosen `to` (executor pins this to itself).
        IMintableToken(path[path.length - 1]).mint(to, amountOut);

        amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountOut;
    }
}
