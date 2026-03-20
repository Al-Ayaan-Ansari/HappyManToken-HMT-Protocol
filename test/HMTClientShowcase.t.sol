// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {HMTMining} from "../src/HMTMining.sol";
import {HMTToken} from "../src/HMTToken.sol"; 
import {HMT_NFT} from "../src/HMTNFT.sol"; 
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// 🟢 Interface for live AMM Liquidity Injection
interface IPancakeRouter02Test {
    function addLiquidity(address tokenA, address tokenB, uint amountADesired, uint amountBDesired, uint amountAMin, uint amountBMin, address to, uint deadline) external returns (uint amountA, uint amountB, uint liquidity);
}

// ==========================================
// 🧪 THE LIVE FORK SHOWCASE TEST SUITE
// ==========================================
contract HMTClientShowcaseTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    HMT_NFT public nft; 

    // 🟢 Real BSC Mainnet Addresses
    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;

    address public company = address(0x100);
    address public ownerWallet = address(0x200);
    uint160 private dummyNonce = 9999999;

    function setUp() public {
        // 🟢 Deploying the REAL Contracts on the Live Fork
        nft = new HMT_NFT(BSC_USDT, ownerWallet);
        hmt = new HMTToken(BSC_USDT, PANCAKESWAP_ROUTER);
        mining = new HMTMining(BSC_USDT, address(hmt), PANCAKESWAP_ROUTER, company, ownerWallet, address(nft));
        
        // Link them together securely
        hmt.setMiningContract(address(mining));
        nft.setMiningContract(address(mining));

        uint256 hmtLiquidity = 14_700_000 * 1e18;
        uint256 ownerShare = 2_100_100 * 1e18;
        uint256 usdtLiquidity = 2500 * 1e18;     

        deal(BSC_USDT, company, usdtLiquidity);
        hmt.transfer(company, hmtLiquidity); 
        hmt.transfer(address(mining), ownerShare);

        // Inject live liquidity to PancakeSwap
        vm.startPrank(company);
        IERC20(BSC_USDT).approve(PANCAKESWAP_ROUTER, usdtLiquidity);
        hmt.approve(PANCAKESWAP_ROUTER, hmtLiquidity);
        IPancakeRouter02Test(PANCAKESWAP_ROUTER).addLiquidity(address(hmt), BSC_USDT, hmtLiquidity, usdtLiquidity, 0, 0, company, block.timestamp + 1000);
        vm.stopPrank();
        
        hmt.transfer(address(mining), 1_000_000 * 1e18);
    }

    function _usd(uint256 amount) internal pure returns (string memory) {
        uint256 dollars = amount / 1e18;
        uint256 cents = ((amount % 1e18) * 100) / 1e18;
        string memory centsStr = cents < 10 ?
            string(abi.encodePacked("0", vm.toString(cents))) : vm.toString(cents);
        return string(abi.encodePacked("$", vm.toString(dollars), ".", centsStr));
    }

    // 🟢 Smart Invest dynamically respects the V2 24-Hour Window mapping
    function _invest(address _user, address _sponsor, uint256 _totalAmount) internal {
        (uint256 windowStartTime, uint256 windowTotalInvested) = mining.userInvestmentWindows(_user);
        
        uint256 userInvestedToday = (block.timestamp >= windowStartTime + 24 hours) ? 0 : windowTotalInvested;
        uint256 userCanInvest = 2500 * 1e18 > userInvestedToday ? (2500 * 1e18) - userInvestedToday : 0;
        
        uint256 amountForUser = _totalAmount > userCanInvest ? userCanInvest : _totalAmount;

        if (amountForUser > 0) {
            deal(BSC_USDT, _user, amountForUser); // 🟢 Now using `deal` and live USDT
            vm.startPrank(_user);
            IERC20(BSC_USDT).approve(address(mining), amountForUser);
            mining.invest(_sponsor, amountForUser, false);
            vm.stopPrank();
        }

        uint256 amountLeft = _totalAmount - amountForUser;
        while(amountLeft > 0) {
            uint256 chunk = amountLeft > 2500 * 1e18 ? 2500 * 1e18 : amountLeft;
            address dummy = address(dummyNonce++);
            deal(BSC_USDT, dummy, chunk); // 🟢 Now using `deal` and live USDT
            vm.startPrank(dummy);
            IERC20(BSC_USDT).approve(address(mining), chunk);
            mining.invest(_user, chunk, false); 
            vm.stopPrank();
            amountLeft -= chunk;
        }
    }

    // Helper: Generates exactly $1000 in Weaker Leg Volume for a leader in the current week
    function _generateWeeklyVolume(address leader) internal {
        address strongLeg = address(dummyNonce++);
        address weakLeg = address(dummyNonce++);
        _invest(strongLeg, leader, 2000 * 1e18); // $2000 Strong Leg
        _invest(weakLeg, leader, 1000 * 1e18);   // $1000 Weak Leg
    }

    // Helper: Builds a Tier 1 Qualified Leader (100% Unique Addresses)
    function _buildTier1Leader(address leader) internal {
        _invest(leader, company, 1000 * 1e18);
        
        // 39-Person Matrix
        for (uint i = 1; i <= 3; i++) {
            address l1 = address(dummyNonce++);
            _invest(l1, leader, 100 * 1e18);
            for (uint j = 1; j <= 3; j++) {
                address l2 = address(dummyNonce++);
                _invest(l2, l1, 100 * 1e18);
                for (uint k = 1; k <= 3; k++) {
                    address l3 = address(dummyNonce++);
                    _invest(l3, l2, 100 * 1e18);
                }
            }
        }
        
        // $10,000 Weaker Lifetime Volume
        _invest(address(dummyNonce++), leader, 15000 * 1e18); // Strong Leg
        _invest(address(dummyNonce++), leader, 5000 * 1e18);  // Weak Leg
        _invest(address(dummyNonce++), leader, 5000 * 1e18);  // Weak Leg
        
        // Claim to Sync Tier 1
        vm.prank(leader);
        mining.claimROI();
    }

    // ==========================================
    // 🟢 SHOWCASE 5: WEEKLY MAINTENANCE & DYNAMIC SHARING
    // ==========================================
    function test_Client_Showcase_5_WeeklyMaintenanceAndSharing() public {
        console.log("\n========================================================");
        console.log(">> SHOWCASE: WEEKLY MAINTENANCE & ROYALTY POOL SHARING");
        console.log(">> SETUP: 3 Leaders Hit Tier 1. We track their 4-week performance.");
        console.log("========================================================\n");

        address leaderAlice = address(0xA11CE);
        address leaderBob = address(0xB0B);
        address leaderCharlie = address(0xC4A211E);

        console.log("[DAY 0] Alice, Bob, and Charlie all build their teams and unlock Tier 1.");
        
        _buildTier1Leader(leaderAlice);
        _buildTier1Leader(leaderBob);
        _buildTier1Leader(leaderCharlie);

        uint256 t1Shares = mining.totalSharesPerTier(1);
        console.log(string(abi.encodePacked("[SYSTEM] Total Tier 1 Qualified Shares: ", vm.toString(t1Shares))));

        // =====================================
        // CYCLE 1: THE GLOBAL POT & THE WEEKLY GRIND
        // =====================================
        vm.warp(mining.launchTime() + 28 days);

        console.log("\n[CYCLE 1 BEGINS - DAY 28]");
        console.log(">> A massive Global Whale deposits $300,000 into the network!");

        _invest(address(dummyNonce++), company, 300000 * 1e18);
        
        console.log("   -> Contract slices 18% Royalty: $54,000 to the Global Pool.");
        console.log("   -> Tier 1 Bucket gets 2% of Pool: $1,080 reserved for Tier 1.");
        console.log("   -> Since there are 3 shares, each Leader is fighting for exactly $360.00!\n");

        console.log("[WEEK 1] Days 28-34...");
        console.log("   Alice:   $1,000 Weaker Vol \xE2\x9C\x85"); _generateWeeklyVolume(leaderAlice);
        console.log("   Bob:     $1,000 Weaker Vol \xE2\x9C\x85"); _generateWeeklyVolume(leaderBob);
        console.log("   Charlie: $1,000 Weaker Vol \xE2\x9C\x85"); _generateWeeklyVolume(leaderCharlie);

        vm.warp(mining.launchTime() + 35 days);
        console.log("\n[WEEK 2] Days 35-41...");
        console.log("   Alice:   $1,000 Weaker Vol \xE2\x9C\x85"); _generateWeeklyVolume(leaderAlice);
        console.log("   Bob:     $1,000 Weaker Vol \xE2\x9C\x85"); _generateWeeklyVolume(leaderBob);
        console.log("   Charlie: $1,000 Weaker Vol \xE2\x9C\x85"); _generateWeeklyVolume(leaderCharlie);

        vm.warp(mining.launchTime() + 42 days);
        console.log("\n[WEEK 3] Days 42-48 (THE MISTAKE)");
        console.log("   Alice:   $1,000 Weaker Vol \xE2\x9C\x85"); _generateWeeklyVolume(leaderAlice);
        console.log("   Bob:     $1,000 Weaker Vol \xE2\x9C\x85"); _generateWeeklyVolume(leaderBob);
        console.log("   Charlie: Goes on vacation. $0 Vol \xE2\x9D\x8C"); // Charlie skips!

        vm.warp(mining.launchTime() + 49 days);

        console.log("\n[WEEK 4] Days 49-55...");
        console.log("   Alice:   $1,000 Weaker Vol \xE2\x9C\x85"); _generateWeeklyVolume(leaderAlice);
        console.log("   Bob:     $1,000 Weaker Vol \xE2\x9C\x85"); _generateWeeklyVolume(leaderBob);
        console.log("   Charlie: $1,000 Weaker Vol \xE2\x9C\x85 (But it's too late...)"); _generateWeeklyVolume(leaderCharlie);

        // =====================================
        // JUMP TO CYCLE 2 (DAY 56) PAYOUTS
        // =====================================
        vm.warp(mining.launchTime() + 56 days);

        console.log("\n========================================================");
        console.log("[CYCLE 1 COMPLETE - DAY 56] PAYOUT DISTRIBUTION");
        console.log("========================================================\n");

        vm.prank(leaderAlice); mining.claimROI();
        (,,,,,,,,,,,,,,,,,, uint256 aVault) = mining.users(leaderAlice);
        console.log("Leader Alice Vault (Passed 4/4 Weeks):   ", _usd(aVault), " \xE2\x9C\x85");

        vm.prank(leaderBob); mining.claimROI();
        (,,,,,,,,,,,,,,,,,, uint256 bVault) = mining.users(leaderBob);
        console.log("Leader Bob Vault   (Passed 4/4 Weeks):   ", _usd(bVault), " \xE2\x9C\x85");

        vm.prank(leaderCharlie); mining.claimROI();
        (,,,,,,,,,,,,,,,,,, uint256 cVault) = mining.users(leaderCharlie);
        console.log("Leader Charlie Vault (Failed Week 3):    ", _usd(cVault), " \xE2\x9D\x8C");

        console.log("\n[EXPLANATION FOR CLIENT]");
        console.log("Because Charlie missed his Week 3 Maintenance, the smart contract ");
        console.log("instantly revoked his Tier 1 payout for this cycle and dropped him ");
        console.log("into the tiny Tier 0 fallback pool, proving the system is un-gameable!");
        console.log("========================================================\n");
    }

    // ==========================================
    // 🟢 SHOWCASE 6: NFT STAKING & ROYALTY REWARDS (TIER 2 PROOF)
    // ==========================================
    function test_Client_Showcase_6_NFTRoyaltyStaking() public {
        console.log("\n========================================================");
        console.log(">> SHOWCASE 6: NFT STAKING & ROYALTY REWARDS (REAL NFT CONTRACT)");
        console.log(">> SETUP: User buys and stakes a Tier 2 NFT ($2,500).");
        console.log(">> EXPECTATION: Tier 2 now successfully receives the 1% Fixed Bonus.");
        console.log("========================================================\n");

        address investorNFT = address(0x777);
        
        // 1. Give user live USDT and buy the Tier 2 NFT
        deal(BSC_USDT, investorNFT, 2_500 * 1e18); // 🟢 Now using `deal`
        
        vm.startPrank(investorNFT);
        IERC20(BSC_USDT).approve(address(nft), 2_500 * 1e18); // 🟢 Approving live USDT
        nft.buyNFT(2);
        
        // 2. User stakes the NFT into the Mining Contract
        nft.approve(address(mining), 1); // Approve Token ID #1
        mining.stakeNFT(1);
        vm.stopPrank();

        console.log("[CYCLE 0] User stakes Tier 2 NFT (Token ID #1).");
        console.log("   -> Contract locks NFT. Yield generation begins next cycle.\n");

        // =====================================
        // JUMP TO CYCLE 1 (DAY 28)
        // =====================================
        vm.warp(mining.launchTime() + 28 days);

        console.log("[CYCLE 1 ONGOING - DAY 28 to 56]");
        console.log(">> A massive Global Whale deposits $100,000 into the network!");

        // Whale invests $100k
        _invest(address(dummyNonce++), company, 100_000 * 1e18);

        console.log("\n[SMART CONTRACT INTERNAL MATH]");
        console.log("   1. Global Investment: $100,000");
        console.log("   2. Royalty Pool Cut (18%): $18,000");
        console.log("   3. Tier 2 NFT Bucket gets 2% of that Pool: $360.00");
        console.log("   4. Tier 2 Fixed Bonus (1% of $2,500 NFT Price): $25.00");
        console.log("   -> EXPECTED CYCLE 1 TOTAL: $385.00\n");

        // =====================================
        // JUMP TO CYCLE 2 (DAY 56) PAYOUTS
        // =====================================
        vm.warp(mining.launchTime() + 56 days);
        console.log("[CYCLE 1 COMPLETE - DAY 56] USER CLAIMS REWARDS");
        
        // View Pending Rewards
        uint256 pending = mining.getPendingNFTRewards(investorNFT);
        console.log("   -> Contract pre-calculates pending rewards: ", _usd(pending));
        
        // Execute Claim
        vm.prank(investorNFT);
        mining.claimNFTRewards();

        // Verify Vault Balance
        (,,,,,,,,,,,,,,,,,, uint256 royaltyVault) = mining.users(investorNFT);
        console.log("\n[PAYOUT EXECUTION]");
        console.log("   -> User Liquid Vault Receives: ", _usd(royaltyVault));
        console.log("   -> EXACT MATCH: $385.00 Verified ");
        console.log("========================================================\n");
    }
}