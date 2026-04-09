// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {HMTMining} from "../src/HMTMining.sol";
import {HMTToken} from "../src/HMTToken.sol"; 
import {HMT_NFT} from "../src/HMTNFT.sol"; 
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IPancakeRouter02Test {
    function addLiquidity(address tokenA, address tokenB, uint amountADesired, uint amountBDesired, uint amountAMin, uint amountBMin, address to, uint deadline) external returns (uint amountA, uint amountB, uint liquidity);
}

contract HMTAuxiliaryTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    HMT_NFT public nft;

    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    
    address public company = address(0x100);
    address public ownerWallet = address(0x200);
    address public insuranceWallet = address(0x9999); 
    address public liquidityMaintainer = address(0x8888);

    address public activeUser = address(0x2222);

    function setUp() public {
        vm.createSelectFork("bsc");

        hmt = new HMTToken(BSC_USDT, PANCAKESWAP_ROUTER);
        nft = new HMT_NFT(BSC_USDT, ownerWallet);
        mining = new HMTMining(BSC_USDT, address(hmt), PANCAKESWAP_ROUTER, insuranceWallet, liquidityMaintainer, address(nft));
        
        hmt.setMiningContract(address(mining));
        nft.setMiningContract(address(mining));

        // 🟢 FIX for autoBalanceLiquidity test: Initial LP must be small enough to trigger the re-balance logic.
        // Contract constructor sets `lastHmtReserve = 1000e18`. 
        // We will make initial LP exactly 100 HMT / 100 USDT to simulate a drained pool.
        uint256 hmtLiquidity = 100 * 1e18;
        uint256 usdtLiquidity = 100 * 1e18; 

        deal(BSC_USDT, company, 1_000_000 * 1e18); // Give company plenty of USDT for later
        hmt.transfer(company, 1_000_000 * 1e18); 

        vm.startPrank(company);
        IERC20(BSC_USDT).approve(PANCAKESWAP_ROUTER, usdtLiquidity);
        hmt.approve(PANCAKESWAP_ROUTER, hmtLiquidity);
        IPancakeRouter02Test(PANCAKESWAP_ROUTER).addLiquidity(
            address(hmt), BSC_USDT, hmtLiquidity, usdtLiquidity, 0, 0, company, block.timestamp + 1000 
        );
        vm.stopPrank();

        // Fund Mining Contract to pay for rewards & LP additions
        hmt.transfer(address(mining), 50_000 * 1e18);
        deal(BSC_USDT, address(mining), 50_000 * 1e18);
        
        deal(address(hmt), activeUser, 10_000 * 1e18);
    }

    // --- TEST 1: Maintainer Daily Claim ---
    function test_Aux_DailyRewardClaim() public {
        console.log("=======================================================");
        console.log("TEST: LIQUIDITY MAINTAINER DAILY REWARD");
        console.log("=======================================================");

        uint256 startHmt = hmt.balanceOf(liquidityMaintainer);
        uint256 startUsdt = IERC20(BSC_USDT).balanceOf(liquidityMaintainer);

        // Try to claim immediately (should yield 0 days passed)
        mining.claimDailyReward();
        assertEq(hmt.balanceOf(liquidityMaintainer), startHmt, "Should not pay if 1 day hasn't passed");

        // Warp forward exactly 3 days
        vm.warp(block.timestamp + 3 days);

        mining.claimDailyReward();

        uint256 endHmt = hmt.balanceOf(liquidityMaintainer);
        uint256 endUsdt = IERC20(BSC_USDT).balanceOf(liquidityMaintainer);

        console.log("[VERIFICATION] Claimed HMT after 3 days:", (endHmt - startHmt) / 1e18);
        console.log("[VERIFICATION] Claimed USDT after 3 days:", (endUsdt - startUsdt) / 1e18);

        assertEq(endHmt - startHmt, 3 * 1e18, "Failed to mint exact HMT daily reward");
        assertEq(endUsdt - startUsdt, 3 * 1e18, "Failed to mint exact USDT daily reward");
        console.log("[SUCCESS] Daily reward accumulator logic is perfectly accurate.");
    }

    // --- TEST 2: Early Unstaking Penalty ---
    function test_Aux_EarlyUnstakePenalty() public {
        console.log("\n=======================================================");
        console.log("TEST: HMT STAKING EARLY WITHDRAWAL PENALTY");
        console.log("=======================================================");

        uint256 stakeAmount = 1000 * 1e18;

        vm.startPrank(activeUser);
        hmt.approve(address(mining), stakeAmount);
        mining.stakeHMTTokens(stakeAmount);
        vm.stopPrank();

        console.log("[ACTION] User staked 1,000 HMT.");

        // 🟢 FIX: Warp forward exactly 5 days (0 months passed = 20% penalty)
        vm.warp(block.timestamp + 5 days);

        uint256 balanceBefore = hmt.balanceOf(activeUser);

        vm.prank(activeUser);
        mining.unstakeAllHMT();

        uint256 receivedHMT = hmt.balanceOf(activeUser) - balanceBefore;
        
        console.log("[VERIFICATION] Total HMT Received back after 5 days:", receivedHMT / 1e18);

        // Mathematical Expectation: 
        // Penalty = 20% of 1000 = 200 HMT.
        // Reward generated in 5 days (15 periods of 0.2%) is exactly ~30.4 HMT.
        // Since Penalty (200) > Reward (30.4), the penalty eats the reward, and then eats the principal by ~169.6 HMT.
        // Expected return should be exactly ~830.4 HMT.
        assertTrue(receivedHMT < stakeAmount, "User was not penalized for early unstake!");
        assertApproxEqAbs(receivedHMT, 830.41 * 1e18, 0.05 * 1e18, "Penalty math didn't deduct correctly from principal");

        console.log("[SUCCESS] Early unstaking penalty successfully slashed principal to protect TVL.");
    }
    // --- TEST 3: Auto-Balance Liquidity ---
    function test_Aux_AutoBalanceLiquidity() public {
        console.log("\n=======================================================");
        console.log("TEST: AUTO-BALANCE LIQUIDITY POOL");
        console.log("=======================================================");

        // In setUp(), we created an LP of 100 HMT. 
        // lastHmtReserve initialized to 1000 in constructor.
        // hmtRes (100) < lastHmtReserve/2 (500). Therefore, `autoBalanceLiquidity` will PASS the guard check!
        
        uint256 miningHmtBefore = hmt.balanceOf(address(mining));
        uint256 miningUsdtBefore = IERC20(BSC_USDT).balanceOf(address(mining));

        // Anyone can call this function
        mining.autoBalanceLiquidity();

        uint256 miningHmtAfter = hmt.balanceOf(address(mining));
        uint256 miningUsdtAfter = IERC20(BSC_USDT).balanceOf(address(mining));

        uint256 hmtSpent = miningHmtBefore - miningHmtAfter;
        uint256 usdtSpent = miningUsdtBefore - miningUsdtAfter;

        console.log("[VERIFICATION] Contract spent", hmtSpent / 1e18, "HMT to reinforce liquidity.");
        console.log("[VERIFICATION] Contract spent", usdtSpent / 1e18, "USDT to reinforce liquidity.");

        // The logic states: hToAdd = hmtRes * 2 (100 * 2 = 200).
        assertEq(hmtSpent, 200 * 1e18, "Contract did not add the correct multiplier to liquidity");
        
        console.log("[SUCCESS] Contract autonomously managed PancakeSwap liquidity injections.");
    }
}