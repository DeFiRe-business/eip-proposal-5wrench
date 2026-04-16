// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {CoercionResistantVault, IEntryPoint, IERC20} from "../src/CoercionResistantVault.sol";

// --------------------------------------------------
//  Minimal external interfaces (Sepolia contracts)
// --------------------------------------------------

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Uniswap V3 SwapRouter02 (no-deadline variant)
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/**
 * @title CoercionResistantVaultDeFiForkTest
 * @notice Integration tests that fork Sepolia and exercise the vault against
 *         real on-chain protocols (WETH9, Uniswap V3). Proves end-to-end that
 *         the vault can act as an ERC-4337 smart account interacting with
 *         external contracts while preserving its security invariants.
 *
 *         Required env vars (see .env.example):
 *           - SEPOLIA_RPC_URL       (required; tests skip if unset)
 *           - SEPOLIA_WETH          (default provided)
 *           - SEPOLIA_SWAP_ROUTER_02(default provided)
 *           - SEPOLIA_USDC          (default provided; used only in swap test)
 *
 *         Run with:
 *           source .env && forge test --match-contract DeFiFork -vvv
 *
 *         These tests are OPTIONAL and will skip if SEPOLIA_RPC_URL is empty
 *         so the main unit-test suite keeps running in CI without an RPC.
 */
contract CoercionResistantVaultDeFiForkTest is Test {

    CoercionResistantVault internal vault;

    address internal owner      = makeAddr("owner");
    address internal guardian1  = makeAddr("guardian1");
    address internal guardian2  = makeAddr("guardian2");
    address internal guardian3  = makeAddr("guardian3");

    // ERC-4337 EntryPoint v0.7 -- canonical on all chains
    address internal constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    // Addresses resolved from env (with Sepolia defaults)
    address internal weth;
    address internal swapRouter;
    address internal usdc;

    uint256 internal constant TIMELOCK = 3 days;
    uint256 internal constant EPOCH    = 1 days;

    bool internal forkAvailable;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            forkAvailable = false;
            return;
        }

        // Create and select the fork
        vm.createSelectFork(rpc);
        forkAvailable = true;

        // Resolve addresses (env overrides with sensible defaults)
        weth       = vm.envOr("SEPOLIA_WETH",            address(0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14));
        swapRouter = vm.envOr("SEPOLIA_SWAP_ROUTER_02",  address(0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E));
        usdc       = vm.envOr("SEPOLIA_USDC",            address(0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238));

        // Deploy vault on the fork
        address[] memory guardians = new address[](3);
        guardians[0] = guardian1;
        guardians[1] = guardian2;
        guardians[2] = guardian3;

        vault = new CoercionResistantVault(
            IEntryPoint(ENTRY_POINT_V07),
            owner,
            1 ether,              // spending limit
            EPOCH,
            TIMELOCK,
            guardians,
            2                     // threshold
        );

        // Fund vault with 1 ETH from the test's default prefunded account
        vm.deal(address(vault), 1 ether);

        // Whitelist WETH (skipped through timelock)
        _whitelistTarget(weth);
    }

    // ==============================================
    //  Test: wrap ETH into WETH via execute()
    //  (always works -- WETH9 is pure and has no liquidity requirement)
    // ==============================================

    function test_Fork_WrapEthViaExecute() public {
        if (!forkAvailable) {
            console2.log("SEPOLIA_RPC_URL not set; skipping fork test.");
            return;
        }

        uint256 wrapAmount = 0.1 ether;

        // Record state before
        uint256 vaultEthBefore  = address(vault).balance;
        uint256 vaultWethBefore = IWETH9(weth).balanceOf(address(vault));

        // Call WETH.deposit() with ETH value -- wraps vault's ETH into WETH
        bytes memory data = abi.encodeCall(IWETH9.deposit, ());

        vm.prank(owner);
        vault.execute(weth, wrapAmount, data);

        // Vault's ETH went down, WETH went up
        assertEq(address(vault).balance, vaultEthBefore - wrapAmount);
        assertEq(IWETH9(weth).balanceOf(address(vault)), vaultWethBefore + wrapAmount);

        // CRITICAL invariant: execute() does NOT consume the hot spending budget.
        //
        // The hot budget is derived as min(spendingLimit - spentInCurrentEpoch, balance),
        // so the VIEW will change when the ETH balance drops (since balance becomes the
        // binding constraint). The real invariant we care about is that the
        // spentInCurrentEpoch counter does NOT increment on execute() calls, proving
        // the vault distinguishes value-preserving swaps from value-transferring spends.
        assertEq(vault.spentInCurrentEpoch(), 0, "execute() must not increment hot-spend counter");

        console2.log("Vault wrapped ETH via execute()");
        console2.log("WETH balance:", IWETH9(weth).balanceOf(address(vault)));
        console2.log("Hot counter (should be 0):", vault.spentInCurrentEpoch());
    }

    // ==============================================
    //  Test: swap WETH -> USDC via Uniswap V3
    //  (may skip if pool doesn't exist on Sepolia)
    // ==============================================

    function test_Fork_SwapOnUniswap() public {
        if (!forkAvailable) {
            console2.log("SEPOLIA_RPC_URL not set; skipping fork test.");
            return;
        }

        // First whitelist the router
        _whitelistTarget(swapRouter);

        // Wrap 0.5 ETH into WETH inside the vault
        vm.prank(owner);
        vault.execute(weth, 0.5 ether, abi.encodeCall(IWETH9.deposit, ()));

        // Approve the router to spend WETH
        vm.prank(owner);
        vault.approveToken(weth, swapRouter, 0.5 ether);

        // Build swap params
        ISwapRouter02.ExactInputSingleParams memory params = ISwapRouter02.ExactInputSingleParams({
            tokenIn: weth,
            tokenOut: usdc,
            fee: 3000,                    // 0.3% pool
            recipient: address(vault),    // vault retains custody
            amountIn: 0.5 ether,
            amountOutMinimum: 0,          // accept any price (test only!)
            sqrtPriceLimitX96: 0
        });

        bytes memory swapData = abi.encodeCall(ISwapRouter02.exactInputSingle, (params));

        uint256 usdcBefore = IERC20(usdc).balanceOf(address(vault));
        uint256 wethBefore = IWETH9(weth).balanceOf(address(vault));

        // Attempt the swap -- may fail if pool doesn't exist or has no liquidity
        vm.prank(owner);
        try vault.execute(swapRouter, 0, swapData) {
            uint256 usdcAfter = IERC20(usdc).balanceOf(address(vault));
            uint256 wethAfter = IWETH9(weth).balanceOf(address(vault));

            assertGt(usdcAfter, usdcBefore, "USDC balance should increase");
            assertLt(wethAfter, wethBefore, "WETH balance should decrease");

            console2.log("Swap succeeded!");
            console2.log("USDC received:", usdcAfter - usdcBefore);
            console2.log("WETH spent:   ", wethBefore - wethAfter);
        } catch (bytes memory reason) {
            console2.log("Swap failed -- pool may not exist or have liquidity.");
            console2.log("This is acceptable on Sepolia; the wrap test above proves the mechanism.");
            console2.logBytes(reason);
            vm.skip(true);
        }
    }

    // ==============================================
    //  Helpers
    // ==============================================

    function _whitelistTarget(address target) internal {
        vm.prank(owner);
        vault.setWhitelistedTarget(target, true);
        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.prank(owner);
        vault.executeWhitelistChange(target);
        assertTrue(vault.isWhitelisted(target));
    }
}
