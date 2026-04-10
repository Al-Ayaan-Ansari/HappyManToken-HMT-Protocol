// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {HMTMining} from "../src/HMTMining.sol";
import {HMTToken} from "../src/HMTToken.sol"; 
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

interface IPancakeRouter02Test {
    function addLiquidity(
        address tokenA, 
        address tokenB, 
        uint amountADesired, 
        uint amountBDesired, 
        uint amountAMin, 
        uint amountBMin, 
        address to, 
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
}

// Mock NFT to satisfy the Mining Contract constructor requirements
contract MockNFT is ERC721 {
    uint256 public nextId = 1;
    mapping(uint256 => uint8) public tokenTier;
    
    constructor() ERC721("Mock", "MCK") {}
    
    function mintRewardNFT(address to, uint8 tier) external {
        tokenTier[nextId] = tier;
        _mint(to, nextId++);
    }

    function buyNFT(address to, uint8 tier) external {
        tokenTier[nextId] = tier;
        _mint(to, nextId++);
    }

    function getNFTTier(uint256 id) external view returns (uint8) { 
        return tokenTier[id]; 
    }

    function getTierPrice(uint8) external pure returns (uint256) { 
        return 10000 * 1e18; 
    }

    function ownerWallet() external pure returns(address) { 
        return address(0x200); 
    }
}

contract HMTROITest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    MockNFT public nft;

    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    
    address public company = address(0x100);
    address public ownerWallet = address(0x200);
    
    address public sponsor = address(0x300);
    address public user1 = address(0x400);
    address public user2 = address(0x500);

    uint256 public startTime;

    function setUp() public {
        vm.createSelectFork("bsc");

        hmt = new HMTToken(BSC_USDT, PANCAKESWAP_ROUTER);
        nft = new MockNFT();
        mining = new HMTMining(BSC_USDT, address(hmt), PANCAKESWAP_ROUTER, company, ownerWallet, address(nft));
        hmt.setMiningContract(address(mining));

        uint256 hmtLiquidity = 100 * 1e18;
        uint256 usdtLiquidity = 500 * 1e18; 

        deal(BSC_USDT, company, usdtLiquidity);
        hmt.transfer(company, hmtLiquidity); 

        vm.startPrank(company);
        IERC20(BSC_USDT).approve(PANCAKESWAP_ROUTER, usdtLiquidity);
        hmt.approve(PANCAKESWAP_ROUTER, hmtLiquidity);
        
        IPancakeRouter02Test(PANCAKESWAP_ROUTER).addLiquidity(
            address(hmt), BSC_USDT, hmtLiquidity, usdtLiquidity, 0, 0, company, block.timestamp + 1000 
        );
        vm.stopPrank();

        deal(BSC_USDT, sponsor, 1000 * 1e18);
        deal(BSC_USDT, user1, 2000 * 1e18);
        deal(BSC_USDT, user2, 1000 * 1e18);
        
        startTime = mining.launchTime();
    }

    function test_CombinedROIAndAirdrop() public {
        console.log("=======================================================");
        console.log("PHASE 1: SETUP AND INITIAL INVESTMENTS");
        console.log("=======================================================");
        
        // 1. Sponsor invests 100 USDT to open their referral link
        vm.startPrank(sponsor);
        IERC20(BSC_USDT).approve(address(mining), 100 * 1e18);
        mining.invest(company, 100 * 1e18, true);
        vm.stopPrank();
        console.log("[SUCCESS] Sponsor registered with 100 USDT.");

        // 2. User1 invests 1,000 USDT
        vm.startPrank(user1);
        IERC20(BSC_USDT).approve(address(mining), 1000 * 1e18);
        mining.invest(sponsor, 1000 * 1e18, true);
        vm.stopPrank();
        console.log("[SUCCESS] User1 invested 1,000 USDT.");

        // 3. User2 invests 100 USDT under User1 (Unlocks User1's Airdrop)
        vm.startPrank(user2);
        IERC20(BSC_USDT).approve(address(mining), 100 * 1e18);
        mining.invest(user1, 100 * 1e18, true);
        vm.stopPrank();
        console.log("[SUCCESS] User2 invested 100 USDT under User1.");

        uint256 currentCycle = (block.timestamp - startTime) / 28 days;
        uint256 nextCycle = currentCycle + 1;
        
        bool isEligibleCurrent = mining.cycleEligible(user1, currentCycle);
        bool isEligibleNext = mining.cycleEligible(user1, nextCycle);
        
        assertFalse(isEligibleCurrent, "User1 should NOT be eligible for the current cycle");
        assertTrue(isEligibleNext, "User1 cycle did not unlock for the NEXT cycle");
        console.log("[SUCCESS] User1 Airdrop successfully locked for current cycle, unlocked for NEXT cycle.");

        console.log("\n=======================================================");
        console.log("PHASE 2: END OF CURRENT CYCLE (CYCLE 0) VERIFICATION");
        console.log("=======================================================");

        // 🟢 FIX: Absolute Time Travel anchored exactly to launchTime
        // Warp to exactly 28 days + 1 hour to ensure we cleanly cross into the boundary of Cycle 1
        vm.warp(startTime + 28 days + 1 hours);
        console.log("[ACTION] Fast-forwarded to exact absolute boundary of Cycle 1.");

        (uint256 basePendingC0, uint256 airdropPendingC0) = mining.getPendingROI(user1);

        console.log("\n[CHECK] End of Cycle 0 Base ROI (84 periods):");
        console.log(" -> Actual (wei):", basePendingC0);
        assertApproxEqAbs(basePendingC0, 182.748 * 1e18, 0.1e18, "Base ROI compounding failed");

        console.log("\n[CHECK] End of Cycle 0 Airdrop ROI:");
        console.log(" -> Expected: 0 USDT (Not eligible for Cycle 0)");
        console.log(" -> Actual (wei):", airdropPendingC0);
        assertEq(airdropPendingC0, 0, "Airdrop should be 0 for Cycle 0");

        console.log("\n=======================================================");
        console.log("PHASE 3: END OF NEXT CYCLE (CYCLE 1) VERIFICATION");
        console.log("=======================================================");

        // 🟢 FIX: Absolute Time Travel anchored exactly to launchTime
        // Warp to exactly 56 days + 1 hour to ensure we cleanly cross the boundary of Cycle 2 
        // This forces the contract to evaluate the fully completed Cycle 1
        vm.warp(startTime + 56 days + 1 hours);
        console.log("[ACTION] Fast-forwarded to exact absolute boundary of Cycle 2.");

        (uint256 basePendingC1, uint256 airdropPendingC1) = mining.getPendingROI(user1);

        console.log("\n[CHECK] End of Cycle 1 Airdrop ROI:");
        console.log(" -> Expected: 28.000000 USDT");
        console.log(" -> Actual (wei):", airdropPendingC1);
        assertApproxEqAbs(airdropPendingC1, 28.0 * 1e18, 0.001e18, "Airdrop calculation failed after eligible cycle");

        console.log("\n=======================================================");
        console.log("PHASE 4: CLAIMING AND WALLET ROUTING");
        console.log("=======================================================");

        (,,,,,,,,,,,,,,,,uint256 sponsorVaultBefore,,) = mining.users(sponsor);

        // User1 calls claim
        vm.prank(user1);
        mining.claimROI();
        console.log("[ACTION] User1 executed claimROI().");

        (,,,,,,,,,,,,,,,,uint256 user1LiquidVault,,uint256 user1AirdropVault) = mining.users(user1);

        // Verification: User1 Vaults
        console.log("\n[CHECK] User1 Vault Distributions:");
        console.log(" -> Liquid Vault (Base ROI):", user1LiquidVault);
        console.log(" -> Airdrop Vault (Airdrop ROI):", user1AirdropVault);
        assertApproxEqAbs(user1AirdropVault, 28.0 * 1e18, 0.001e18, "Airdrop Vault did not receive Airdrop ROI");

        // Verification: Sponsor 15% Level Income
        (,,,,,,,,,,,,,,,,uint256 sponsorVaultAfter,,) = mining.users(sponsor);
        uint256 sponsorReceived = sponsorVaultAfter - sponsorVaultBefore;
        uint256 expectedSponsorCommission = (user1LiquidVault * 15) / 100;
        
        console.log("\n[CHECK] Sponsor Level Income (15% Match on Base ROI):");
        console.log(" -> Expected Match:", expectedSponsorCommission);
        console.log(" -> Actual Received:", sponsorReceived);
        assertApproxEqAbs(sponsorReceived, expectedSponsorCommission, 0.001e18, "Sponsor did not receive exact 15% match on Base ROI claim");

        console.log("\n=======================================================");
        console.log("TEST COMPLETE: ALL ROI MECHANICS VERIFIED FLAWLESSLY");
        console.log("=======================================================\n");
    }
}