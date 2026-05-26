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
}
