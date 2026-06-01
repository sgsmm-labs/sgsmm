// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title AgentIdentityNFT
 * @notice Minimal ERC-8004-compatible Identity Registry for autonomous AI agents.
 * @dev Implements the Identity Registry portion of EIP-8004 (Draft) used by the
 *      Mantle Turing Test Hackathon. Each agent mints one NFT representing its
 *      on-chain identity; mutable metadata stores live Sortino + vault NAV.
 *
 *      Compliance subset:
 *      - register(agentURI) → mints NFT
 *      - setAgentURI(agentId, newURI)
 *      - setMetadata(agentId, key, value)
 *      - getMetadata(agentId, key) → bytes
 *
 *      Skipped (out of hackathon scope):
 *      - setAgentWallet via EIP-712 signature (use direct transfer or upgrade later)
 *      - Reputation Registry (separate contract, optional)
 *      - Validation Registry (separate contract, optional)
 */
contract AgentIdentityNFT is ERC721, AccessControl {
    bytes32 public constant METADATA_WRITER_ROLE = keccak256("METADATA_WRITER_ROLE");

    /// @notice Monotonic counter for agent IDs.
    uint256 public nextAgentId;

    /// @notice Per-agent metadata key → value bytes.
    mapping(uint256 => mapping(string => bytes)) private _metadata;

    /// @notice Per-agent canonical URI (e.g., IPFS reference to agent manifest).
    mapping(uint256 => string) private _agentURIs;

    event AgentRegistered(uint256 indexed agentId, address indexed owner, string agentURI);
    event AgentURIUpdated(uint256 indexed agentId, string newURI);
    event MetadataUpdated(uint256 indexed agentId, string key, bytes value);

    constructor(address admin) ERC721("SGSMM Agent Identity", "SGSMM-AGENT") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Mint a new agent identity NFT to caller, with a self-asserted URI.
    /// @dev OPEN REGISTRATION BY DESIGN (EIP-8004 Identity Registry semantics):
    ///      anyone may register and any `uri` is caller-supplied and therefore
    ///      UNTRUSTED. The returned `agentId` only proves that *some* address
    ///      minted it — it is NOT an endorsement, KYC, or proof the manifest is
    ///      authentic. Consumers (frontend, indexers, other contracts) MUST treat
    ///      both the agentId binding and the URI/metadata as unverified input and
    ///      apply their own allow-listing / signature checks before trusting an
    ///      agent. Privileged on-chain reputation writes are separately gated
    ///      behind METADATA_WRITER_ROLE via {setMetadata}; only `register`,
    ///      `setAgentURI`, and the ERC-721 ownership surface are permissionless.
    function register(string calldata uri) external returns (uint256 agentId) {
        agentId = nextAgentId;
        unchecked {
            nextAgentId = agentId + 1;
        }
        _safeMint(msg.sender, agentId);
        _agentURIs[agentId] = uri;
        emit AgentRegistered(agentId, msg.sender, uri);
    }

    /// @notice Update the agent URI (only NFT owner).
    function setAgentURI(uint256 agentId, string calldata newUri) external {
        require(_ownerOf(agentId) == msg.sender, "AGENT: not owner");
        _agentURIs[agentId] = newUri;
        emit AgentURIUpdated(agentId, newUri);
    }

    /// @notice Read agent URI.
    function agentURI(uint256 agentId) external view returns (string memory) {
        return _agentURIs[agentId];
    }

    /// @notice Authorized writer updates per-agent metadata (e.g., Sortino, NAV).
    function setMetadata(uint256 agentId, string calldata key, bytes calldata value)
        external
        onlyRole(METADATA_WRITER_ROLE)
    {
        require(_ownerOf(agentId) != address(0), "AGENT: nonexistent");
        _metadata[agentId][key] = value;
        emit MetadataUpdated(agentId, key, value);
    }

    /// @notice Read per-agent metadata.
    function getMetadata(uint256 agentId, string calldata key) external view returns (bytes memory) {
        return _metadata[agentId][key];
    }

    /// @notice tokenURI returns the canonical agent URI (overrides ERC721 default).
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _agentURIs[tokenId];
    }

    /// @inheritdoc AccessControl
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
