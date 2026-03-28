// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Minimal interface to interact with your live NFT contract
interface IHMT_NFT {
    function claimOwnerAllocation(uint8 _tier) external;
}

contract ClaimNFTAllocation is Script {
    // 🟢 Your live HMT NFT Contract on BSC Testnet
    address constant NFT_ADDRESS = 0x060C6861b6fF27136B9340b569d4282963527cE1;

    function run() external {
        // Foundry automatically picks up the --private-key flag from the terminal
        vm.startBroadcast();
        
        IHMT_NFT nft = IHMT_NFT(NFT_ADDRESS);
        
        // 🚨 CHOOSE YOUR TIER HERE
        // Start with Tier 7 (mints 25 NFTs). 
        // Warning: Claiming Tier 1 (mints 500 NFTs) will likely hit the block gas limit!
        uint8 targetTier = 7; 
        
        console.log("Attempting to claim Owner Allocation for Tier", targetTier, "...");
        
        nft.claimOwnerAllocation(targetTier);
        
        console.log("! Owner Allocation claimed for Tier", targetTier);

        vm.stopBroadcast();
    }
}