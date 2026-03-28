// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../src/HMTNFT.sol"; 
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// 🟢 OFFLINE DUMMY USDT FOR TESTING
contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract HMTNFTShowcaseTest is Test {
    HMT_NFT public nft;
    MockUSDT public usdt;

    address public ownerWallet = address(0x100);
    address public miningContract = address(0x200);
    address public testUser = address(0x300);

    function setUp() public {
        usdt = new MockUSDT();
        nft = new HMT_NFT(address(usdt), ownerWallet);
        nft.setMiningContract(miningContract);
    }

    function _usd(uint256 amount) internal pure returns (string memory) {
        return string(abi.encodePacked("$", vm.toString(amount / 1e18)));
    }

    // ==========================================
    // 🟢 SHOWCASE 3: SCARCITY CAPS & HARD LIMITS
    // ==========================================
    function test_Client_Showcase_NFT_3_ScarcityCaps() public {
        console.log("\n========================================================");
        console.log(">> SHOWCASE 3: SCARCITY ENFORCEMENT (TIER 7 MAX 250)");
        console.log(">> EXPECTATION: The contract physical blocks the 251st mint.");
        console.log("========================================================\n");

        console.log("[SYSTEM] Minting exactly 250 Tier 7 NFTs ($100,000 each)...");
        
        // Give the test user $26 Million USDT to afford 260 NFTs
        usdt.mint(testUser, 26_000_000 * 1e18); 
        
        vm.startPrank(testUser);
        usdt.approve(address(nft), 26_000_000 * 1e18);

        // Buy 250 NFTs to perfectly hit the new cap
        for(uint i = 0; i < 250; i++) {
            nft.buyNFT(7);
        }
        vm.stopPrank();

        // Destructure the new 4-item tuple from the updated struct
        (,, uint256 minted,) = nft.tiers(7);
        console.log("   -> Tier 7 NFTs successfully minted: ", minted);
        console.log("   -> Total Supply Cap Reached!");

        console.log("\n[ACTION] A late investor tries to buy the 251st Tier 7 NFT...");
        
        vm.startPrank(testUser);
        vm.expectRevert("Tier completely sold out");
        nft.buyNFT(7);
        vm.stopPrank();

        console.log("\n[CLIENT VERIFICATION] Smart Contract successfully blocked the");
        console.log("transaction. Scarcity economics are actively protected!");
        console.log("========================================================\n");
    }
}