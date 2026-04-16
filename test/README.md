# Test Suite

Foundry test suite for the Coercion-Resistant Vault Standard. Proves that the
reference implementation behaves according to the spec, including the critical
security invariants under adversarial conditions.

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
  (`forge --version` should report >= 0.2.0)
- For fork tests: a Sepolia RPC endpoint (Alchemy, Infura, QuickNode, free tier works)

## Setup

From the repository root:

```bash
# Install forge-std (only needs to be done once)
forge install foundry-rs/forge-std --no-commit

# Copy environment template and fill in your Sepolia RPC URL
cp .env.example .env
# edit .env and set SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
```

## Running Tests

### Unit tests only (fast, no RPC required)

```bash
forge test --no-match-contract DeFiFork -vv
```

This runs all tests except the Sepolia fork test, in a few seconds.

### Full suite (unit + Sepolia fork)

```bash
source .env && forge test -vvv
```

The fork tests will skip gracefully if `SEPOLIA_RPC_URL` is not set.

### Gas report

```bash
forge test --gas-report
```

### Specific test file

```bash
forge test --match-path test/CoercionResistantVault.t.sol -vvv
```

### Specific test function

```bash
forge test --match-test test_HotSpend_ExceedsLimit_Reverts -vvv
```

## Coverage

```bash
forge coverage
```

## What Each Test File Covers

| File | Coverage |
|---|---|
| `CoercionResistantVault.t.sol` | Core vault: hot spend, cold withdrawal flow, multisig bypass, emergency pause (24h auto-expiry, multisig unpause), MAX_PENDING cap, config timelock (limit/epoch/timelock changes), guardian management + removal invariant |
| `CoercionResistantVaultTokens.t.sol` | ERC-20 extension: deposits, per-token spending limits, first-time-config immediacy, token limit/epoch timelock semantics, token cold withdrawals |
| `CoercionResistantVaultDeFi.t.sol` | DeFi execution extension with a `MockDexRouter`: whitelist addition timelock, whitelist removal immediacy, `execute()` target gating, `approveToken()` spender gating, atomic `executeBatch()`, and — critically — proof that value-preserving swaps do **not** consume the hot spending budget |
| `CoercionResistantVaultDeFi.fork.t.sol` | Integration test on **live Sepolia fork**: wraps ETH into WETH via `execute()` against the real WETH9 contract, optionally swaps WETH→USDC via Uniswap V3 SwapRouter02. Verifies end-to-end that the vault works as a proper smart account with real on-chain contracts |

## Key Invariants Tested

1. **Hot spend is rate-limited** — exceeds-budget reverts, epoch reset works
2. **Cold vault respects timelock** — pre-timelock execution reverts
3. **Cancellation works** — owner or any guardian can cancel pending withdrawals
4. **Multisig bypasses timelock** — threshold approvals enable instant execution
5. **Same guardian cannot approve twice** — no double counting
6. **Config changes that weaken security are timelocked** — limit increases, epoch decreases, timelock decreases
7. **Config changes that strengthen security are immediate** — limit decreases, epoch increases, timelock increases
8. **Emergency pause** — single guardian can pause, auto-expires in 24h, multisig unpause required, cancellation remains callable during pause
9. **MAX_PENDING cap** — 33rd concurrent withdrawal request reverts; cancellation frees a slot
10. **Guardian removal invariant** — cannot remove a guardian if it would break the multisig threshold
11. **Whitelist timelocked on add, immediate on remove** — attacker cannot whitelist a drainer and call it immediately
12. **approveToken requires whitelisted spender** — not a whitelisted token contract
13. **DeFi execution does NOT consume hot budget** — value-preserving swaps keep the rate limit intact
14. **Pause blocks all value-moving operations** — but safety actions (cancel, approve) remain callable

## Fork Test Notes

The Sepolia fork test attempts two integrations:

1. **WETH wrap** via `execute(WETH, value, deposit())` — always works, WETH has no
   liquidity requirements. This is the canonical proof that the vault can act as
   a smart account against real on-chain contracts.

2. **Uniswap V3 swap** WETH→USDC via SwapRouter02 — may skip if the pool doesn't
   exist or has insufficient liquidity on Sepolia. The test uses `try/catch` and
   skips gracefully. Verify the router address in `.env` if you want this path
   to work; addresses can change between Uniswap deployments.

See the [Uniswap V3 deployments documentation](https://docs.uniswap.org/contracts/v3/reference/deployments/ethereum-deployments)
for the latest canonical Sepolia addresses.
