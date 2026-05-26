// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {SGSMMVault} from "../src/SGSMMVault.sol";
import {DecisionLog} from "../src/DecisionLog.sol";
import {AgentIdentityNFT} from "../src/AgentIdentityNFT.sol";
import {MirrorExecutor} from "../src/MirrorExecutor.sol";
import {MockUSDY} from "../test/mocks/MockUSDY.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Deploy
 * @notice One-shot deploy script for SGSMM on Mantle Sepolia.
 *
 * Usage:
 *   forge script script/Deploy.s.sol:Deploy \
 *       --rpc-url $MANTLE_SEPOLIA_RPC \
 *       --broadcast \
 *       --verify \
 *       --etherscan-api-key $MANTLESCAN_API_KEY \
 *       --private-key $DEPLOYER_PRIVATE_KEY
 *
 * After deploy, copy addresses into agent/.env and frontend/.env.local.
 */
contract Deploy is Script {
    function run() external {
        address deployer = msg.sender;
        address agentOperator = vm.envOr("AGENT_OPERATOR_ADDRESS", deployer);
        string memory agentManifestUri = vm.envOr(
            "AGENT_MANIFEST_URI", string("ipfs://placeholder-sgsmm-manifest")
        );

        vm.startBroadcast();

        // 1. Mock USDY (testnet only — replace with real USDY address on mainnet)
        MockUSDY usdy = new MockUSDY();
        console2.log("MockUSDY:", address(usdy));

        // 2. DecisionLog
        DecisionLog decisionLog = new DecisionLog(deployer);
        console2.log("DecisionLog:", address(decisionLog));

        // 3. AgentIdentityNFT
        AgentIdentityNFT identity = new AgentIdentityNFT(deployer);
        console2.log("AgentIdentityNFT:", address(identity));

        // 4. Register the SGSMM agent (deployer is initial owner)
        uint256 agentId = identity.register(agentManifestUri);
        console2.log("Agent ID:", agentId);

        // 5. SGSMM Vault (asset = MockUSDY)
        SGSMMVault vault = new SGSMMVault(IERC20(address(usdy)), deployer);
        console2.log("SGSMMVault:", address(vault));

        // 6. MirrorExecutor
        MirrorExecutor executor = new MirrorExecutor(
            vault, decisionLog, identity, agentId, deployer, agentOperator
        );
        console2.log("MirrorExecutor:", address(executor));

        // 7. Role wiring
        vault.grantRole(vault.EXECUTOR_ROLE(), address(executor));
        decisionLog.grantRole(decisionLog.LOGGER_ROLE(), address(executor));
        identity.grantRole(identity.METADATA_WRITER_ROLE(), address(executor));

        vm.stopBroadcast();

        console2.log("---");
        console2.log("Deploy summary:");
        console2.log("  USDY (test):     ", address(usdy));
        console2.log("  DecisionLog:     ", address(decisionLog));
        console2.log("  AgentIdentity:   ", address(identity));
        console2.log("  AgentId:         ", agentId);
        console2.log("  Vault:           ", address(vault));
        console2.log("  MirrorExecutor:  ", address(executor));
        console2.log("  Agent Operator:  ", agentOperator);
    }
}
