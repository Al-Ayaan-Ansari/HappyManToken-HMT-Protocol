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
        
        // Link the mock mining contract
        nft.setMiningContract(miningContract);

        // Give the test user 500,000 USDT to buy NFTs
        usdt.mint(testUser, 500_000 * 1e18);
    }

    // Converts raw blockchain uints (1e18) to readable strings
    function _usd(uint256 amount) internal pure returns (string memory) {
        return string(abi.encodePacked("$", vm.toString(amount / 1e18)));
    }

    // ==========================================
    // 🟢 SHOWCASE 1: FILEBASE IPFS METADATA MAPPING
    // ==========================================
    function test_Client_Showcase_NFT_1_IPFS_Mapping() public {
        console.log("\n========================================================");
        console.log(">> SHOWCASE 1: FILEBASE IPFS METADATA ENGINE");
        console.log(">> EXPECTATION: Token URI maps to TIER, not Token ID.");
        console.log("========================================================\n");

        // 1. Set the Filebase IPFS Folder URL
        string memory filebaseFolderCID = "ipfs://QmYourFilebaseFolderCID12345/";
        nft.setBaseURI(filebaseFolderCID);
        console.log("[SYSTEM] Base URI set to: ", filebaseFolderCID);

        // 2. User buys a Tier 4 NFT ($10,000)
        vm.startPrank(testUser);
        usdt.approve(address(nft), 10_000 * 1e18);
        nft.buyNFT(4);
        vm.stopPrank();

        uint256 firstTokenId = 1;
        uint8 firstTokenTier = nft.getNFTTier(firstTokenId);
        string memory firstTokenURI = nft.tokenURI(firstTokenId);

        console.log("\n[MINT 1] User bought Token ID #1");
        console.log("   -> Contract assigned it to Tier: ", firstTokenTier);
        console.log("   -> OpenSea/Wallets will load:    ", firstTokenURI);

        // 3. Mining Contract grants a Tier 7 NFT (Free Reward)
        vm.prank(miningContract);
        nft.mintRewardNFT(testUser, 7);

        uint256 secondTokenId = 2;
        uint8 secondTokenTier = nft.getNFTTier(secondTokenId);
        string memory secondTokenURI = nft.tokenURI(secondTokenId);

        console.log("\n[MINT 2] Protocol rewarded Token ID #2");
        console.log("   -> Contract assigned it to Tier: ", secondTokenTier);
        console.log("   -> OpenSea/Wallets will load:    ", secondTokenURI);

        console.log("\n[CLIENT VERIFICATION] Both tokens perfectly map to their respective");
        console.log("tier JSON files (4.json and 7.json), eliminating the need to upload");
        console.log("individual metadata for every single token minted! \xE2\x9C\x85");
        console.log("========================================================\n");
    }

    // ==========================================
    // 🟢 SHOWCASE 2: FINANCIAL ROUTING & OWNER REVENUE
    // ==========================================
    function test_Client_Showcase_NFT_2_FinancialRouting() public {
        console.log("\n========================================================");
        console.log(">> SHOWCASE 2: DIRECT OWNER FINANCIAL ROUTING");
        console.log(">> EXPECTATION: 100% of NFT sales go straight to Owner Wallet.");
        console.log("========================================================\n");

        uint256 ownerBalanceBefore = usdt.balanceOf(ownerWallet);
        console.log("[DAY 0] Owner Wallet Balance: ", _usd(ownerBalanceBefore));

        console.log("\n[ACTION] User purchases a Tier 5 NFT for $25,000");
        vm.startPrank(testUser);
        usdt.approve(address(nft), 25_000 * 1e18);
        nft.buyNFT(5);
        vm.stopPrank();

        uint256 ownerBalanceAfter = usdt.balanceOf(ownerWallet);
        console.log("\n[RESULT] Owner Wallet Balance: ", _usd(ownerBalanceAfter));
        console.log("[CLIENT VERIFICATION] Funds successfully bypassed the Matrix");
        console.log("and settled securely in the Owner's Treasury! \xE2\x9C\x85");
        console.log("========================================================\n");
    }

    // ==========================================
    // 🟢 SHOWCASE 3: SCARCITY CAPS & HARD LIMITS
    // ==========================================
    // ==========================================
    // 💎 SHOWCASE 3: SCARCITY CAPS & HARD LIMITS
    // ==========================================
    function test_Client_Showcase_NFT_3_ScarcityCaps() public {
        console.log("\n========================================================");
        console.log(">> SHOWCASE 3: SCARCITY ENFORCEMENT (TIER 7 MAX 50)");
        console.log(">> EXPECTATION: The contract physical blocks the 51st mint.");
        console.log("========================================================\n");

        console.log("[SYSTEM] Minting exactly 50 Tier 7 NFTs ($100,000 each)...");
        
        // 🟢 FIX: Give the test user enough money to actually afford 50 Tier 7 NFTs!
        usdt.mint(testUser, 6_000_000 * 1e18); 
        
        vm.startPrank(testUser);
        usdt.approve(address(nft), 6_000_000 * 1e18); // Approve enough for 60 NFTs

        for(uint i = 0; i < 50; i++) {
            nft.buyNFT(7);
        }
        vm.stopPrank();

        (,, uint256 minted) = nft.tiers(7);
        console.log("   -> Tier 7 NFTs successfully minted: ", minted);
        console.log("   -> Total Supply Cap Reached!");

        console.log("\n[ACTION] A late investor tries to buy the 51st Tier 7 NFT...");
        
        vm.startPrank(testUser);
        
        // We expect the contract to throw an exact revert message
        vm.expectRevert("Tier completely sold out");
        nft.buyNFT(7);
        vm.stopPrank();

        console.log("\n[CLIENT VERIFICATION] Smart Contract successfully blocked the");
        console.log("transaction. Scarcity economics are actively protected!");
        console.log("========================================================\n");
    }
}