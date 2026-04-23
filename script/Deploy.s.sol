// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {CoercionResistantVault, IEntryPoint} from "../src/CoercionResistantVault.sol";

/**
 * @title Deploy
 * @notice Deployment script for the Coercion-Resistant Vault on Sepolia.
 *
 *         Reads configuration from environment variables (see .env.example):
 *           DEPLOYER_PRIVATE_KEY  — pays for the deploy tx
 *           VAULT_OWNER           — the EOA that will own the vault
 *           VAULT_SPENDING_LIMIT  — per-epoch hot spend cap (wei)
 *           VAULT_EPOCH_DURATION  — hot spend epoch length (seconds)
 *           VAULT_TIMELOCK_DURATION — cold vault delay (seconds)
 *           VAULT_MULTISIG_THRESHOLD — guardian approvals for instant unlock
 *
 *         Guardians are hardcoded to 3 publicly-known test addresses (Anvil
 *         accounts 1, 2, 3). This is INTENTIONAL: it lets anyone reproduce
 *         guardian actions via `cast send --private-key <known-test-key>`
 *         for demo/simulation purposes on testnet. NEVER deploy this script
 *         to mainnet without replacing the guardian addresses with real
 *         guardian EOAs held securely.
 *
 *         Usage:
 *           source .env
 *           forge script script/Deploy.s.sol:Deploy \
 *             --rpc-url $SEPOLIA_RPC_URL \
 *             --broadcast \
 *             --verify \
 *             --etherscan-api-key $ETHERSCAN_API_KEY
 */
contract Deploy is Script {

    // Canonical ERC-4337 EntryPoint v0.7 (same address on all chains)
    address internal constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    // Well-known Anvil test accounts (1, 2, 3) — PUBLIC keys, testnet-only.
    // Corresponding private keys (public, widely known — never use on mainnet):
    //   guardian1: 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
    //   guardian2: 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
    //   guardian3: 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6
    address internal constant GUARDIAN_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address internal constant GUARDIAN_2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
    address internal constant GUARDIAN_3 = 0x90F79bf6EB2c4f870365E785982E1f101E93b906;

    function run() external returns (CoercionResistantVault vault) {
        // --- Load config from env ---
        uint256 deployerKey      = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address vaultOwner       = vm.envAddress("VAULT_OWNER");
        uint256 spendingLimit    = vm.envUint("VAULT_SPENDING_LIMIT");
        uint256 epochDuration    = vm.envUint("VAULT_EPOCH_DURATION");
        uint256 timelockDuration = vm.envUint("VAULT_TIMELOCK_DURATION");
        uint256 multisigThresh   = vm.envUint("VAULT_MULTISIG_THRESHOLD");

        address[] memory guardians = new address[](3);
        guardians[0] = GUARDIAN_1;
        guardians[1] = GUARDIAN_2;
        guardians[2] = GUARDIAN_3;

        // --- Log deployment plan ---
        console2.log("==========================================");
        console2.log("CoercionResistantVault deployment");
        console2.log("==========================================");
        console2.log("EntryPoint:      ", ENTRY_POINT_V07);
        console2.log("Vault owner:     ", vaultOwner);
        console2.log("Guardian 1:      ", GUARDIAN_1);
        console2.log("Guardian 2:      ", GUARDIAN_2);
        console2.log("Guardian 3:      ", GUARDIAN_3);
        console2.log("Spending limit:  ", spendingLimit, "wei");
        console2.log("Epoch duration:  ", epochDuration, "seconds");
        console2.log("Timelock:        ", timelockDuration, "seconds");
        console2.log("Multisig thresh: ", multisigThresh);
        console2.log("Deployer addr:   ", vm.addr(deployerKey));
        console2.log("==========================================");

        // --- Broadcast ---
        vm.startBroadcast(deployerKey);

        vault = new CoercionResistantVault(
            IEntryPoint(ENTRY_POINT_V07),
            vaultOwner,
            spendingLimit,
            epochDuration,
            timelockDuration,
            guardians,
            multisigThresh
        );

        vm.stopBroadcast();

        console2.log("");
        console2.log("Vault deployed at:", address(vault));
        console2.log("");
        console2.log("Next steps:");
        console2.log("1. Etherscan:    https://sepolia.etherscan.io/address/", address(vault));
        console2.log("2. Write the address to demo/deployment.sepolia.json");
        console2.log("3. Fund the vault: send Sepolia ETH to its address");
        console2.log("4. Open demo/index.html and connect MetaMask");
    }
}
