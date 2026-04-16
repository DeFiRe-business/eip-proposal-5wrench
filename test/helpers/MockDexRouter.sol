// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC20} from "./MockERC20.sol";

/**
 * @title MockDexRouter
 * @notice A minimal DEX-like contract for testing the vault's DeFi execution paths.
 * @dev Simulates a swap: caller approves tokenIn, router pulls it, mints tokenOut to recipient.
 *      The exchange rate is fixed 1:1 for simplicity. Used to verify that:
 *        - The vault can be whitelisted as the caller, not the target
 *        - Token allowances flow correctly via approveToken()
 *        - Value-preserving swaps don't consume the hot spending budget
 *      NOT a real DEX. Do not deploy.
 */
contract MockDexRouter {
    event Swapped(address indexed user, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    /// @notice Simulates a 1:1 token swap. Caller must have approved `amountIn` of `tokenIn`.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external returns (uint256 amountOut) {
        // Pull tokenIn from caller (requires prior approval)
        MockERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);

        // 1:1 swap rate
        amountOut = amountIn;

        // Mint tokenOut to recipient
        MockERC20(tokenOut).mint(recipient, amountOut);

        emit Swapped(msg.sender, tokenIn, tokenOut, amountIn, amountOut);
    }
}
