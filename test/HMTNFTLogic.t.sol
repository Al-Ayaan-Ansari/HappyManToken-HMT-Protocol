// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {HMTMining} from "../src/HMTMining.sol";
import {HMTToken} from "../src/HMTToken.sol"; 
import {HMT_NFT} from "../src/HMTNFT.sol"; 
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IPancakeRouter02Test {
    function addLiquidity(address tokenA, address tokenB, uint amountADesired, uint amountBDesired, uint amountAMin, uint amountBMin, address to, uint deadline) external returns (uint amountA, uint amountB, uint liquidity);
}

contract HMTNFTLogicTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    HMT_NFT public nft;

    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    
    address public company = address(0x100);
    address public ownerWallet = address(0x200);
    address public insuranceWallet = address(0x9999); 
    address public liquidityMaintainer = address(0x8888);

    address public sponsorUser = address(0x1111);
    address public activeUser = address(0x2222);

    function setUp() public {
        vm.createSelectFork("bsc");

        hmt = new HMTToken(BSC_USDT, PANCAKESWAP_ROUTER);
        nft = new HMT_NFT(BSC_USDT, ownerWallet);
        mining = new HMTMining(BSC_USDT, address(hmt), PANCAKESWAP_ROUTER, insuranceWallet, liquidityMaintainer, address(nft));
        
        hmt.setMiningContract(address(mining));
        nft.setMiningContract(address(mining));

        uint256 hmtLiquidity = 1_000_000 * 1e18;
        uint256 usdtLiquidity = 1_000_000 * 1e18; 

        deal(BSC_USDT, company, usdtLiquidity);
        hmt.transfer(company, hmtLiquidity); 

        vm.startPrank(company);
        IERC20(BSC_USDT).approve(PANCAKESWAP_ROUTER, usdtLiquidity);
        hmt.approve(PANCAKESWAP_ROUTER, hmtLiquidity);
        IPancakeRouter02Test(PANCAKESWAP_ROUTER).addLiquidity(
            address(hmt), BSC_USDT, hmtLiquidity, usdtLiquidity, 0, 0, company, block.timestamp + 1000 
        );
        vm.stopPrank();

        deal(BSC_USDT, sponsorUser, 10_000 * 1e18);
        deal(BSC_USDT, activeUser, 10_000 * 1e18);
        deal(address(hmt), activeUser, 10_000_000 * 1e18); // Deal massive HMT for staking cap test

        vm.startPrank(company);
        deal(BSC_USDT, company, 1000 * 1e18);
        IERC20(BSC_USDT).approve(address(mining), 100 * 1e18);
        mining.invest(insuranceWallet, 100 * 1e18, true);
        vm.stopPrank();

        // Provide the Mining Contract with a healthy HMT reserve buffer 
        hmt.transfer(address(mining), 5_000_000 * 1e18);
    }

    // --- TEST 1: The Core Pipeline (Buy Internal Swap, Stake, 1-Cycle Unstake) ---
    function test_NFT_BuyStakeAndRewardPipeline() public {
        vm.startPrank(sponsorUser);
        IERC20(BSC_USDT).approve(address(mining), 100 * 1e18);
        mining.invest(company, 100 * 1e18, true);
        vm.stopPrank();

        vm.startPrank(activeUser);
        IERC20(BSC_USDT).approve(address(mining), 100 * 1e18);
        mining.invest(sponsorUser, 100 * 1e18, true);
        vm.stopPrank();

        uint256 sponsorUsdtBefore = IERC20(BSC_USDT).balanceOf(sponsorUser);
        uint256 sponsorHmtBefore = hmt.balanceOf(sponsorUser);
        uint256 ownerUsdtBefore = IERC20(BSC_USDT).balanceOf(ownerWallet);

        // Active User Buys Tier 1 NFT (1,000 USDT)
        vm.startPrank(activeUser);
        IERC20(BSC_USDT).approve(address(mining), 1000 * 1e18);
        mining.buyNFT(1); 
        
        // 🟢 FIX: Verify Contract used internal balance correctly without AMM Swap slippage
        uint256 sponsorUsdtAfter = IERC20(BSC_USDT).balanceOf(sponsorUser);
        uint256 sponsorHmtAfter = hmt.balanceOf(sponsorUser);
        uint256 ownerUsdtAfter = IERC20(BSC_USDT).balanceOf(ownerWallet);

        assertEq(sponsorUsdtAfter - sponsorUsdtBefore, 0, "Sponsor should not receive USDT anymore");
        assertEq(ownerUsdtAfter - ownerUsdtBefore, 950 * 1e18, "Owner should receive exactly 95% USDT");

        uint256 expectedSponsorHmtPurchase = hmt.getHMTForUSDT(50 * 1e18); // 5% of 1000 = 50 USDT
        
        // 🟢 Exact equality check since there is no AMM swap slippage
        assertEq(sponsorHmtAfter - sponsorHmtBefore, expectedSponsorHmtPurchase, "Sponsor internal HMT transfer failed");
        console.log("[VERIFICATION] Contract flawlessly calculated and transferred exactly 5% equivalent in HMT to Sponsor!");

        uint256 tokenId = 1;
        nft.approve(address(mining), tokenId);
        mining.stakeNFT(tokenId);
        vm.stopPrank();

        uint256 cycle2Start = mining.launchTime() + (28 days * 2);
        vm.warp(cycle2Start + 1 days);
        
        uint256 expectedRewardUsdt = 10 * 1e18; // 1% of 1000
        uint256 expectedRewardHmt = hmt.getHMTForUSDT(expectedRewardUsdt);
        uint256 expectedSponsorHmt = (expectedRewardHmt * 15) / 100;

        uint256 userHmtBeforeClaim = hmt.balanceOf(activeUser);
        uint256 sponsorHmtBeforeClaim = hmt.balanceOf(sponsorUser);

        vm.startPrank(activeUser);
        mining.unstakeNFT(tokenId);
        vm.stopPrank();

        assertApproxEqAbs(hmt.balanceOf(activeUser) - userHmtBeforeClaim, expectedRewardHmt, 0.01 * 1e18, "User 1% payout failed");
        assertApproxEqAbs(hmt.balanceOf(sponsorUser) - sponsorHmtBeforeClaim, expectedSponsorHmt, 0.01 * 1e18, "Sponsor 15% payout failed");
    }

    // --- TEST 2: The Owner's Allocation (Creator Royalty) ---
    function test_NFT_OwnerAllocationRoyalty() public {
        console.log("\n=======================================================");
        console.log("TEST: NFT CREATOR ROYALTY (OWNER ALLOCATION)");
        console.log("=======================================================");

        uint256 ownerBalanceBefore = nft.balanceOf(ownerWallet);
        assertEq(ownerBalanceBefore, 0, "Owner should start with 0 NFTs");

        nft.claimOwnerAllocation();

        uint256 ownerBalanceAfter = nft.balanceOf(ownerWallet);
        
        console.log("[VERIFICATION] Owner NFT Balance After Claim:", ownerBalanceAfter);
        
        assertEq(ownerBalanceAfter, 100, "Owner did not receive the batch limit of 100 NFTs");
        console.log("[SUCCESS] Owner successfully claimed Creator Royalty Batch!");
    }

    // --- TEST 3: The Recurring Passive Yield (Residual Royalty) ---
    function test_NFT_RecurringStakingRoyalty() public {
        console.log("\n=======================================================");
        console.log("TEST: RECURRING RESIDUAL ROYALTY (MULTI-CYCLE STAKING)");
        console.log("=======================================================");

        vm.startPrank(sponsorUser);
        IERC20(BSC_USDT).approve(address(mining), 100 * 1e18);
        mining.invest(company, 100 * 1e18, true);
        vm.stopPrank();

        vm.startPrank(activeUser);
        IERC20(BSC_USDT).approve(address(mining), 100 * 1e18);
        mining.invest(sponsorUser, 100 * 1e18, true);
        vm.stopPrank();

        vm.startPrank(activeUser);
        IERC20(BSC_USDT).approve(address(mining), 2500 * 1e18);
        mining.buyNFT(2);
        
        uint256 tokenId = 1;
        nft.approve(address(mining), tokenId);
        mining.stakeNFT(tokenId);
        vm.stopPrank();

        vm.warp(mining.launchTime() + (28 days * 2) + 1 hours);
        
        uint256 uHmtBefore_C1 = hmt.balanceOf(activeUser);
        uint256 sHmtBefore_C1 = hmt.balanceOf(sponsorUser);

        vm.prank(activeUser);
        mining.claimROI(); 

        uint256 userHmtReceived_C1 = hmt.balanceOf(activeUser) - uHmtBefore_C1;
        uint256 sponsorHmtReceived_C1 = hmt.balanceOf(sponsorUser) - sHmtBefore_C1;

        uint256 expectedRewardUsdt_C1 = 25 * 1e18; // 1% of 2500 for 1 cycle
        uint256 expectedHmt_C1 = hmt.getHMTForUSDT(expectedRewardUsdt_C1);
        uint256 expectedSponsor_C1 = (expectedHmt_C1 * 15) / 100;

        assertApproxEqAbs(userHmtReceived_C1, expectedHmt_C1, 0.01 * 1e18, "Cycle 1 User Royalty Failed");
        assertApproxEqAbs(sponsorHmtReceived_C1, expectedSponsor_C1, 0.01 * 1e18, "Cycle 1 Sponsor Royalty Failed");
        console.log("[ROYALTY 1] Claimed exactly 1% after 1 mature Cycle.");

        vm.warp(mining.launchTime() + (28 days * 5) + 1 hours);

        uint256 uHmtBefore_C4 = hmt.balanceOf(activeUser);
        uint256 sHmtBefore_C4 = hmt.balanceOf(sponsorUser);

        vm.prank(activeUser);
        mining.claimROI();

        uint256 userHmtReceived_C4 = hmt.balanceOf(activeUser) - uHmtBefore_C4;
        uint256 sponsorHmtReceived_C4 = hmt.balanceOf(sponsorUser) - sHmtBefore_C4;

        uint256 expectedRewardUsdt_C4 = 75 * 1e18; // 3% of 2500 for 3 cycles
        uint256 expectedHmt_C4 = hmt.getHMTForUSDT(expectedRewardUsdt_C4);
        uint256 expectedSponsor_C4 = (expectedHmt_C4 * 15) / 100;

        assertApproxEqAbs(userHmtReceived_C4, expectedHmt_C4, 0.01 * 1e18, "Multi-Cycle User Royalty Failed");
        assertApproxEqAbs(sponsorHmtReceived_C4, expectedSponsor_C4, 0.01 * 1e18, "Multi-Cycle Sponsor Royalty Failed");

        console.log("[ROYALTY 2] User claimed accumulated 3% after leaving NFT alone for 3 Cycles.");
        console.log("[SUCCESS] Continuous passive royalty verified across multiple time periods!");
    }

    // --- TEST 4: Global HMT Staking Reward Cap Migration ---
    function test_HMTStaking_GlobalRewardCap() public {
        console.log("\n=======================================================");
        console.log("TEST: GLOBAL HMT STAKING CAP (2.1 MILLION SHUTDOWN)");
        console.log("=======================================================");

        // Stake a massive amount of HMT (10 Million HMT)
        vm.startPrank(activeUser);
        hmt.approve(address(mining), 10_000_000 * 1e18);
        mining.stakeHMTTokens(10_000_000 * 1e18);
        vm.stopPrank();

        console.log("[ACTION] User staked 10 Million HMT.");

        // Warp forward roughly ~1 year (1,100 periods of 8 hours)
        // 0.2% per 8 hours compounding on 10 Million HMT will easily breach the 2.1M Cap.
        vm.warp(block.timestamp + 365 days);

        vm.prank(activeUser);
        mining.unstakeAllHMT();

        uint256 totalDistributed = mining.totalHMTRewardsDistributed();
        bool isDisabled = mining.isHMTStakingDisabled();

        console.log("[VERIFICATION] Total Native HMT Rewards Distributed:", totalDistributed / 1e18);
        
        // Assert that exactly 2.1 Million was distributed, protecting the protocol from printing too much
        assertEq(totalDistributed, 2_100_000 * 1e18, "Global HMT Staking Cap was breached!");
        
        // Assert that the global shutdown switch was flipped
        assertTrue(isDisabled, "Staking was not disabled after cap was reached");

        console.log("[SUCCESS] Protocol smoothly capped payouts at 2.1M HMT and triggered the shutdown switch.");

        // Verify new staking attempts are blocked
        vm.startPrank(activeUser);
        hmt.approve(address(mining), 100 * 1e18);
        
        vm.expectRevert(abi.encodeWithSignature("HMTStakingLimitReached()"));
        mining.stakeHMTTokens(100 * 1e18);
        vm.stopPrank();

        console.log("[SUCCESS] Contract correctly blocks any new native HMT from being staked.");
    }
}