---
eip: TBD
title: Coercion-Resistant Vault Standard
description: A smart contract wallet standard with spending limits, timelocks, and multisig to protect against physical coercion attacks
author: cmayorga (@cmayorga)
discussions-to: https://ethereum-magicians.org/t/erc-coercion-resistant-vault-spending-limits-timelock-multisig-against-5-wrench-attacks/28130
status: Draft
type: Standards Track
category: ERC
created: 2026-04-01
requires: 20, 165, 4337
---

<!--
  NOTE: The EIP number (currently "TBD") will be assigned by an EIP editor
  when this proposal is submitted as a Pull Request to the ethereum/EIPs
  repository.
  
  Pre-proposal discussion and development:
  https://github.com/DeFiRe-business/eip-proposal-5wrench
-->

## Abstract

This ERC defines a standard interface for coercion-resistant vault contracts that partition
a user's balance into two tiers: a "hot" balance available for immediate spending up to a
configurable limit, and a "cold" vault requiring either a timelock delay or multisig approval
to unlock. The standard supports both native ETH and ERC-20 tokens, with independent
spending limits per asset. The design mirrors the delayed-opening safes used by banks and
cash-in-transit companies, where even employees with physical access cannot immediately
access the full contents, rendering physical coercion attacks economically unviable.

## Motivation

Physical attacks against cryptocurrency holders—commonly known as "$5 wrench attacks"—have
risen dramatically. According to publicly maintained databases of known physical attacks
against crypto holders, reported incidents increased by 169% in 2025, with over 70 confirmed
cases worldwide resulting in over $40 million stolen.

Unlike traditional financial systems where banks impose withdrawal limits, wire transfer
delays, and fraud departments that can reverse transactions, self-custodial cryptocurrency
wallets grant immediate, irreversible access to the entire balance to anyone who controls
the private key. This creates a uniquely dangerous situation: attackers can coerce a victim
into transferring their entire net worth in minutes, with no possibility of reversal.

Current mitigation strategies have significant limitations:

- **Decoy/duress wallets**: Rely on the attacker not knowing about hidden funds. Attackers
  who research their targets (increasingly common) may not be satisfied with a small decoy
  balance and may escalate violence.
- **Pure multisig**: Effective but introduces friction for everyday spending and requires
  always-available cosigners.
- **Pure timelock**: Prevents all immediate spending, making the wallet impractical for
  daily use.

This ERC proposes a standard that combines the best of all approaches: immediate access to
a limited "hot" balance for daily spending, with the bulk of funds locked behind timelocks
and/or multisig requirements. The key insight is that even under physical coercion, the
victim can truthfully state: "I can only send you X amount right now. The rest is locked
and I physically cannot access it faster."

This approach:

1. **Removes the incentive** for physical attacks by limiting the immediately extractable
   value.
2. **Provides verifiable constraints**: The victim is not lying or hiding funds—the
   constraint is verifiable on-chain. Unlike duress wallets, there is no theater involved.
3. **Allows cancellation**: Pending withdrawals from the cold vault can be cancelled during
   the timelock period, giving the victim time to act after the attacker leaves.
4. **Maintains usability**: Daily spending from the hot balance works without friction.

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD",
"SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document
are to be interpreted as described in RFC 2119 and RFC 8174.

### Definitions

- **Owner**: The primary key holder of the vault, capable of spending from the hot balance
  and initiating cold vault withdrawals.
- **Guardian**: A cosigner in the multisig scheme who can approve cold vault withdrawals
  or cancel pending withdrawals.
- **Hot balance**: The portion of funds available for immediate transfer by the owner,
  subject to a rate limit. Tracked independently for ETH and each configured ERC-20 token.
- **Cold vault**: The portion of funds requiring a timelock delay or multisig approval
  before transfer.
- **Spending limit**: The maximum amount the owner can transfer from the hot balance within
  a configurable time window (epoch). Each asset (ETH and each ERC-20 token) has its own
  independent spending limit and epoch duration.
- **Timelock period**: The minimum delay between initiating a cold vault withdrawal and
  the funds becoming transferable. Shared across all assets.
- **Withdrawal request**: A pending transfer from the cold vault, subject to the timelock
  period and cancellable by the owner or any guardian. Each request specifies which asset
  (ETH or token) is being withdrawn.
- **Pause state**: A temporary state invokable by any single guardian that blocks all
  value-moving operations (hot spends, DeFi execution, new withdrawal requests) for a
  bounded duration, allowing response to suspicious activity.

### Interface — Core (ETH)

Every compliant contract MUST implement the following interface for native ETH:

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

interface ICoercionResistantVault {

    // ──────────────────────────────────────────────
    //  Events — ETH
    // ──────────────────────────────────────────────

    /// @notice Emitted when ETH is deposited into the vault.
    event Deposited(address indexed sender, uint256 amount);

    /// @notice Emitted when the owner spends ETH from the hot balance.
    event HotSpend(address indexed to, uint256 amount);

    /// @notice Emitted when the ETH spending limit configuration changes.
    event SpendingLimitChanged(uint256 newLimit, uint256 newEpochDuration);

    // ──────────────────────────────────────────────
    //  Events — Shared (ETH + ERC-20)
    // ──────────────────────────────────────────────

    /// @notice Emitted when a cold vault withdrawal is requested.
    /// @param token The asset address. address(0) = native ETH.
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed token,
        address indexed to,
        uint256 amount,
        uint256 unlockTime
    );

    /// @notice Emitted when a pending withdrawal is executed after timelock.
    event WithdrawalExecuted(uint256 indexed requestId);

    /// @notice Emitted when a pending withdrawal is cancelled.
    event WithdrawalCancelled(uint256 indexed requestId, address cancelledBy);

    /// @notice Emitted when a withdrawal is approved via multisig (bypassing timelock).
    event WithdrawalApprovedByMultisig(uint256 indexed requestId);

    /// @notice Emitted when the timelock duration changes.
    event TimelockChanged(uint256 newDuration);

    /// @notice Emitted when a guardian is added or removed.
    event GuardianChanged(address indexed guardian, bool added);

    /// @notice Emitted when the vault is paused by a guardian.
    event VaultPaused(address indexed by, uint256 until);

    /// @notice Emitted when the vault is explicitly unpaused (before auto-expiry).
    event VaultUnpaused(address indexed by);

    // ──────────────────────────────────────────────
    //  Views — ETH
    // ──────────────────────────────────────────────

    /// @notice Returns the total ETH balance held by the vault (hot + cold).
    function totalBalance() external view returns (uint256);

    /// @notice Returns the maximum ETH the owner can spend immediately.
    function hotBalance() external view returns (uint256);

    /// @notice Returns the ETH amount locked in the cold vault.
    function coldBalance() external view returns (uint256);

    /// @notice Returns the ETH spending limit per epoch.
    function spendingLimit() external view returns (uint256);

    /// @notice Returns the ETH epoch duration in seconds.
    function epochDuration() external view returns (uint256);

    /// @notice Returns the ETH amount already spent in the current epoch.
    function spentInCurrentEpoch() external view returns (uint256);

    /// @notice Returns the remaining ETH spendable in the current epoch.
    function remainingHotBudget() external view returns (uint256);

    // ──────────────────────────────────────────────
    //  Views — Shared
    // ──────────────────────────────────────────────

    /// @notice Returns the timelock duration in seconds.
    function timelockDuration() external view returns (uint256);

    /// @notice Returns the required number of multisig approvals for instant withdrawal.
    function multisigThreshold() external view returns (uint256);

    /// @notice Returns true if the address is a registered guardian.
    function isGuardian(address account) external view returns (bool);

    /// @notice Returns the timestamp when the current pause expires (0 if not paused).
    function pausedUntil() external view returns (uint256);

    /// @notice Returns true if the vault is currently paused.
    function isPaused() external view returns (bool);

    /// @notice Returns the number of currently pending (unresolved) withdrawal requests.
    function pendingWithdrawalCount() external view returns (uint256);

    /// @notice Returns details of a pending withdrawal request.
    /// @return token The asset address (address(0) for ETH).
    function getWithdrawalRequest(uint256 requestId)
        external
        view
        returns (
            address token,
            address to,
            uint256 amount,
            uint256 unlockTime,
            bool executed,
            bool cancelled,
            uint256 approvalCount
        );

    // ──────────────────────────────────────────────
    //  Hot balance operations — ETH (owner only)
    // ──────────────────────────────────────────────

    /// @notice Transfer ETH from the hot balance, subject to spending limit.
    /// @dev MUST revert if amount exceeds remainingHotBudget().
    ///      MUST revert if the vault is paused.
    function hotSpend(address payable to, uint256 amount) external;

    // ──────────────────────────────────────────────
    //  Cold vault operations — ETH
    // ──────────────────────────────────────────────

    /// @notice Request an ETH withdrawal from the cold vault, starting the timelock.
    /// @dev MUST revert if amount exceeds coldBalance(). Only callable by owner.
    ///      MUST revert if pendingWithdrawalCount() is at MAX_PENDING_WITHDRAWALS.
    ///      MUST revert if the vault is paused.
    /// @return requestId The ID of the created withdrawal request.
    function requestWithdrawal(address payable to, uint256 amount)
        external
        returns (uint256 requestId);

    // ──────────────────────────────────────────────
    //  Cold vault operations — Shared (ETH + ERC-20)
    // ──────────────────────────────────────────────

    /// @notice Execute a pending withdrawal (ETH or token) after the timelock.
    /// @dev MUST revert if the timelock has not expired or if cancelled.
    ///      Works for both ETH and token withdrawals—the asset type is stored
    ///      in the withdrawal request.
    function executeWithdrawal(uint256 requestId) external;

    /// @notice Cancel a pending withdrawal. Callable by the owner or any guardian.
    /// @dev MUST remain callable even while the vault is paused (safety action).
    function cancelWithdrawal(uint256 requestId) external;

    /// @notice Approve a pending withdrawal via multisig, bypassing the timelock.
    /// @dev Only callable by guardians. When approvalCount >= multisigThreshold,
    ///      the withdrawal becomes immediately executable.
    function approveWithdrawal(uint256 requestId) external;

    // ──────────────────────────────────────────────
    //  Emergency pause (guardian panic button)
    // ──────────────────────────────────────────────

    /// @notice Pause the vault, blocking value-moving operations temporarily.
    /// @dev Callable by any single guardian. The pause auto-expires after
    ///      MAX_PAUSE_DURATION (RECOMMENDED: 24 hours). Multisig can extend
    ///      the pause beyond auto-expiry. The owner can lift the pause with
    ///      multisig approval from other guardians.
    function pause() external;

    /// @notice Unpause the vault before auto-expiry.
    /// @dev Requires multisig approval (>= multisigThreshold guardians must sign).
    ///      Alternatively, the owner MAY unpause with explicit guardian approval
    ///      tracked off-chain via multisig signatures.
    function unpause() external;

    // ──────────────────────────────────────────────
    //  Configuration (owner only, subject to timelock)
    // ──────────────────────────────────────────────

    /// @notice Update the ETH hot balance spending limit.
    /// @dev Limit increases SHOULD be subject to a timelock delay.
    ///      Epoch duration decreases SHOULD also be subject to a timelock delay,
    ///      as they effectively increase the spending rate.
    ///      Limit decreases and epoch duration increases MAY take effect immediately.
    function setSpendingLimit(uint256 newLimit, uint256 newEpochDuration) external;

    /// @notice Update the timelock duration for cold vault withdrawals.
    /// @dev Shared across ETH and all tokens.
    ///      Decreases SHOULD be subject to the current timelock delay.
    ///      Increases MAY take effect immediately.
    function setTimelockDuration(uint256 newDuration) external;

    /// @notice Add or remove a guardian.
    /// @dev Changes SHOULD be subject to a timelock delay.
    ///      Removal MUST revert if it would leave guardianList.length < multisigThreshold.
    function setGuardian(address guardian, bool active) external;

    /// @notice Set the number of guardian approvals required for instant withdrawal.
    function setMultisigThreshold(uint256 threshold) external;
}
```

### Interface — ERC-20 Token Extension

Compliant contracts that support ERC-20 tokens MUST additionally implement the following
interface:

```solidity
interface ICoercionResistantVaultTokens {

    // ──────────────────────────────────────────────
    //  Events — ERC-20
    // ──────────────────────────────────────────────

    /// @notice Emitted when ERC-20 tokens are deposited into the vault.
    event TokenDeposited(address indexed token, address indexed sender, uint256 amount);

    /// @notice Emitted when the owner spends tokens from the hot balance.
    event TokenHotSpend(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when a token spending limit configuration changes.
    event TokenSpendingLimitChanged(
        address indexed token,
        uint256 newLimit,
        uint256 newEpochDuration
    );

    // ──────────────────────────────────────────────
    //  Views — ERC-20
    // ──────────────────────────────────────────────

    /// @notice Returns the total token balance held by the vault.
    function totalTokenBalance(address token) external view returns (uint256);

    /// @notice Returns the remaining hot budget for a specific token.
    function remainingTokenHotBudget(address token) external view returns (uint256);

    /// @notice Returns the hot (immediately spendable) balance for a token.
    function tokenHotBalance(address token) external view returns (uint256);

    /// @notice Returns the cold (locked) balance for a token.
    function tokenColdBalance(address token) external view returns (uint256);

    /// @notice Returns the spending limit and epoch duration for a token.
    function tokenSpendingLimit(address token)
        external
        view
        returns (uint256 limit, uint256 epoch);

    /// @notice Returns the amount already spent in the current epoch for a token.
    function tokenSpentInCurrentEpoch(address token) external view returns (uint256);

    // ──────────────────────────────────────────────
    //  Deposit — ERC-20
    // ──────────────────────────────────────────────

    /// @notice Deposit ERC-20 tokens into the vault.
    /// @dev Caller must have approved this contract to spend `amount` of `token`.
    function depositToken(address token, uint256 amount) external;

    // ──────────────────────────────────────────────
    //  Hot balance operations — ERC-20 (owner only)
    // ──────────────────────────────────────────────

    /// @notice Transfer tokens from the hot balance, subject to per-token limit.
    /// @dev MUST revert if amount exceeds remainingTokenHotBudget(token).
    ///      MUST revert if token has no spending limit configured.
    ///      MUST revert if the vault is paused.
    function hotSpendToken(address token, address to, uint256 amount) external;

    // ──────────────────────────────────────────────
    //  Cold vault operations — ERC-20
    // ──────────────────────────────────────────────

    /// @notice Request a token withdrawal from the cold vault, starting the timelock.
    /// @dev MUST revert if amount exceeds tokenColdBalance(token).
    ///      MUST revert if pendingWithdrawalCount() is at MAX_PENDING_WITHDRAWALS.
    ///      MUST revert if the vault is paused.
    /// @return requestId The ID of the created withdrawal request.
    function requestTokenWithdrawal(address token, address payable to, uint256 amount)
        external
        returns (uint256 requestId);

    // ──────────────────────────────────────────────
    //  Configuration — ERC-20 (owner only, subject to timelock)
    // ──────────────────────────────────────────────

    /// @notice Configure or update the spending limit for an ERC-20 token.
    /// @dev First-time configuration MAY take effect immediately.
    ///      Subsequent limit increases and epoch duration decreases SHOULD be
    ///      subject to a timelock delay.
    ///      Limit decreases and epoch duration increases MAY take effect immediately.
    function setTokenSpendingLimit(
        address token,
        uint256 newLimit,
        uint256 newEpochDuration
    ) external;
}
```

### Interface — DeFi Execution Extension

Compliant contracts that support interaction with external DeFi protocols (acting as a
smart account / EOA-like wallet) MUST additionally implement the following interface:

```solidity
interface ICoercionResistantVaultExecutor {

    // ──────────────────────────────────────────────
    //  Events — Execution & Whitelist
    // ──────────────────────────────────────────────

    /// @notice Emitted when a call is executed against a whitelisted target.
    event Executed(address indexed target, uint256 value, bytes data, bytes result);

    /// @notice Emitted when a batch of calls is executed.
    event BatchExecuted(uint256 count);

    /// @notice Emitted when the vault approves a whitelisted spender for a token.
    event TokenApproval(address indexed token, address indexed spender, uint256 amount);

    /// @notice Emitted when a target contract is added to or removed from the whitelist.
    event TargetWhitelisted(address indexed target, bool allowed);

    /// @notice Emitted when a whitelist change is scheduled (addition requires timelock).
    event WhitelistChangeScheduled(address indexed target, uint256 effectiveTime);

    /// @notice Emitted when a scheduled whitelist change is cancelled.
    event WhitelistChangeCancelled(address indexed target);

    // ──────────────────────────────────────────────
    //  Views — Whitelist
    // ──────────────────────────────────────────────

    /// @notice Returns true if the target contract is whitelisted for execution.
    function isWhitelisted(address target) external view returns (bool);

    // ──────────────────────────────────────────────
    //  Token Allowance — Owner only
    // ──────────────────────────────────────────────

    /// @notice Approve a whitelisted spender to spend vault tokens.
    /// @dev MUST revert if `spender` is not whitelisted. This is the ONLY way
    ///      to grant ERC-20 allowances from the vault. Calling `execute()` against
    ///      a token contract to invoke `approve()` directly MUST NOT be possible
    ///      (token contracts MUST NOT be whitelisted — doing so would allow
    ///      `transfer()` calls that bypass spending limits).
    ///      MUST revert if the vault is paused.
    /// @param token   The ERC-20 token to approve.
    /// @param spender The whitelisted contract to grant allowance to.
    /// @param amount  The allowance amount (0 to revoke).
    function approveToken(address token, address spender, uint256 amount) external;

    // ──────────────────────────────────────────────
    //  Execution — Owner only
    // ──────────────────────────────────────────────

    /// @notice Execute an arbitrary call to a whitelisted target contract.
    /// @dev MUST revert if `target` is not whitelisted.
    ///      MUST revert if the vault is paused.
    ///      ETH value sent with the call is NOT subject to the hot spending limit,
    ///      as DeFi operations (swaps, LP) are value-preserving exchanges, not spends.
    ///      The vault retains custody — funds flow out and back through the protocol.
    /// @param target The whitelisted contract to call.
    /// @param value  The ETH value to send with the call.
    /// @param data   The calldata to execute.
    /// @return result The return data from the call.
    function execute(address target, uint256 value, bytes calldata data)
        external
        returns (bytes memory result);

    /// @notice Execute a batch of calls to whitelisted targets atomically.
    /// @dev All targets MUST be whitelisted. Reverts if any call fails.
    ///      MUST revert if the vault is paused.
    ///      Useful for multi-step DeFi operations (e.g., approve + swap,
    ///      or approve + addLiquidity).
    function executeBatch(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata datas
    ) external returns (bytes[] memory results);

    // ──────────────────────────────────────────────
    //  Whitelist management (owner only, additions timelocked)
    // ──────────────────────────────────────────────

    /// @notice Add or remove a target contract from the whitelist.
    /// @dev Additions MUST be subject to a timelock delay equal to at least
    ///      the current `timelockDuration`. This prevents an attacker from
    ///      whitelisting a malicious contract and draining immediately.
    ///      Removals MAY take effect immediately (more secure).
    function setWhitelistedTarget(address target, bool allowed) external;

    /// @notice Execute a scheduled whitelist addition after the timelock.
    function executeWhitelistChange(address target) external;

    /// @notice Cancel a scheduled whitelist change.
    function cancelWhitelistChange(address target) external;
}
```

### Constants

Compliant implementations MUST define the following constants:

- `MAX_PENDING_WITHDRAWALS`: the maximum number of concurrent unresolved withdrawal
  requests. RECOMMENDED value: `32`. Prevents unbounded storage growth and DoS via
  request spam if the owner's key is compromised.
- `MAX_PAUSE_DURATION`: the maximum duration of a single guardian-initiated pause.
  RECOMMENDED value: `24 hours`. After this period the pause auto-expires unless
  extended via multisig.

### Behavior Requirements

#### Hot Balance and Spending Limits — ETH

1. The vault MUST track a `spendingLimit` and an `epochDuration` for native ETH.
2. The vault MUST track `spentInCurrentEpoch` and reset it when the current epoch expires.
3. `hotSpend()` MUST revert if `amount > remainingHotBudget()`.
4. `remainingHotBudget()` MUST return `min(spendingLimit - spentInCurrentEpoch, address(this).balance)`.
5. The hot balance is NOT a separate pool—it is a rate-limited view of the total balance.
   The cold balance is calculated as `totalBalance - remainingHotBudget()`.
6. Reducing `epochDuration` while keeping the same `spendingLimit` effectively increases
   the spending rate and MUST be subject to the same timelock delay as a limit increase.

#### Hot Balance and Spending Limits — ERC-20 Tokens

7. Each ERC-20 token MUST have independent spending limit, epoch duration, and epoch
   tracking state.
8. A token with no configured spending limit (epoch duration = 0) MUST have a hot budget
   of zero—all tokens are in the cold vault by default until configured.
9. `hotSpendToken()` MUST revert if the token has no spending limit configured.
10. `hotSpendToken()` MUST revert if `amount > remainingTokenHotBudget(token)`.
11. Token epoch resets MUST be independent from the ETH epoch.
12. Per-token epoch duration decreases MUST follow the same timelock rule as ETH.

#### Cold Vault Withdrawals

13. `requestWithdrawal()` MUST create a pending request with `unlockTime = block.timestamp + timelockDuration`.
14. `requestWithdrawal()` and `requestTokenWithdrawal()` MUST revert if
    `pendingWithdrawalCount() >= MAX_PENDING_WITHDRAWALS`. This prevents unbounded
    storage growth and denial-of-service via request spam.
15. `requestTokenWithdrawal()` MUST store the token address in the withdrawal request.
16. `executeWithdrawal()` MUST handle both ETH and token requests based on the stored
    token address (address(0) = ETH).
17. `executeWithdrawal()` MUST revert if `block.timestamp < unlockTime`.
18. `executeWithdrawal()` MUST revert if the request has been cancelled.
19. `cancelWithdrawal()` MUST be callable by the owner OR any registered guardian.
20. `cancelWithdrawal()` MUST work at any time before execution, including after the
    timelock expires, and including while the vault is paused (safety action).
21. Executed or cancelled withdrawal requests MUST decrement `pendingWithdrawalCount`.

#### Multisig Bypass

22. `approveWithdrawal()` MUST be callable only by registered guardians.
23. Each guardian MUST only be able to approve each request once.
24. When `approvalCount >= multisigThreshold`, the withdrawal MUST become immediately
    executable (timelock bypassed).
25. `multisigThreshold` MUST be at least 2 when guardians are configured.

#### Guardian Management Invariants

26. Removing a guardian MUST revert if it would leave `guardianList.length < multisigThreshold`.
    The owner MUST explicitly reduce the threshold first via `setMultisigThreshold()` before
    removing guardians that would violate this invariant. This prevents the vault from
    entering an unreachable state where multisig bypass is impossible.

#### Emergency Pause

27. `pause()` MUST be callable by any single registered guardian.
28. While paused, the following operations MUST revert: `hotSpend`, `hotSpendToken`,
    `requestWithdrawal`, `requestTokenWithdrawal`, `execute`, `executeBatch`, `approveToken`.
29. While paused, the following operations MUST remain callable: `cancelWithdrawal`,
    `approveWithdrawal`, `unpause`, any view functions, deposits, and configuration
    reads. These are safety or read-only actions.
30. A pause MUST auto-expire after `MAX_PAUSE_DURATION` from activation. After expiry,
    operations resume without any explicit `unpause()` call.
31. `unpause()` before auto-expiry MUST require multisig approval
    (`>= multisigThreshold` guardian signatures). The owner alone cannot unpause.
32. A single guardian MAY extend an active pause by calling `pause()` again, resetting
    the auto-expiry timer. This allows sustained freezing when suspicious activity
    continues.

#### Token Allowances

33. `approveToken()` MUST revert if `spender` is not in the whitelist.
34. `approveToken()` is the ONLY mechanism to grant ERC-20 allowances from the vault.
    ERC-20 token contracts MUST NOT be added to the whitelist — doing so would allow
    `execute()` to call `transfer()` or `approve()` directly, bypassing spending limits
    and the whitelisted-spender requirement.
35. `approveToken()` with `amount = 0` MUST revoke the allowance. Implementations
    SHOULD encourage revoking allowances after use.

#### DeFi Execution

36. `execute()` MUST revert if `target` is not in the whitelist.
37. `execute()` MUST revert if `target` is address(0) or the vault itself.
38. `executeBatch()` MUST revert atomically if any individual call fails.
39. `executeBatch()` MUST revert if array lengths do not match.
40. ETH value sent via `execute()` is NOT subject to the hot spending limit. DeFi
    operations (swaps, liquidity provision) are value-preserving exchanges where the
    vault retains custody of the resulting assets. The whitelist is the security
    boundary, not the spending limit.
41. `hotSpend()` and `hotSpendToken()` remain the only paths for direct asset transfers
    to non-whitelisted addresses.

#### Whitelist Management

42. Adding a target to the whitelist MUST be subject to a timelock delay equal to at
    least the current `timelockDuration`.
43. Removing a target from the whitelist MAY take effect immediately (this makes the
    vault more restrictive, not less).
44. The whitelist MUST NOT allow adding the vault's own address as a target
    (re-entrancy vector).
45. Cancellation of pending whitelist changes MUST be callable by the owner or any
    guardian.

#### Configuration Security

46. Increases to `spendingLimit` (ETH) MUST be subject to a timelock delay equal to at
    least the current `timelockDuration`. This prevents an attacker from forcing the
    victim to raise the limit and then drain immediately.
47. Increases to token spending limits MUST follow the same timelock rule. First-time
    configuration (when no limit exists) MAY take effect immediately, as it only enables
    a hot budget where none existed before.
48. Decreases to `timelockDuration` MUST be subject to a delay equal to the current
    `timelockDuration`.
49. Changes to the guardian set MUST be subject to a timelock delay.
50. Decreases to spending limits (ETH or token) and increases to `timelockDuration` MAY
    take effect immediately (these changes make the vault more secure, not less).
51. The `timelockDuration` is shared across all assets—there is no per-token timelock.

### ERC-165 Support

Compliant contracts MUST implement ERC-165 and return `true` for the interface IDs of
`ICoercionResistantVault` and, if token support is implemented, `ICoercionResistantVaultTokens`.
If DeFi execution support is implemented, the contract MUST also return `true` for
`ICoercionResistantVaultExecutor`.

### ERC-4337 Account Abstraction

Compliant contracts MUST implement the ERC-4337 `IAccount` interface (v0.7), allowing
the vault to be used as a first-class smart account with any dApp that supports
UserOperations (Uniswap, Aave, etc. via compatible wallets like MetaMask).

```solidity
interface IAccount {
    /// @notice Validate a UserOperation and pay the EntryPoint prefund.
    /// @dev Called by the EntryPoint during the validation phase.
    ///      MUST verify that userOp.signature is a valid ECDSA signature
    ///      from the vault owner over the EIP-191 prefixed userOpHash.
    ///      MUST pay missingAccountFunds to the EntryPoint for gas.
    /// @return validationData 0 for success, 1 for signature failure.
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external returns (uint256 validationData);
}
```

#### ERC-4337 Behavior Requirements

52. `validateUserOp()` MUST only be callable by the canonical EntryPoint.
53. `validateUserOp()` MUST verify that the signature is a valid ECDSA signature
    from the vault owner over the EIP-191 prefixed `userOpHash`.
54. `validateUserOp()` MUST reject malleable signatures (high `s` values per EIP-2).
55. `validateUserOp()` MUST pay `missingAccountFunds` to the EntryPoint when > 0.
56. All `onlyOwner` functions (hotSpend, execute, approveToken, configuration, etc.)
    MUST accept calls from the EntryPoint address in addition to the owner, because
    the EntryPoint calls the account with `userOp.callData` after successful validation.
57. Implementations MUST provide a mechanism to deposit ETH to the EntryPoint to cover
    gas costs for UserOperations.
58. The vault's security model (spending limits, timelocks, whitelist, pause state)
    MUST apply identically regardless of whether calls arrive directly from the owner
    or via the EntryPoint.

## Rationale

### Why rate-limited hot balance instead of a fixed hot pool?

A fixed hot pool requires the user to manually "refill" it, adding friction. A rate-limited
approach means the user always has access to their daily budget without any action, while
the bulk of funds remains inaccessible on short notice. The rate limit also means that even
if an attacker keeps the victim coerced for extended periods, the maximum extractable value
grows linearly and slowly.

### Why independent spending limits per token?

Different assets have different values and use patterns. A user might want a generous USDC
spending limit for daily expenses (e.g., 500 USDC/day) while keeping a very tight limit on
WETH or WBTC. Independent limits allow granular control per asset. This also means that
adding a new token to the vault doesn't automatically make it spendable—tokens start with
zero hot budget by default.

### Why shared timelock across all assets?

The timelock is a security parameter, not an asset-management parameter. Having per-token
timelocks would mean the attacker could search for the token with the shortest timelock to
extract value. A single shared timelock simplifies the security model and ensures consistent
protection regardless of which assets the vault holds.

### Why allow both timelock AND multisig?

Different users have different threat models and social graphs:

- A user with trusted family members or business partners may prefer a 2-of-3 multisig for
  quick access when legitimately needed.
- A user without suitable cosigners may prefer a longer timelock (72h+) as the sole
  protection mechanism.
- Many users will use both: multisig for planned large transactions, timelock as the
  fallback for solo operations.

### Why must configuration changes also be timelocked?

Without this, an attacker could force the victim to: (1) raise the spending limit to
infinity, (2) immediately drain the entire balance. The timelock on configuration changes
closes this attack vector. This applies equally to ETH and token spending limits.

### Why are epoch duration decreases timelocked?

A subtle attack vector: with a fixed spending limit, reducing the epoch duration increases
the effective spending rate. For example, going from "1 ETH / 24h" to "1 ETH / 1h" means
24x more can be extracted per day. Without the timelock on duration decreases, an attacker
could force the victim to compress epochs and drain rapidly. Treating duration decreases
the same as limit increases closes this vector.

### Why can guardians cancel withdrawals?

If an attacker forces a cold vault withdrawal and then leaves (planning to return after the
timelock), a guardian can cancel the withdrawal during the delay period. This gives the
victim and their trusted contacts a window to respond.

### Why an emergency pause mechanism?

Cancellation alone is insufficient — it only stops pending cold vault withdrawals. It does
not stop the owner's key from continuing to drain the hot balance or interact with DeFi
via `execute()`. The emergency pause is a true "freeze everything now" button available
to any single guardian, for cases where:

- The owner has been kidnapped and is being held for extended coercion
- The owner's key has been compromised (phishing, malware) and is actively being drained
- Unusual activity patterns suggest an ongoing attack

Single-guardian activation is intentional: waiting for multisig consensus during an active
attack defeats the purpose. The 24-hour auto-expiry and multisig requirement for extension
prevent a malicious or compromised guardian from freezing funds indefinitely.

### Why a cap on pending withdrawal requests?

Without a limit, the owner (or an attacker with the owner's key) could call
`requestWithdrawal()` thousands of times, bloating storage and potentially causing
denial-of-service conditions. The cap is low enough to prevent abuse (32) but high enough
for any legitimate multi-withdrawal workflow. Cancelled or executed requests free up
slots, so the limit applies only to unresolved requests.

### Why guard against guardian removal below threshold?

If removing a guardian would leave fewer guardians than the multisig threshold, the
multisig bypass path becomes permanently unreachable. Cold vault withdrawals could only
exit via the timelock, which is not a security issue per se but removes a capability the
owner likely wants. Requiring an explicit threshold reduction before such a removal
forces the owner to acknowledge the change and maintains a consistent, reachable state.

### Why not use a duress PIN / panic wallet instead?

Duress-based systems rely on the attacker not knowing about the mechanism. If an attacker
is aware of duress wallets (increasingly likely as they become common), they may torture
the victim further, demanding the "real" wallet. A verifiable on-chain constraint is
superior because:

1. The limitation is publicly auditable—the attacker can verify it themselves.
2. The victim does not need to lie or perform theater under extreme stress.
3. The mechanism works regardless of attacker sophistication.

### Why allow DeFi execution via whitelisted targets?

A vault that can only send ETH/tokens to addresses is not practical for users who
participate in DeFi. Without execution capability, users would need to withdraw funds
from the vault, interact with protocols, and re-deposit—negating the security benefits.
By allowing `execute()` calls to whitelisted contracts, the vault can act as a smart
account: performing swaps on Uniswap, providing liquidity on Aave, etc., while the
funds never leave the vault's custody.

The whitelist is the security boundary. Adding a new target requires waiting the full
timelock, so an attacker cannot force the victim to whitelist a malicious drainer
contract and call it immediately. Removing targets is instant—cutting off access is
always safe.

### Why a dedicated approveToken() instead of using execute()?

To interact with DeFi protocols, the vault must grant ERC-20 allowances (e.g., approve a
DEX router before a swap). If allowances were granted via `execute()` calling `approve()`
on the token contract, the token contract itself would need to be whitelisted. But a
whitelisted token contract would also allow `execute()` to call `transfer()`, bypassing
the vault's spending limits entirely.

`approveToken(token, spender, amount)` solves this by only requiring the **spender** to
be whitelisted, not the token contract. The typical DeFi flow becomes:

1. `approveToken(USDC, uniswapRouter, 1000e6)` — grant allowance to whitelisted router
2. `execute(uniswapRouter, 0, swapExactTokensForTokens(...))` — call the router
3. `approveToken(USDC, uniswapRouter, 0)` — revoke allowance (recommended)

This keeps token contracts out of the whitelist while enabling all standard DeFi
interactions.

### Why is DeFi execution not subject to spending limits?

DeFi operations like swaps and liquidity provision are value-preserving: the vault sends
ETH/tokens to a protocol and receives other assets back. Applying the hot spending limit
to `execute()` would make most DeFi operations impossible (a 10 ETH swap would consume
the entire daily budget despite the vault receiving equivalent value back). The whitelist
serves as the security control instead—only pre-approved, timelocked contracts can be
called.

`hotSpend()` and `hotSpendToken()` remain the exclusive paths for direct transfers to
arbitrary addresses, where spending limits are enforced.

### Why require ERC-4337 instead of just direct calls?

Without account abstraction, the vault requires a custom frontend for every dApp
interaction. With ERC-4337, the vault becomes a standard smart account that works with
any dApp via compatible wallets (MetaMask, Ambire, etc.):

1. User connects their vault address (not the owner EOA) to Uniswap.
2. Uniswap builds a swap transaction targeting the vault.
3. The wallet builds a UserOperation with `callData = abi.encodeCall(execute, (...))`.
4. The owner signs the UserOperation with their EOA key.
5. A bundler submits it to the EntryPoint.
6. EntryPoint calls `validateUserOp()` (verifies owner signature), then executes.

The vault's spending limits, timelocks, and whitelist apply identically regardless of
the execution path. ERC-4337 is the transport layer; the vault's security model is the
enforcement layer.

### Why is first-time token configuration immediate?

When `setTokenSpendingLimit()` is called for a token with no prior limit, the change only
*enables* a hot budget where none existed. This is a security-neutral or security-weakening
change in isolation, but it is necessary for usability: without it, every new token added
to the vault would require waiting the full timelock period before any daily spending is
possible. The risk is bounded because the spending limit itself is still capped.

## Backwards Compatibility

This ERC introduces a new contract standard and does not modify existing standards. It is
fully backwards compatible. Existing wallets can migrate funds to a compliant vault contract
at any time.

## Reference Implementation

See [`CoercionResistantVault.sol`](./CoercionResistantVault.sol) for a complete reference
implementation supporting both native ETH and ERC-20 tokens.

## Security Considerations

### Attacker holds victim for extended periods

If an attacker holds a victim for multiple epochs, they can extract `spendingLimit` per
epoch. Implementations SHOULD allow users to set aggressive spending limits (e.g., 0.1 ETH
per 24h) to minimize this risk. A 72-hour timelock combined with a low daily limit means
even sustained coercion yields limited value. With ERC-20 tokens, the attacker would need
to know which tokens are in the vault and extract each one subject to its own limit.

### Attacker drains multiple token types

An attacker aware of the vault's contents could attempt to extract the hot budget from
every configured token simultaneously. The total extractable value is the sum of all
per-token hot budgets. Users SHOULD consider the aggregate hot exposure across all assets
when configuring limits.

### Attacker targets guardians

If an attacker knows the guardian addresses, they might target guardians to force multisig
approval. Implementations SHOULD recommend that guardian identities remain private.
Guardians MAY be institutional custodians, hardware wallets in bank vaults, or
time-delayed smart contracts themselves.

### Social engineering of guardians

A sophisticated attacker might contact guardians with a plausible story to get their
approval. Guardians SHOULD establish out-of-band verification protocols with the vault
owner (e.g., code words, video calls, in-person verification).

### Griefing via cancellation

A malicious guardian could repeatedly cancel legitimate withdrawal requests. The owner
SHOULD be able to remove guardians, though this action is itself subject to a timelock.
Implementations MAY add a dispute resolution mechanism or require a majority of guardians
to agree on cancellation.

### Griefing via emergency pause

A malicious guardian could repeatedly pause the vault, disrupting normal operation. The
24-hour auto-expiry bounds the damage of any single pause. A malicious guardian can at
most cause 24 hours of downtime before the pause expires or other guardians intervene
via `unpause()`. The owner can initiate guardian removal immediately after an abusive
pause, though the removal itself is timelocked. Implementations MAY add a rate limit on
pause activations by a single guardian (e.g., no more than once per 72 hours).

### Front-running and MEV

Withdrawal execution transactions are not time-sensitive in a way that creates significant
MEV opportunities, as the unlock time provides a wide execution window.

### Smart contract risk

As with any smart contract wallet, bugs in the implementation could lead to loss of funds.
Implementations MUST undergo thorough auditing. The simplicity of the interface is
intentional—fewer features mean a smaller attack surface.

### ERC-20 token risks

Some ERC-20 tokens have non-standard behavior (fee-on-transfer, rebasing, pausable,
blocklisted). Implementations SHOULD account for fee-on-transfer tokens by checking actual
received amounts. Rebasing tokens may cause balance discrepancies between tracked spending
limits and actual balances. Implementations SHOULD NOT assume that `transfer(to, amount)`
always delivers exactly `amount` tokens.

### Malicious whitelisted contract

If a whitelisted contract is compromised or upgraded to a malicious implementation,
the attacker could drain the vault via `execute()`. Mitigations:

- Implementations SHOULD recommend whitelisting only immutable or well-audited contracts.
- Proxy contracts (upgradeable) carry additional risk—a governance attack on the protocol
  could turn a whitelisted target into a drainer.
- Guardians can immediately remove a compromised target from the whitelist via
  `cancelWhitelistChange()` or the owner can call `setWhitelistedTarget(target, false)`.
- Users SHOULD periodically review their whitelist and remove unused targets.

### Token allowances via approveToken()

The `approveToken()` function grants ERC-20 allowances to whitelisted spender contracts.
This is necessary for DeFi interactions (e.g., approving a DEX router before a swap).
Token contracts themselves MUST NOT be whitelisted — doing so would allow `execute()` to
call `transfer()` or `approve()` directly, bypassing spending limits and the whitelisted-
spender constraint.

Unlimited approvals (`type(uint256).max`) carry risk if the approved contract is later
compromised. Implementations SHOULD recommend exact-amount approvals and revoking
allowances after use (`approveToken(token, spender, 0)`).

### Re-entrancy via execute()

The `execute()` function performs an external call, which could re-enter the vault.
Implementations SHOULD use a reentrancy guard on `execute()` and `executeBatch()`.
The reference implementation relies on the whitelist as the trust boundary, but defense
in depth via `nonReentrant` modifiers is RECOMMENDED.

### EntryPoint trust model

The vault trusts the EntryPoint to only call functions after successful signature
validation. If the canonical EntryPoint contract were compromised, an attacker could
call any `onlyOwner` function without a valid signature. This risk is inherent to
all ERC-4337 accounts and is mitigated by the EntryPoint being a well-audited,
immutable singleton contract. Implementations MUST use the canonical EntryPoint and
MUST NOT allow changing it after deployment.

### Signature replay across chains

The `userOpHash` provided by the EntryPoint includes the chain ID, preventing cross-chain
replay. However, if the same owner deploys vaults on multiple chains with the same
EntryPoint, a UserOperation for one chain cannot be replayed on another because the
vault address and chain ID are part of the hash.

### Configuration lock-out

If the owner loses access to their key, the cold vault funds become permanently locked
(no guardian has unilateral withdrawal rights). Implementations SHOULD consider adding a
social recovery mechanism compatible with the vault's security model.

## Acknowledgments

Thanks to the following community members for review and feedback that shaped this
specification:

- **Harish Kumar Gunjalli** ([@HarishKumarGunjalli](https://ethereum-magicians.org/u/HarishKumarGunjalli)) —
  identified the guardian-removal-below-threshold invariant, raised the concurrent
  withdrawal DoS concern, surfaced the epoch duration attack vector, and proposed the
  emergency pause mechanism. [Review thread](https://ethereum-magicians.org/t/erc-coercion-resistant-vault-spending-limits-timelock-multisig-against-5-wrench-attacks/28130/2).

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
