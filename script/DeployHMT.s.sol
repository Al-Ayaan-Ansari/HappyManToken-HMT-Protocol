// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {HMTToken} from "../src/HMTToken.sol";
import {HMT_NFT} from "../src/HMTNFT.sol";
import {HMTMining} from "../src/HMTMining.sol";

contract DeployHMT is Script {
    
    // 🟢 BSC MAINNET CONSTANTS
    // address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    // address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;


    // 🟢 TESTNET CONSTANTS
    address constant BSC_USDT = 0x0E78a171587B55381AE57686f0Ad0ea62e58052d;
    address constant PANCAKESWAP_ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;

    // 🚨 UPDATE THESE TWO ADDRESSES BEFORE DEPLOYING
    address constant COMPANY_WALLET = 0xcdA255C7a704281ac3F9F643f3B529C546a83fA9; // Receives 10% investment fees
    address constant OWNER_WALLET = 0xcdA255C7a704281ac3F9F643f3B529C546a83fA9;   // Receives 5% withdraw fees & NFT sales

    function run() external {
        // Foundry will automatically pick up the --private-key flag from the terminal
        vm.startBroadcast();

        console.log("Starting HMT Ecosystem Testnet Deployment...");

        // 1. Deploy HMT Token
        HMTToken hmt = new HMTToken(BSC_USDT, PANCAKESWAP_ROUTER);
        console.log("1. HMT Token deployed to:", address(hmt));

        // 2. Deploy NFT Contract
        HMT_NFT nft = new HMT_NFT(BSC_USDT, OWNER_WALLET);
        console.log("2. HMT NFT deployed to:", address(nft));

        // 3. Deploy Mining Contract
        HMTMining mining = new HMTMining(
            BSC_USDT, 
            address(hmt), 
            PANCAKESWAP_ROUTER, 
            COMPANY_WALLET, 
            OWNER_WALLET, 
            address(nft)
        );
        console.log("3. HMT Mining Contract deployed to:", address(mining));

        // 4. Securely Link the Ecosystem
        hmt.setMiningContract(address(mining));
        nft.setMiningContract(address(mining));
        console.log("4. Ecosystem Linked! (Mining contract authorized)");

        // 5. Transfer 80% of HMT to Mining Contract (16,800,000 HMT)
        // 21,000,000 * 80% = 16,800,000
        uint256 miningSupply = 16_800_000 * 1e18;
        hmt.transfer(address(mining), miningSupply);
        console.log("5. Transferred 16.8M HMT (80%) to Mining Contract.");
        
        uint256 deployerBalance = hmt.balanceOf(msg.sender);
        console.log("   Deployer retained balance:", deployerBalance / 1e18, "HMT");

        // 6. Claim Genesis NFT Allocations (10% of all 7 tiers)
        // console.log("6. Claiming Genesis NFT Allocations for Developer...");
        // for (uint8 i = 1; i <= 7; i++) {
        //     nft.claimOwnerAllocation(i);
        //     console.log(string.concat("   - Claimed allocation for Tier ", vm.toString(i)));
        // }

        // Note: Ownership transfer is intentionally omitted for Testnet showcasing.
        // The deployer wallet remains the Owner.
        console.log("7. Ownership retained by deployer wallet for showcasing.");

        vm.stopBroadcast();
        console.log("HMT Ecosystem Testnet Deployment Complete!");
    }
}