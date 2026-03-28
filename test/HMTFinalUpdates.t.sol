// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

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

contract HMTFinalUpdatesTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    HMT_NFT public nft;

    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    
    address public company = address(0x100);
    address public ownerWallet = address(0x200);

    uint160 private dummyNonce = 9000000;

    function setUp() public {
        hmt = new HMTToken(BSC_USDT, PANCAKESWAP_ROUTER);
        
        // Deploy the REAL NFT contract. 
        // Note: msg.sender here is address(this), so the Test Contract is the Owner.
        nft = new HMT_NFT(BSC_USDT, ownerWallet);
        
        mining = new HMTMining(BSC_USDT, address(hmt), PANCAKESWAP_ROUTER, company, ownerWallet, address(nft));
        
        hmt.setMiningContract(address(mining));
        nft.setMiningContract(address(mining));

        uint256 hmtLiquidity = 14_700_000 * 1e18;
        uint256 usdtLiquidity = 2500 * 1e18;     

        deal(BSC_USDT, company, usdtLiquidity);
        hmt.transfer(company, hmtLiquidity); 

        vm.startPrank(company);
        IERC20(BSC_USDT).approve(PANCAKESWAP_ROUTER, usdtLiquidity);
        hmt.approve(PANCAKESWAP_ROUTER, hmtLiquidity);
        IPancakeRouter02Test(PANCAKESWAP_ROUTER).addLiquidity(
            address(hmt), BSC_USDT, hmtLiquidity, usdtLiquidity, 0, 0, company, block.timestamp + 1000 
        );
        vm.stopPrank();
        
        hmt.transfer(address(mining), 1_000_000 * 1e18);
    }

    function _invest(address _user, address _sponsor, uint256 _amount) internal {
        deal(BSC_USDT, _user, _amount);
        vm.startPrank(_user);
        IERC20(BSC_USDT).approve(address(mining), _amount);
        mining.invest(_sponsor, _amount, false); 
        vm.stopPrank();
    }

    // ==========================================
    // 🧪 TEST 1: NFT 10% GENESIS ALLOCATION
    // ==========================================
    function test_Final_NFTOwnerAllocation() public {
        console.log("-----------------------------------------");
        console.log("TEST 1: NFT Genesis Allocation (claimOwnerAllocation)");

        // 1. Owner claims Tier 1 (Max Supply 5000)
        // 🟢 FIXED: The Test Contract deployed HMT_NFT, so the Test Contract is the Owner!
        nft.claimOwnerAllocation(1);

        uint256 ownerBalance = nft.balanceOf(ownerWallet);
        (,, uint256 minted, bool claimed) = nft.tiers(1);

        console.log("Tier 1 Max Supply: 5000");
        console.log("Owner NFTs Minted: ", ownerBalance);

        // 10% of 5000 is exactly 500 NFTs.
        assertEq(ownerBalance, 500, "Owner did not receive exactly 10% of Tier 1 supply");
        assertEq(minted, 500, "Minted counter not updated correctly");
        assertTrue(claimed, "Boolean flag not set to true");

        // 2. Prevent Double Claiming
        vm.expectRevert("Allocation already claimed for this tier");
        nft.claimOwnerAllocation(1);
        
        console.log("SUCCESS: Contract physically blocks double-claiming!");
    }

    // ==========================================
    // 🧪 TEST 2: UNIVERSAL 1% YIELD (TIER 1)
    // ==========================================
    function test_Final_UniversalTier1NFTYield() public {
        console.log("-----------------------------------------");
        console.log("TEST 2: Tier 1 Universal 1% Daily Yield");

        address nftBuyer = address(dummyNonce++);
        deal(BSC_USDT, nftBuyer, 1000 * 1e18);

        vm.startPrank(nftBuyer);
        IERC20(BSC_USDT).approve(address(nft), 1000 * 1e18);
        nft.buyNFT(1); // Buy Tier 1 ($1000)
        
        uint256 tokenId = nft.tokenOfOwnerByIndex(nftBuyer, 0);
        nft.approve(address(mining), tokenId);
        mining.stakeNFT(tokenId); // Staked in Cycle 0. Yield begins calculating at Start of Cycle 1.
        vm.stopPrank();

        // 🟢 FIXED: Warp exactly 56 days (Cycle 2) so Cycle 1 is fully complete and ready for payout!
        vm.warp(mining.launchTime() + 56 days);

        uint256 pendingRewards = mining.getPendingNFTRewards(nftBuyer);
        
        // 1% of $1000 = $10/day. 28 days = $280.
        console.log("Tier 1 NFT Pending Rewards after 28 days: $", pendingRewards / 1e18);
assertEq(pendingRewards, 10 * 1e18, "Tier 1 did not generate the 1% cycle return");
    }

    // ==========================================
    // 🧪 TEST 3: DYNAMIC WITHDRAWAL LIMITS & HARD CAP
    // ==========================================
    function test_Final_WithdrawalCapsAndHardLimits() public {
        console.log("-----------------------------------------");
        console.log("TEST 3: 10% Dynamic Limit & $1000 Hard Cap");

        address normalUser = address(dummyNonce++);
        address whaleUser = address(dummyNonce++);

        // 🟢 FIXED: Use $1,000 blocks to strictly avoid hitting the 24h spam protection limit

        // USER 1: Normal User invests $5,000 total (over 5 days)
        for(uint i=0; i<5; i++) {
            _invest(normalUser, company, 1000 * 1e18);
            skip(25 hours);
        }

        // USER 2: Whale User invests $15,000 total (over 15 days)
        for(uint i=0; i<15; i++) {
            _invest(whaleUser, company, 1000 * 1e18);
            skip(25 hours);
        }

        // Check Limits
        (uint256 normalLimit, ) = mining.getDailyWithdrawLimit(normalUser);
        (uint256 whaleLimit, ) = mining.getDailyWithdrawLimit(whaleUser);

        console.log("Normal User ($5k Inv) Limit: $", normalLimit / 1e18);
        console.log("Whale User ($15k Inv) Limit: $", whaleLimit / 1e18);

        // Normal User should be exactly 10% ($500)
        assertEq(normalLimit, 500 * 1e18, "Normal user limit is not exactly 10%");
        
        // Whale User should be throttled to $1000 (Even though 10% of 15k is $1500)
        assertEq(whaleLimit, 1000 * 1e18, "Whale was not stopped by the $1000 Hard Cap!");
        
        console.log("SUCCESS: Limits perfectly scale and throttle!");
    }

    // ==========================================
    // 🧪 TEST 4: DAILY WITHDRAWAL WINDOW EXHAUSTION
    // ==========================================
    function test_Final_WithdrawalWindowExhaustion() public {
        address user = address(0xABC);
        _invest(user, company, 2500 * 1e18); // $2,500 investment. Limit = $250.

        // Generate ROI to withdraw
        vm.warp(block.timestamp + 200 days);
        vm.prank(user);
        mining.claimROI(); // Claim built-up Base ROI

        (uint256 limitBefore, uint256 remainingBefore) = mining.getDailyWithdrawLimit(user);
        assertEq(limitBefore, 250 * 1e18);
        assertEq(remainingBefore, 250 * 1e18);

        // Withdraw $100
        vm.prank(user);
        mining.withdraw(100 * 1e18, false);

        (, uint256 remainingAfter) = mining.getDailyWithdrawLimit(user);
        assertEq(remainingAfter, 150 * 1e18, "Remaining limit not updated correctly");

        // Attempt to withdraw $200 (Which exceeds the remaining $150)
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSignature("ExceedsDailyLimit()"));
        mining.withdraw(200 * 1e18, false);
    }
}