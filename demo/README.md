# Demo: Coercion-Resistant Vault on Sepolia

Live demo of the Coercion-Resistant Vault reference implementation, deployed
to Sepolia testnet and interactive via MetaMask. Proves the vault works as a
smart account with real on-chain protocols (WETH9, Uniswap V3).

## What the demo does

- **Connects MetaMask** to the vault (Sepolia only)
- **Shows live vault state**: hot/cold split, spending limit, timelock, pending withdrawals
- **Deposits** ETH from any wallet
- **Hot spends** from the rate-limited budget (owner only)
- **Cold withdrawals** with real-time timelock countdown and cancel support
- **Uniswap V3 swap** (WETH → USDC) via the vault's `execute()` path —
  demonstrates that DeFi operations do not consume the hot spending budget
- **Event log** streams all vault activity in real time

## Prerequisites

- [Foundry](https://book.getfoundry.sh/) installed (`forge`, `cast`)
- [MetaMask](https://metamask.io) browser extension
- A Sepolia RPC URL (Alchemy/Infura/QuickNode — free tier works)
- A small amount of Sepolia ETH in a **deployer wallet** (a burner, not your
  main MetaMask — see step 2 below). Get from [sepoliafaucet.com](https://sepoliafaucet.com/)
- A small amount of Sepolia ETH in your **MetaMask EOA** (will become vault owner)

---

## Step 1 — Configure environment

From the repo root:

```bash
cp .env.example .env
```

Edit `.env` and fill in:

```
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
DEPLOYER_PRIVATE_KEY=0x...           # burner wallet, see step 2
VAULT_OWNER=0xYourMetaMaskAddress    # your MetaMask EOA on Sepolia
ETHERSCAN_API_KEY=YourEtherscanKey   # free at etherscan.io/myapikey
```

The vault-config defaults are already populated (0.05 ETH/day hot limit,
3-hour timelock, 2-of-3 multisig). Override in `.env` if you want different
values.

## Step 2 — Create a burner deployer wallet

Your **MetaMask key should never touch `.env`**. Create a burner wallet that
only pays for the deployment:

```bash
cast wallet new
```

Copy the `Private key` into `DEPLOYER_PRIVATE_KEY` in `.env`. Copy the `Address`
and send it ~0.1 Sepolia ETH from a faucet or from MetaMask. After deployment,
the burner has no control over the vault — all authority lives with the owner
address (your MetaMask).

## Step 3 — Deploy

```bash
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

When it succeeds, you'll see:

```
Vault deployed at: 0xAbC…
```

Copy that address. The script also logs the Etherscan link — click it to
verify the contract was verified (green checkmark on Etherscan).

## Step 4 — Update the demo config

Open `demo/deployment.sepolia.json` and replace the `vault` field with the
deployed address:

```json
{
  "vault": "0xAbC...",
  ...
}
```

If you used a different owner address than the default, update `owner` too.

## Step 5 — Fund the vault

Send some Sepolia ETH to the vault address. With the default config:
- Hot spending limit: 0.05 ETH per 24h
- Cold withdrawal timelock: 3 hours

Send at least 0.2 ETH so both hot and cold flows have room to play with.

## Step 6 — One-time whitelist setup

The Uniswap swap demo requires WETH9 and the Uniswap SwapRouter02 to be
whitelisted. Whitelist additions are subject to the vault's timelock
(3 hours in the default config), so this is a one-time setup.

Replace `$VAULT` with your deployed vault address and run:

```bash
source .env

VAULT=0xYourVaultAddress

# Schedule WETH + router whitelist additions
cast send $VAULT "setWhitelistedTarget(address,bool)" \
  0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 true \
  --rpc-url $SEPOLIA_RPC_URL --private-key <your-owner-private-key>

cast send $VAULT "setWhitelistedTarget(address,bool)" \
  0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E true \
  --rpc-url $SEPOLIA_RPC_URL --private-key <your-owner-private-key>
```

Then wait 3 hours (or whatever `VAULT_TIMELOCK_DURATION` you set), and execute
the scheduled changes:

```bash
cast send $VAULT "executeWhitelistChange(address)" \
  0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14 \
  --rpc-url $SEPOLIA_RPC_URL --private-key <your-owner-private-key>

cast send $VAULT "executeWhitelistChange(address)" \
  0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E \
  --rpc-url $SEPOLIA_RPC_URL --private-key <your-owner-private-key>
```

> ⚠️ The `cast send` commands need the owner's private key. If that's your
> MetaMask, you can either (a) export it temporarily just for these commands
> and then delete it, (b) use MetaMask directly by calling the methods from
> the connected frontend (feature not yet in this demo — PRs welcome!),
> or (c) rebuild the vault with a shorter timelock for the demo.

**Alternative: shorter timelock for demo.** Set `VAULT_TIMELOCK_DURATION=300`
(5 minutes) in `.env` before deploying and you can whitelist + swap the same
afternoon.

## Step 7 — Open the demo

The frontend is static — any static server works. Two easy options:

```bash
# Option A: Python
cd demo
python -m http.server 8000
# Then open http://localhost:8000

# Option B: Node
cd demo
npx serve .
```

Click **"Connect MetaMask"**, switch to Sepolia if prompted, and play with
the vault. The **Uniswap swap** button runs the full DeFi flow:

1. Wraps ETH → WETH via `execute(WETH, value, deposit())`
2. Approves the router via `approveToken(WETH, router, amount)`
3. Swaps WETH → USDC via `execute(router, 0, exactInputSingle(…))`

All three transactions come from MetaMask as the vault owner. The USDC lands
in the vault's custody. The hot spending counter stays at zero because
DeFi operations are value-preserving.

---

## Simulating guardian actions

The deploy script uses three well-known Anvil test addresses as guardians:

| Guardian | Address | Private key (public test key) |
|---|---|---|
| 1 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d` |
| 2 | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | `0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a` |
| 3 | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` | `0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6` |

These keys are **publicly known** — they are Anvil's default test accounts.
They are used here ONLY so that anyone can reproduce guardian actions on a
testnet deployment. **Never use them on mainnet or anywhere real funds exist.**

The guardians need a tiny bit of Sepolia ETH to pay gas. Send ~0.01 Sepolia ETH
to each from a faucet.

### Example: Multisig bypass

1. Connect as owner and request a large cold withdrawal from the demo
2. Copy the request ID from the pending list
3. Have two guardians approve:

```bash
cast send $VAULT "approveWithdrawal(uint256)" <requestId> \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d

cast send $VAULT "approveWithdrawal(uint256)" <requestId> \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
```

4. Back in the demo, click **Execute** — the withdrawal goes through
   immediately, despite the timelock not having expired.

### Example: Emergency pause

```bash
cast send $VAULT "pause()" \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
```

The demo will show "Paused: YES". Any hotSpend/execute attempt from the owner
will revert until the pause auto-expires after 24h, or two guardians call
`unpause()`.

---

## Troubleshooting

**"Vault address not set" error on page load**
Make sure `demo/deployment.sepolia.json` has the deployed vault address,
not the zero address placeholder.

**"TargetNotWhitelisted" error when swapping**
Step 6 hasn't been completed yet, or the timelock hasn't expired. Check
`vault.isWhitelisted(WETH)` and `vault.isWhitelisted(router)` via Etherscan.

**"ExceedsHotBudget" error on Hot Spend**
You've spent your epoch's hot budget. Wait until the epoch resets
(epoch start + `epochDuration`), or set a higher `VAULT_SPENDING_LIMIT`
for the demo.

**"ExceedsColdBalance" error on Cold Withdrawal**
The vault doesn't have enough ETH beyond the hot budget to cover the
requested amount. Deposit more ETH first.

**Uniswap swap fails with no obvious reason**
The WETH/USDC 0.3% pool on Sepolia occasionally lacks liquidity. The wrap
step always works — that alone proves the `execute()` mechanism. Check
the pool on [Uniswap info](https://info.uniswap.org/) or try a different
fee tier (edit `fee: 3000` in `app.js`).

---

## What this demo proves

- The vault compiles, deploys, and runs on a live EVM
- An EOA (MetaMask) can be the `owner` and interact with the vault directly
  through standard transactions
- The vault can call arbitrary whitelisted contracts via `execute()`
- DeFi swaps work end-to-end: WETH wrap, token approval, router swap, USDC custody
- Spending limits, timelocks, and pause state all behave per spec under real
  usage conditions

What it does **not** prove (and why):

- **ERC-4337 UserOperations**: MetaMask currently doesn't build UserOps
  natively. A full 4337 demo would require integrating a bundler (Pimlico,
  Alchemy, Stackup) and a custom frontend that constructs + signs UserOps.
  This is planned as a follow-up demo. The vault's `validateUserOp()` is
  exercised in the unit test suite.
