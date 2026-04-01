---
eip: TBD
title: Coercion-Resistant Vault Standard
description: A smart contract wallet standard with spending limits, timelocks, and multisig to protect against physical coercion attacks
author: cmayorga (@cmayorga)
discussions-to: https://ethereum-magicians.org/t/erc-coercion-resistant-vault/TBD
status: Draft
type: Standards Track
category: ERC
created: 2026-04-01
requires: 165, 4337
---

<!--
  NOTE: The EIP number (currently "TBD") will be assigned by an EIP editor
  when this proposal is submitted as a Pull Request to the ethereum/EIPs
  repository. Do NOT self-assign a number.

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
    function hotSpend(address payable to, uint256 amount) external;

    // ──────────────────────────────────────────────
    //  Cold vault operations — ETH
    // ──────────────────────────────────────────────

    /// @notice Request an ETH withdrawal from the cold vault, starting the timelock.
    /// @dev MUST revert if amount exceeds coldBalance(). Only callable by owner.
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
    function cancelWithdrawal(uint256 requestId) external;

    /// @notice Approve a pending withdrawal via multisig, bypassing the timelock.
    /// @dev Only callable by guardians. When approvalCount >= multisigThreshold,
    ///      the withdrawal becomes immediately executable.
    function approveWithdrawal(uint256 requestId) external;

    // ──────────────────────────────────────────────
    //  Configuration (owner only, subject to timelock)
    // ──────────────────────────────────────────────

    /// @notice Update the ETH hot balance spending limit.
    /// @dev Increases SHOULD be subject to a timelock delay.
    ///      Decreases MAY take effect immediately.
    function setSpendingLimit(uint256 newLimit, uint256 newEpochDuration) external;

    /// @notice Update the timelock duration for cold vault withdrawals.
    /// @dev Shared across ETH and all tokens.
    ///      Decreases SHOULD be subject to the current timelock delay.
    ///      Increases MAY take effect immediately.
    function setTimelockDuration(uint256 newDuration) external;

    /// @notice Add or remove a guardian.
    /// @dev Changes SHOULD be subject to a timelock delay.
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
    function hotSpendToken(address token, address to, uint256 amount) external;

    // ──────────────────────────────────────────────
    //  Cold vault operations — ERC-20
    // ──────────────────────────────────────────────

    /// @notice Request a token withdrawal from the cold vault, starting the timelock.
    /// @dev MUST revert if amount exceeds tokenColdBalance(token).
    /// @return requestId The ID of the created withdrawal request.
    function requestTokenWithdrawal(address token, address payable to, uint256 amount)
        external
        returns (uint256 requestId);

    // ──────────────────────────────────────────────
    //  Configuration — ERC-20 (owner only, subject to timelock)
    // ──────────────────────────────────────────────

    /// @notice Configure or update the spending limit for an ERC-20 token.
    /// @dev First-time configuration MAY take effect immediately.
    ///      Subsequent increases SHOULD be subject to a timelock delay.
    ///      Decreases MAY take effect immediately.
    function setTokenSpendingLimit(
        address token,
        uint256 newLimit,
        uint256 newEpochDuration
    ) external;
}
```

### Behavior Requirements

#### Hot Balance and Spending Limits — ETH

1. The vault MUST track a `spendingLimit` and an `epochDuration` for native ETH.
2. The vault MUST track `spentInCurrentEpoch` and reset it when the current epoch expires.
3. `hotSpend()` MUST revert if `amount > remainingHotBudget()`.
4. `remainingHotBudget()` MUST return `min(spendingLimit - spentInCurrentEpoch, address(this).balance)`.
5. The hot balance is NOT a separate pool—it is a rate-limited view of the total balance.
   The cold balance is calculated as `totalBalance - remainingHotBudget()`.

#### Hot Balance and Spending Limits — ERC-20 Tokens

6. Each ERC-20 token MUST have independent spending limit, epoch duration, and epoch
   tracking state.
7. A token with no configured spending limit (epoch duration = 0) MUST have a hot budget
   of zero—all tokens are in the cold vault by default until configured.
8. `hotSpendToken()` MUST revert if the token has no spending limit configured.
9. `hotSpendToken()` MUST revert if `amount > remainingTokenHotBudget(token)`.
10. Token epoch resets MUST be independent from the ETH epoch.

#### Cold Vault Withdrawals

11. `requestWithdrawal()` MUST create a pending request with `unlockTime = block.timestamp + timelockDuration`.
12. `requestTokenWithdrawal()` MUST store the token address in the withdrawal request.
13. `executeWithdrawal()` MUST handle both ETH and token requests based on the stored
    token address (address(0) = ETH).
14. `executeWithdrawal()` MUST revert if `block.timestamp < unlockTime`.
15. `executeWithdrawal()` MUST revert if the request has been cancelled.
16. `cancelWithdrawal()` MUST be callable by the owner OR any registered guardian.
17. `cancelWithdrawal()` MUST work at any time before execution, including after the
    timelock expires.

#### Multisig Bypass

18. `approveWithdrawal()` MUST be callable only by registered guardians.
19. Each guardian MUST only be able to approve each request once.
20. When `approvalCount >= multisigThreshold`, the withdrawal MUST become immediately
    executable (timelock bypassed).
21. `multisigThreshold` MUST be at least 2 when guardians are configured.

#### Configuration Security

22. Increases to `spendingLimit` (ETH) MUST be subject to a timelock delay equal to at
    least the current `timelockDuration`. This prevents an attacker from forcing the
    victim to raise the limit and then drain immediately.
23. Increases to token spending limits MUST follow the same timelock rule. First-time
    configuration (when no limit exists) MAY take effect immediately, as it only enables
    a hot budget where none existed before.
24. Decreases to `timelockDuration` MUST be subject to a delay equal to the current
    `timelockDuration`.
25. Changes to the guardian set MUST be subject to a timelock delay.
26. Decreases to spending limits (ETH or token) and increases to `timelockDuration` MAY
    take effect immediately (these changes make the vault more secure, not less).
27. The `timelockDuration` is shared across all assets—there is no per-token timelock.

### ERC-165 Support

Compliant contracts MUST implement ERC-165 and return `true` for the interface IDs of
`ICoercionResistantVault` and, if token support is implemented, `ICoercionResistantVaultTokens`.

### ERC-4337 Compatibility

Implementations SHOULD be compatible with ERC-4337 account abstraction, allowing the vault
to be used as a smart contract wallet with UserOperations. The hot spend functions (both ETH
and token) SHOULD be callable via UserOp execution, while cold vault operations follow the
same timelock/multisig rules regardless of the execution path.

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

### Why can guardians cancel withdrawals?

If an attacker forces a cold vault withdrawal and then leaves (planning to return after the
timelock), a guardian can cancel the withdrawal during the delay period. This gives the
victim and their trusted contacts a window to respond.

### Why not use a duress PIN / panic wallet instead?

Duress-based systems rely on the attacker not knowing about the mechanism. If an attacker
is aware of duress wallets (increasingly likely as they become common), they may torture
the victim further, demanding the "real" wallet. A verifiable on-chain constraint is
superior because:

1. The limitation is publicly auditable—the attacker can verify it themselves.
2. The victim does not need to lie or perform theater under extreme stress.
3. The mechanism works regardless of attacker sophistication.

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

### Configuration lock-out

If the owner loses access to their key, the cold vault funds become permanently locked
(no guardian has unilateral withdrawal rights). Implementations SHOULD consider adding a
social recovery mechanism compatible with the vault's security model.

## Copyright

Copyright and related rights waived via [CC0](https://creativecommons.org/publicdomain/zero/1.0/).
