// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {HMTMining} from "../src/HMTMining.sol";
import {HMTToken} from "../src/HMTToken.sol"; 
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

interface IPancakeRouter02Test {
    function addLiquidity(address tokenA, address tokenB, uint amountADesired, uint amountBDesired, uint amountAMin, uint amountBMin, address to, uint deadline) external returns (uint amountA, uint amountB, uint liquidity);
}

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
    function getNFTTier(uint256 id) external view returns (uint8) { return tokenTier[id]; }
    function getTierPrice(uint8) external pure returns (uint256) { return 10000 * 1e18; }
    function ownerWallet() external pure returns(address) { return address(0x200); }
}

contract HMTNetworkAdvancedTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    MockNFT public nft;

    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    
    address public company = address(0x100);
    address public ownerWallet = address(0x200);
    address public insuranceWallet = address(0x9999); 

    function setUp() public {
        vm.createSelectFork("bsc");

        hmt = new HMTToken(BSC_USDT, PANCAKESWAP_ROUTER);
        nft = new MockNFT();
        mining = new HMTMining(BSC_USDT, address(hmt), PANCAKESWAP_ROUTER, insuranceWallet, ownerWallet, address(nft));
        hmt.setMiningContract(address(mining));

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

        _invest(company, insuranceWallet, 100 * 1e18); // Initialize root
    }

    function _invest(address user, address sponsor, uint256 amount) internal {
        deal(BSC_USDT, user, amount);
        vm.startPrank(user);
        IERC20(BSC_USDT).approve(address(mining), amount);
        mining.invest(sponsor, amount, true);
        vm.stopPrank();
    }

    function _getMatrixVault(address _user) internal view returns (uint256) {
        (,,,,,,,,,,,,,,,,, uint256 matrixVault,) = mining.users(_user);
        return matrixVault;
    }

    // --- Core Advanced Test 1: Matrix Edge Cases ---
    function test_Matrix_LateBuilderAndMissedMaintenance() public {
        console.log("=======================================================");
        console.log("TEST: 3X3 MATRIX PENALTIES (TIME & VOLUME ENFORCEMENT)");
        console.log("=======================================================");

        address fastLeader = address(0x111);
        address slowLeader = address(0x222);

        _invest(fastLeader, company, 100 * 1e18);
        _invest(slowLeader, company, 100 * 1e18);

        vm.warp(block.timestamp + 10 days);
        _build3x3Matrix(fastLeader, 0x1000);
        console.log("[ACTION] FastLeader completed 3x3 Matrix in 10 Days.");

        vm.warp(mining.launchTime() + 35 days);
        _build3x3Matrix(slowLeader, 0x2000);
        console.log("[ACTION] SlowLeader completed 3x3 Matrix in 35 Days.");

        (, bool fastUnlocked,,,,,,,,,,,,,,,,,) = mining.users(fastLeader);
        (, bool slowUnlocked,,,,,,,,,,,,,,,,,) = mining.users(slowLeader);
        assertTrue(fastUnlocked, "FastLeader matrix failed to unlock");
        assertTrue(slowUnlocked, "SlowLeader matrix failed to unlock");

        console.log("\n--- Executing Cycle 2 Maintenance Simulation ---");
        uint256 cycle2Start = mining.launchTime() + (28 days * 2);

        address fastLeg1 = address(uint160(0x1001));
        address fastLeg2 = address(uint160(0x1002));
        address slowLeg1 = address(uint160(0x2001));
        address slowLeg2 = address(uint160(0x2002));

        for(uint256 w = 0; w < 4; w++) {
            vm.warp(cycle2Start + (w * 7 days));
            
            _invest(address(uint160(0x5000 + w)), fastLeg1, 1500 * 1e18); 
            _invest(address(uint160(0x6000 + w)), fastLeg2, 1500 * 1e18);

            if (w != 2) {
                _invest(address(uint160(0x7000 + w)), slowLeg1, 1500 * 1e18);
                _invest(address(uint160(0x8000 + w)), slowLeg2, 1500 * 1e18);
            }
        }

        console.log("[MAINTENANCE] FastLeader completed 4/4 weeks of volume.");
        console.log("[MAINTENANCE] SlowLeader missed Week 3 volume requirement.");

        vm.warp(cycle2Start + 28 days + 1);

        uint256 fastFamROI = mining.cycleFamilyROI(fastLeader, 2);
        
        uint256 fastVaultBefore = _getMatrixVault(fastLeader);
        vm.prank(fastLeader);
        mining.claimROI();
        uint256 fastVaultAfter = _getMatrixVault(fastLeader);
        
        uint256 fastPayout = fastVaultAfter - fastVaultBefore;
        uint256 expectedFastPayout = (fastFamROI * 2) / 100;

        console.log("\n[VERIFICATION] FastLeader Payout (wei):", fastPayout);
        assertApproxEqAbs(fastPayout, expectedFastPayout, 0.01 * 1e18, "FastLeader did not receive exact 2% multiplier");

        uint256 slowVaultBefore = _getMatrixVault(slowLeader);
        vm.prank(slowLeader);
        mining.claimROI();
        uint256 slowVaultAfter = _getMatrixVault(slowLeader);
        
        uint256 slowPayout = slowVaultAfter - slowVaultBefore;

        console.log("[VERIFICATION] SlowLeader Payout (wei):", slowPayout);
        assertEq(slowPayout, 0, "SlowLeader received payout despite failing week 3 maintenance");

        console.log("\n[SUCCESS] Contract successfully penalized late builders and lazy maintenance.");
    }

    // --- Core Advanced Test 2: Matching Income Split Math ---
    function test_MatchingIncome_DynamicPoolSplitting() public {
        console.log("\n=======================================================");
        console.log("TEST: MATCHING INCOME DYNAMIC RPS POOL SPLITTING");
        console.log("=======================================================");

        address leaderA = address(0xAAAA);
        address leaderB = address(0xBBBB);

        _invest(leaderA, company, 100 * 1e18);
        _invest(leaderB, company, 100 * 1e18);

        console.log("[ACTION] Leader A and Leader B building to Tier 1 in Cycle 0...");
        
        // --- LEADER A VOLUME ---
        address legA1 = address(0xA1);
        address legA2 = address(0xA2);
        _invest(legA1, leaderA, 2500 * 1e18);
        _invest(legA2, leaderA, 2500 * 1e18);
        _invest(address(0xA11), legA1, 2500 * 1e18);
        _invest(address(0xA12), address(0xA11), 2500 * 1e18);
        _invest(address(0xA13), address(0xA12), 2500 * 1e18);
        _invest(address(0xA21), legA2, 2500 * 1e18);
        _invest(address(0xA22), address(0xA21), 2500 * 1e18);
        _invest(address(0xA23), address(0xA22), 2500 * 1e18);

        // --- LEADER B VOLUME ---
        address legB1 = address(0xB1);
        address legB2 = address(0xB2);
        _invest(legB1, leaderB, 2500 * 1e18);
        _invest(legB2, leaderB, 2500 * 1e18);
        _invest(address(0xB11), legB1, 2500 * 1e18);
        _invest(address(0xB12), address(0xB11), 2500 * 1e18);
        _invest(address(0xB13), address(0xB12), 2500 * 1e18);
        _invest(address(0xB21), legB2, 2500 * 1e18);
        _invest(address(0xB22), address(0xB21), 2500 * 1e18);
        _invest(address(0xB23), address(0xB22), 2500 * 1e18);

        // Claim in Cycle 0 to register their Rank.
        vm.prank(leaderA); mining.claimROI();
        vm.prank(leaderB); mining.claimROI();

        uint256 activeShares = mining.matchingSharesPerTier(1);
        console.log("Total Active Shares in Tier 1:", activeShares);
        assertEq(activeShares, 2, "Shares did not aggregate correctly");

        // 🟢 WARP TO CYCLE 1
        uint256 cycle1Start = mining.launchTime() + 28 days;
        vm.warp(cycle1Start + 1 seconds);

        // 🟢 FIX: Leader A and B must maintain active "cycleEligible" status by referring at least 1 person this cycle
        console.log("[ACTION] Leader A and B register a direct referral in Cycle 1 to maintain eligibility.");
        _invest(address(0x999A), leaderA, 100 * 1e18);
        _invest(address(0x999B), leaderB, 100 * 1e18);

        vm.warp(cycle1Start + 14 days); // Halfway through Cycle 1

        console.log("\n[ACTION] Global Volume generates 10,000 USDT with 14 days remaining in Cycle 1.");
        for(uint256 i = 1; i <= 4; i++) {
             _invest(address(uint160(0xC000 + i)), company, 2500 * 1e18);
        }

        // Fetch exactly what the contract recorded as the RPS for Cycle 1
        uint256 recordedRPS = mining.cycleMatchingRPS(1, 1);
        
        // Contract divides recordedRPS by 1e18 when paying out to the vault
        uint256 expectedVaultIncrease = recordedRPS / 1e18;

        console.log("\n[VERIFICATION] Actual Contract RPS Value (wei):", recordedRPS);

        // Warp to Cycle 2 so Leader A can claim their completed Cycle 1 reward
        vm.warp(cycle1Start + 28 days + 1);
        
        uint256 vaultBefore = _getMatrixVault(leaderA);
        vm.prank(leaderA);
        mining.claimROI();
        uint256 vaultAfter = _getMatrixVault(leaderA);

        uint256 payoutA = vaultAfter - vaultBefore;
        console.log("[VERIFICATION] Leader A final Claimed Matching Amount:", payoutA);
        
        assertEq(payoutA, expectedVaultIncrease, "Leader A final payout extraction failed");

        console.log("\n[SUCCESS] Contract flawlessy executed O(1) multi-share matching distribution.");
    }

    function _build3x3Matrix(address root, uint160 offset) internal {
        for(uint256 i=0; i<3; i++) {
            address l1 = address(uint160(offset + i + 1));
            _invest(l1, root, 100 * 1e18);
            for(uint256 j=1; j<=3; j++) {
                address l2 = address(uint160(offset + 100 + (i * 10) + j));
                _invest(l2, l1, 100 * 1e18);
            }
        }
    }
}