// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentIdentityNFT} from "../src/AgentIdentityNFT.sol";

contract AgentIdentityNFTTest is Test {
    AgentIdentityNFT internal nft;
    address internal admin = address(0xA11CE);
    address internal writer = address(0xB0B);
    address internal alice = address(0xA1);
    address internal bob = address(0xB1);

    function setUp() public {
        nft = new AgentIdentityNFT(admin);
        bytes32 writerRole = nft.METADATA_WRITER_ROLE();
        vm.prank(admin);
        nft.grantRole(writerRole, writer);
    }

    function test_register_mints_and_assigns_uri() public {
        vm.prank(alice);
        uint256 id = nft.register("ipfs://QmFoo");

        assertEq(id, 0);
        assertEq(nft.ownerOf(0), alice);
        assertEq(nft.agentURI(0), "ipfs://QmFoo");
        assertEq(nft.tokenURI(0), "ipfs://QmFoo");
        assertEq(nft.nextAgentId(), 1);
    }

    function test_register_multiple_increments_id() public {
        vm.prank(alice);
        uint256 a = nft.register("ipfs://A");
        vm.prank(bob);
        uint256 b = nft.register("ipfs://B");
        assertEq(a, 0);
        assertEq(b, 1);
        assertEq(nft.ownerOf(a), alice);
        assertEq(nft.ownerOf(b), bob);
    }

    function test_setAgentURI_by_owner() public {
        vm.prank(alice);
        uint256 id = nft.register("ipfs://old");
        vm.prank(alice);
        nft.setAgentURI(id, "ipfs://new");
        assertEq(nft.agentURI(id), "ipfs://new");
    }

    function test_setAgentURI_reverts_for_nonowner() public {
        vm.prank(alice);
        uint256 id = nft.register("ipfs://A");
        vm.prank(bob);
        vm.expectRevert(bytes("AGENT: not owner"));
        nft.setAgentURI(id, "ipfs://hack");
    }

    function test_setMetadata_by_writer_updates_store() public {
        vm.prank(alice);
        uint256 id = nft.register("ipfs://A");

        bytes memory sortinoBytes = abi.encode(int256(1_500_000));
        vm.prank(writer);
        nft.setMetadata(id, "sortino_score", sortinoBytes);
        assertEq(nft.getMetadata(id, "sortino_score"), sortinoBytes);
    }

    function test_setMetadata_reverts_without_role() public {
        vm.prank(alice);
        uint256 id = nft.register("ipfs://A");
        vm.prank(bob);
        vm.expectRevert();
        nft.setMetadata(id, "foo", abi.encode(uint256(1)));
    }

    function test_setMetadata_reverts_for_nonexistent_agent() public {
        vm.prank(writer);
        vm.expectRevert(bytes("AGENT: nonexistent"));
        nft.setMetadata(999, "foo", abi.encode(uint256(1)));
    }

    function test_supportsInterface_for_ERC721_and_AccessControl() public view {
        // ERC721 = 0x80ac58cd
        assertTrue(nft.supportsInterface(0x80ac58cd));
        // AccessControl = 0x7965db0b
        assertTrue(nft.supportsInterface(0x7965db0b));
    }

    /// @notice Registration is OPEN BY DESIGN (EIP-8004 Identity Registry semantics):
    ///         any address may register, and the URI is self-asserted / untrusted. The
    ///         agentId binding only proves *some* address minted it — it is NOT an
    ///         endorsement of the manifest. This test documents that contract behavior:
    ///         two distinct addresses can register the SAME URI and both succeed.
    function test_registration_is_permissionless_and_uri_is_untrusted() public {
        // No role grant to alice/bob — registration needs none.
        vm.prank(alice);
        uint256 a = nft.register("ipfs://same-manifest");
        vm.prank(bob);
        uint256 b = nft.register("ipfs://same-manifest");

        assertEq(a, 0);
        assertEq(b, 1);
        // Identical (untrusted) URIs are allowed; the binding is per-owner, not unique.
        assertEq(nft.agentURI(a), nft.agentURI(b));
        assertEq(nft.ownerOf(a), alice);
        assertEq(nft.ownerOf(b), bob);
    }

    /// @notice Privileged reputation writes stay role-gated even for the token owner:
    ///         minting an identity does NOT grant the right to write trusted metadata.
    function test_owner_cannot_self_write_metadata_without_role() public {
        vm.prank(alice);
        uint256 id = nft.register("ipfs://A");

        // Alice owns the token but lacks METADATA_WRITER_ROLE → setMetadata reverts.
        vm.prank(alice);
        vm.expectRevert();
        nft.setMetadata(id, "sortino_score", abi.encode(int256(1_500_000)));
    }
}
