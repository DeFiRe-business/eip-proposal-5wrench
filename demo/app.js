// ════════════════════════════════════════════════════════════════════════════
//  Coercion-Resistant Vault — Demo frontend
//
//  Connects to MetaMask, reads vault state from Sepolia, and lets the user
//  exercise the vault's core flows: deposit, hot spend, cold withdrawal, and
//  the flagship DeFi swap on Uniswap V3 via execute().
//
//  Supports custom vault addresses: if the visitor has deployed their own
//  vault, they can paste its address in the input field to use it instead
//  of the default DeFiRe Labs vault.
// ════════════════════════════════════════════════════════════════════════════

import { ethers } from "ethers";
import { VAULT_ABI, WETH_ABI, ERC20_ABI, UNISWAP_ROUTER_ABI } from "./abis.js";

// ────────────────────────────────────────────────────────────────────────────
//  Config
// ────────────────────────────────────────────────────────────────────────────

const SEPOLIA_CHAIN_ID_HEX = "0xaa36a7"; // 11155111
const SEPOLIA_CHAIN_ID     = 11155111n;

let config = null;       // Loaded from deployment.sepolia.json
let provider = null;     // ethers.BrowserProvider (read + write, MetaMask)
let signer = null;       // ethers.Signer (connected account)
let vault = null;        // ethers.Contract, read-only
let vaultWithSigner = null; // ethers.Contract, for transactions
let userAddress = null;  // Currently-connected EOA
let isOwner = false;     // Is connected address the vault owner?
let activeVaultAddress = null; // The vault address actually in use

// ────────────────────────────────────────────────────────────────────────────
//  DOM helpers
// ────────────────────────────────────────────────────────────────────────────

const $ = (id) => document.getElementById(id);

function show(id) { $(id).hidden = false; }
function hide(id) { $(id).hidden = true; }

function log(message, level = "info") {
  const logEl = $("log");
  if (!logEl) return;
  const time = new Date().toLocaleTimeString();
  const entry = document.createElement("div");
  entry.className = "log-entry";
  entry.innerHTML = `<span class="log-time">${time}</span><span class="log-${level}">${message}</span>`;
  logEl.insertBefore(entry, logEl.firstChild);
}

function toast(message, type = "info") {
  const t = document.createElement("div");
  t.className = `toast toast-${type}`;
  t.textContent = message;
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 4500);
}

function shorten(addr) {
  if (!addr) return "—";
  return addr.slice(0, 6) + "…" + addr.slice(-4);
}

function formatSeconds(sec) {
  sec = Number(sec);
  if (sec < 60)         return `${sec}s`;
  if (sec < 3600)       return `${Math.round(sec / 60)}m`;
  if (sec < 86400)      return `${(sec / 3600).toFixed(1)}h`;
  return `${(sec / 86400).toFixed(1)}d`;
}

function etherscan(path) {
  return `https://sepolia.etherscan.io/${path}`;
}

// ────────────────────────────────────────────────────────────────────────────
//  Custom vault address
// ────────────────────────────────────────────────────────────────────────────

function getActiveVaultAddress() {
  const customInput = $("custom-vault");
  const statusEl = $("custom-vault-status");
  if (!customInput) return config.vault;

  const value = customInput.value.trim();

  if (!value) {
    // Empty — use default
    statusEl.textContent = "";
    customInput.style.borderColor = "";
    return config.vault;
  }

  if (ethers.isAddress(value)) {
    // Valid address — use custom
    statusEl.textContent = "✓ Custom vault";
    statusEl.style.color = "var(--success)";
    customInput.style.borderColor = "var(--success)";
    return ethers.getAddress(value); // checksummed
  }

  // Invalid
  statusEl.textContent = "✗ Invalid address";
  statusEl.style.color = "var(--danger)";
  customInput.style.borderColor = "var(--danger)";
  return null;
}

// ────────────────────────────────────────────────────────────────────────────
//  Bootstrap
// ────────────────────────────────────────────────────────────────────────────

async function loadConfig() {
  const res = await fetch("./deployment.sepolia.json");
  if (!res.ok) throw new Error(`Failed to load deployment config: ${res.status}`);
  config = await res.json();
  if (config.vault === ethers.ZeroAddress || !config.vault) {
    throw new Error("Vault address not set in deployment.sepolia.json. Deploy the vault first with `forge script script/Deploy.s.sol`.");
  }
  log(`Config loaded. Default vault: ${config.vault}`, "info");
}

async function connect() {
  if (!window.ethereum) {
    toast("MetaMask not detected. Install it from metamask.io", "error");
    return;
  }

  // Resolve vault address (custom or default)
  activeVaultAddress = getActiveVaultAddress();
  if (!activeVaultAddress) {
    toast("Invalid custom vault address", "error");
    return;
  }

  const isCustom = activeVaultAddress.toLowerCase() !== config.vault.toLowerCase();

  try {
    // Request accounts
    const accounts = await window.ethereum.request({ method: "eth_requestAccounts" });
    if (!accounts.length) {
      toast("No account selected", "error");
      return;
    }

    // Ensure Sepolia
    const chainId = await window.ethereum.request({ method: "eth_chainId" });
    if (chainId !== SEPOLIA_CHAIN_ID_HEX) {
      try {
        await window.ethereum.request({
          method: "wallet_switchEthereumChain",
          params: [{ chainId: SEPOLIA_CHAIN_ID_HEX }]
        });
      } catch (err) {
        toast("Please switch MetaMask to Sepolia", "error");
        return;
      }
    }

    provider = new ethers.BrowserProvider(window.ethereum);
    signer   = await provider.getSigner();
    userAddress = await signer.getAddress();

    vault           = new ethers.Contract(activeVaultAddress, VAULT_ABI, provider);
    vaultWithSigner = new ethers.Contract(activeVaultAddress, VAULT_ABI, signer);

    // Verify the contract exists by calling a view function
    try {
      await vault.owner();
    } catch (err) {
      toast("No vault found at this address. Is it deployed on Sepolia?", "error");
      log(`No vault contract at ${shorten(activeVaultAddress)}. Check the address.`, "error");
      return;
    }

    // Check ownership
    const vaultOwner = await vault.owner();
    isOwner = vaultOwner.toLowerCase() === userAddress.toLowerCase();

    renderConnection(vaultOwner, isCustom);
    await refreshAll();
    subscribeToEvents();

    // Disable custom vault input after connecting (reconnect = reload)
    const customInput = $("custom-vault");
    if (customInput) customInput.disabled = true;

    // React to account/chain changes
    window.ethereum.on("accountsChanged", () => location.reload());
    window.ethereum.on("chainChanged",    () => location.reload());

    log(`Connected as ${shorten(userAddress)}${isOwner ? " (vault owner)" : " (not owner)"}${isCustom ? " — using custom vault" : ""}`, "success");

  } catch (err) {
    console.error(err);
    toast(err.message || "Connection failed", "error");
    log(`Connection failed: ${err.message}`, "error");
  }
}

function renderConnection(vaultOwner, isCustom) {
  $("connect-btn").textContent = shorten(userAddress);
  $("connect-btn").disabled = true;

  const customLabel = isCustom ? ` (custom vault <strong>${shorten(activeVaultAddress)}</strong>)` : "";

  const banner = isOwner
    ? `<p>✅ Connected as <strong>${shorten(userAddress)}</strong> — vault owner${customLabel}. All actions enabled.</p>`
    : `<p>⚠️ Connected as <strong>${shorten(userAddress)}</strong>. This is <em>not</em> the vault owner (${shorten(vaultOwner)})${customLabel}. Only deposits are available.</p>`;

  $("wallet-status").innerHTML = banner;

  show("overview-section");
  show("actions-section");
  show("log-section");

  // Disable owner-only buttons if not owner
  if (!isOwner) {
    for (const id of ["hotspend-btn", "coldwithdraw-btn", "swap-btn"]) {
      $(id).disabled = true;
      $(id).title = "Owner only — connect with the vault owner address";
    }
  }
}

// ────────────────────────────────────────────────────────────────────────────
//  State refresh
// ────────────────────────────────────────────────────────────────────────────

async function refreshAll() {
  try {
    const [total, hot, cold, limit, epoch, spent, timelock, threshold,
           guardianCount, paused, pendingCount, vaultOwner, nextId] = await Promise.all([
      vault.totalBalance(),
      vault.hotBalance(),
      vault.coldBalance(),
      vault.spendingLimit(),
      vault.epochDuration(),
      vault.spentInCurrentEpoch(),
      vault.timelockDuration(),
      vault.multisigThreshold(),
      vault.guardianCount(),
      vault.isPaused(),
      vault.pendingWithdrawalCount(),
      vault.owner(),
      vault.nextRequestId()
    ]);

    $("vault-total").textContent = ethers.formatEther(total) + " ETH";
    $("vault-hot").textContent   = ethers.formatEther(hot) + " ETH";
    $("vault-cold").textContent  = ethers.formatEther(cold) + " ETH";
    $("vault-spent").textContent = ethers.formatEther(spent) + " ETH";
    $("vault-limit").textContent = ethers.formatEther(limit) + " ETH";
    $("vault-epoch").textContent = formatSeconds(epoch);
    $("timelock-duration").textContent = formatSeconds(timelock);

    const linkEl = $("vault-address");
    linkEl.href = etherscan(`address/${activeVaultAddress}`);
    linkEl.textContent = shorten(activeVaultAddress);

    $("vault-owner").innerHTML = `<a href="${etherscan(`address/${vaultOwner}`)}" target="_blank">${shorten(vaultOwner)}</a>`;
    $("vault-guardians").textContent = guardianCount.toString();
    $("vault-threshold").textContent = threshold.toString();
    $("vault-paused").textContent = paused ? "YES" : "no";
    $("vault-paused").style.color = paused ? "var(--danger)" : "var(--text)";
    $("vault-pending").textContent = pendingCount.toString();

    await refreshPendingWithdrawals(Number(nextId));
  } catch (err) {
    console.error(err);
    log(`Refresh failed: ${err.message}`, "error");
  }
}

async function refreshPendingWithdrawals(nextId) {
  const container = $("pending-list");
  if (nextId === 0) {
    container.innerHTML = `<p class="muted">No withdrawals have been requested yet.</p>`;
    return;
  }

  const items = [];
  for (let i = 0; i < nextId; i++) {
    const req = await vault.getWithdrawalRequest(i);
    if (req.executed || req.cancelled) continue;

    const unlockTime = Number(req.unlockTime);
    const now = Math.floor(Date.now() / 1000);
    const remaining = unlockTime - now;
    const approvals = Number(req.approvalCount);
    const threshold = Number(await vault.multisigThreshold());

    const unlocked = remaining <= 0 || approvals >= threshold;
    const statusText = unlocked
      ? `<span class="unlock-ready">✓ Unlocked</span>`
      : `<span class="unlock-waiting">Unlocks in ${formatSeconds(remaining)}</span>`;

    const approvalsText = approvals > 0
      ? ` · <strong>${approvals}/${threshold}</strong> multisig`
      : "";

    items.push(`
      <div class="pending-item">
        <div class="pending-item-id">#${i}</div>
        <div class="pending-item-info">
          <strong>${ethers.formatEther(req.amount)} ETH</strong> to
          <strong>${shorten(req.to)}</strong><br/>
          ${statusText}${approvalsText}
        </div>
        <div class="pending-item-actions">
          ${unlocked && isOwner
            ? `<button class="primary small" data-execute="${i}">Execute</button>`
            : ""}
          ${isOwner
            ? `<button class="danger small" data-cancel="${i}">Cancel</button>`
            : ""}
        </div>
      </div>
    `);
  }

  container.innerHTML = items.length
    ? items.join("")
    : `<p class="muted">No pending withdrawals.</p>`;

  container.querySelectorAll("[data-execute]").forEach(btn =>
    btn.addEventListener("click", () => executeWithdrawal(btn.dataset.execute)));
  container.querySelectorAll("[data-cancel]").forEach(btn =>
    btn.addEventListener("click", () => cancelWithdrawal(btn.dataset.cancel)));
}

// ────────────────────────────────────────────────────────────────────────────
//  Actions
// ────────────────────────────────────────────────────────────────────────────

async function sendTx(fn, label) {
  try {
    log(`${label}: submitting…`, "info");
    const tx = await fn();
    log(`${label}: tx <a href="${etherscan(`tx/${tx.hash}`)}" target="_blank">${shorten(tx.hash)}</a>`, "info");
    const receipt = await tx.wait();
    log(`${label}: confirmed in block ${receipt.blockNumber}`, "success");
    toast(`${label} confirmed`, "success");
    await refreshAll();
    return receipt;
  } catch (err) {
    console.error(err);
    const msg = err.shortMessage || err.reason || err.message || "Transaction failed";
    log(`${label}: ${msg}`, "error");
    toast(`${label}: ${msg}`, "error");
    throw err;
  }
}

async function deposit() {
  const amount = $("deposit-amount").value;
  if (!amount || Number(amount) <= 0) return toast("Enter a positive amount", "error");

  await sendTx(
    () => vaultWithSigner.deposit({ value: ethers.parseEther(amount) }),
    `Deposit ${amount} ETH`
  );
}

async function hotSpend() {
  const to = $("hotspend-to").value.trim();
  const amount = $("hotspend-amount").value;
  if (!ethers.isAddress(to)) return toast("Invalid recipient address", "error");
  if (!amount || Number(amount) <= 0) return toast("Enter a positive amount", "error");

  await sendTx(
    () => vaultWithSigner.hotSpend(to, ethers.parseEther(amount)),
    `Hot spend ${amount} ETH → ${shorten(to)}`
  );
}

async function requestWithdrawal() {
  const to = $("coldwithdraw-to").value.trim();
  const amount = $("coldwithdraw-amount").value;
  if (!ethers.isAddress(to)) return toast("Invalid recipient address", "error");
  if (!amount || Number(amount) <= 0) return toast("Enter a positive amount", "error");

  await sendTx(
    () => vaultWithSigner.requestWithdrawal(to, ethers.parseEther(amount)),
    `Request withdrawal ${amount} ETH → ${shorten(to)}`
  );
}

async function executeWithdrawal(requestId) {
  await sendTx(
    () => vaultWithSigner.executeWithdrawal(requestId),
    `Execute withdrawal #${requestId}`
  );
}

async function cancelWithdrawal(requestId) {
  await sendTx(
    () => vaultWithSigner.cancelWithdrawal(requestId),
    `Cancel withdrawal #${requestId}`
  );
}

// ────────────────────────────────────────────────────────────────────────────
//  DeFi: Uniswap V3 swap (the flagship demo)
// ────────────────────────────────────────────────────────────────────────────

async function swapOnUniswap() {
  const amountStr = $("swap-amount").value;
  if (!amountStr || Number(amountStr) <= 0) return toast("Enter a positive amount", "error");

  const amountWei = ethers.parseEther(amountStr);
  const weth      = config.weth;
  const usdc      = config.usdc;
  const router    = config.uniswapRouter;

  // Step 1: Check WETH whitelist
  const wethWhitelisted = await vault.isWhitelisted(weth);
  if (!wethWhitelisted) {
    log("WETH is not whitelisted yet. Whitelist requires timelock. See docs for one-time setup. Aborting swap.", "error");
    toast("WETH not whitelisted — see docs for setup", "error");
    return;
  }

  // Step 2: Same for router
  const routerWhitelisted = await vault.isWhitelisted(router);
  if (!routerWhitelisted) {
    log("Uniswap router is not whitelisted yet. See docs for one-time setup. Aborting swap.", "error");
    toast("Router not whitelisted — see docs for setup", "error");
    return;
  }

  // Step 3: Wrap ETH into WETH
  log(`Step 1/3: wrap ${amountStr} ETH → WETH via execute()`, "info");
  const wethIface = new ethers.Interface(WETH_ABI);
  const depositData = wethIface.encodeFunctionData("deposit", []);
  await sendTx(
    () => vaultWithSigner.execute(weth, amountWei, depositData),
    `Wrap ${amountStr} ETH → WETH`
  );

  // Step 4: Approve router to spend WETH
  log("Step 2/3: approve router to spend WETH", "info");
  await sendTx(
    () => vaultWithSigner.approveToken(weth, router, amountWei),
    `Approve router ${amountStr} WETH`
  );

  // Step 5: Execute the swap
  log("Step 3/3: swap WETH → USDC via Uniswap V3", "info");
  const routerIface = new ethers.Interface(UNISWAP_ROUTER_ABI);
  const swapData = routerIface.encodeFunctionData("exactInputSingle", [{
    tokenIn:           weth,
    tokenOut:          usdc,
    fee:               3000,
    recipient:         activeVaultAddress,
    amountIn:          amountWei,
    amountOutMinimum:  0,
    sqrtPriceLimitX96: 0
  }]);

  try {
    await sendTx(
      () => vaultWithSigner.execute(router, 0, swapData),
      `Swap ${amountStr} WETH → USDC`
    );

    const usdcContract = new ethers.Contract(usdc, ERC20_ABI, provider);
    const usdcBalance = await usdcContract.balanceOf(activeVaultAddress);
    const decimals = await usdcContract.decimals();
    log(`✨ Vault now holds ${ethers.formatUnits(usdcBalance, decimals)} USDC`, "success");
  } catch (err) {
    log("Swap failed — the Uniswap pool on Sepolia may not have liquidity. The mechanism is proven by the wrap step.", "error");
  }
}

// ────────────────────────────────────────────────────────────────────────────
//  Event subscription
// ────────────────────────────────────────────────────────────────────────────

function subscribeToEvents() {
  vault.on("Deposited",           (sender, amount) => log(`Event: Deposited ${ethers.formatEther(amount)} ETH from ${shorten(sender)}`, "event"));
  vault.on("HotSpend",            (to, amount)     => log(`Event: HotSpend ${ethers.formatEther(amount)} ETH → ${shorten(to)}`, "event"));
  vault.on("WithdrawalRequested", (id, token, to, amount, unlock) => log(`Event: WithdrawalRequested #${id} — ${ethers.formatEther(amount)} ETH → ${shorten(to)}, unlocks ${new Date(Number(unlock) * 1000).toLocaleTimeString()}`, "event"));
  vault.on("WithdrawalExecuted",  (id) => log(`Event: WithdrawalExecuted #${id}`, "event"));
  vault.on("WithdrawalCancelled", (id, by) => log(`Event: WithdrawalCancelled #${id} by ${shorten(by)}`, "event"));
  vault.on("WithdrawalApprovedByMultisig", (id) => log(`Event: WithdrawalApprovedByMultisig #${id}`, "event"));
  vault.on("TargetWhitelisted",   (target, allowed) => log(`Event: TargetWhitelisted ${shorten(target)} = ${allowed}`, "event"));
  vault.on("Executed",            (target, value, data, result) => log(`Event: Executed → ${shorten(target)}, value ${ethers.formatEther(value)} ETH`, "event"));
  vault.on("VaultPaused",         (by, until) => log(`Event: VaultPaused by ${shorten(by)} until ${new Date(Number(until) * 1000).toLocaleTimeString()}`, "event"));
  vault.on("VaultUnpaused",       (by) => log(`Event: VaultUnpaused by ${shorten(by)}`, "event"));
}

// ────────────────────────────────────────────────────────────────────────────
//  Wire up
// ────────────────────────────────────────────────────────────────────────────

async function init() {
  try {
    await loadConfig();
  } catch (err) {
    $("wallet-status").innerHTML = `<p style="color: var(--danger);">${err.message}</p>`;
    return;
  }

  // Live validation on custom vault input
  const customInput = $("custom-vault");
  if (customInput) {
    customInput.addEventListener("input", getActiveVaultAddress);
  }

  $("connect-btn").addEventListener("click",     connect);
  $("deposit-btn").addEventListener("click",     deposit);
  $("hotspend-btn").addEventListener("click",    hotSpend);
  $("coldwithdraw-btn").addEventListener("click", requestWithdrawal);
  $("swap-btn").addEventListener("click",        swapOnUniswap);
  $("clear-log").addEventListener("click",       () => $("log").innerHTML = "");
}

init();
