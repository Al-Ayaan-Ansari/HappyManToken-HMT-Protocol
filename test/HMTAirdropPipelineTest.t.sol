// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

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
    function getNFTTier(uint256 id) external view returns (uint8) { return tokenTier[id]; }
    function getTierPrice(uint8) external pure returns (uint256) { return 10000 * 1e18; }
}

contract HMTAirdropPipelineTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    MockNFT public nft;

    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    
    address public company = address(0x100);
    address public ownerWallet = address(0x200);

    address public user1 = address(0x111);
    address public user2 = address(0x222);

    uint160 private dummyNonce = 5000000;

    function setUp() public {
        hmt = new HMTToken(BSC_USDT, PANCAKESWAP_ROUTER);
        nft = new MockNFT();
        mining = new HMTMining(BSC_USDT, address(hmt), PANCAKESWAP_ROUTER, company, ownerWallet, address(nft));
        hmt.setMiningContract(address(mining));

        uint256 hmtLiquidity = 1000 * 1e18;
        uint256 usdtLiquidity = 5000 * 1e18;     

        deal(BSC_USDT, company, usdtLiquidity);
        hmt.transfer(company, hmtLiquidity); 
        hmt.transfer(address(mining), 2_100_100 * 1e18);

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
    // 🧪 TEST 1: THE HAPPY PATH (PERFECT PIPELINE)
    // ==========================================
    function test_Airdrop_HappyPath() public {
        console.log("-----------------------------------------");
        console.log("TEST 1: Perfect Maintenance Pipeline");
        
        _invest(user1, company, 1000 * 1e18);
        
        address referral = address(0x333);
        _invest(referral, user1, 100 * 1e18); // Unlocks Cycle 1
        
        assertTrue(mining.isAirdropUnlockedForNextCycle(user1), "Cycle 1 did not unlock");

        vm.warp(mining.launchTime() + 56 days); // Jumps to Cycle 2 so Cycle 1 is complete

        (, uint256 airdropPending) = mining.getPendingROI(user1);
        
        console.log("Pending Airdrop after 1 active cycle: $", airdropPending / 1e18);
        assertEq(airdropPending, 28 * 1e18, "Did not receive exactly 2.8% of $1000");
    }

    // ==========================================
    // 🧪 TEST 2: MID-CYCLE DAILY SNAPSHOT (CLIENT REQUIREMENT)
    // ==========================================
    function test_Airdrop_MidCycleDailySnapshot() public {
        console.log("-----------------------------------------");
        console.log("TEST 2: Exact Daily Accumulation Mid-Cycle");

        _invest(user1, company, 1000 * 1e18);
        _invest(address(dummyNonce++), user1, 100 * 1e18); // Unlocks Cycle 1

        // Warp to Day 40. This is exactly 12 days into Cycle 1.
        vm.warp(mining.launchTime() + 40 days);

        // User tops up $1000 mid-cycle. Their total becomes $2000.
        // Before topping up, the contract internally snapshots: 12 days * 0.1% * $1000 = $12 earned.
        _invest(user1, company, 1000 * 1e18);

        // Warp to Day 56 (End of Cycle 1).
        // The remaining 16 days calculate on the new $2000 balance: 16 days * 0.1% * $2000 = $32 earned.
        // Total Cycle 1 Payout should be EXACTLY $44.00 ($12 + $32).
        vm.warp(mining.launchTime() + 56 days);

        (, uint256 airdropPending) = mining.getPendingROI(user1);
        
        console.log("Pending Airdrop for 12 days @ $1000 + 16 days @ $2000: $", airdropPending / 1e18);
        assertEq(airdropPending, 44 * 1e18, "Daily accumulator math is flawed");
    }

    // ==========================================
    // 🧪 TEST 3: LAPSE & RECOVERY
    // ==========================================
    function test_Airdrop_LapseAndRecovery() public {
        console.log("-----------------------------------------");
        console.log("TEST 3: The Lapse Penalty & Recovery");

        _invest(user1, company, 1000 * 1e18);
        _invest(address(dummyNonce++), user1, 100 * 1e18); // Unlocks Cycle 1

        vm.warp(mining.launchTime() + 28 days); // Cycle 1 Starts. User gets 0 referrals this month.

        vm.warp(mining.launchTime() + 56 days); // Cycle 2 Starts.
        vm.prank(user1);
        mining.claimROI(); // Claim Cycle 1
        
        vm.warp(mining.launchTime() + 84 days); // Cycle 3 Starts. Cycle 2 ends.
        (, uint256 airdropPendingC2) = mining.getPendingROI(user1);
        
        console.log("Pending Airdrop for Lapsed Cycle 2: $", airdropPendingC2 / 1e18);
        assertEq(airdropPendingC2, 0, "Lapse penalty failed. User earned without a referral!");

        _invest(address(dummyNonce++), user1, 100 * 1e18); // Unlocks Cycle 4

        vm.warp(mining.launchTime() + 140 days); // Cycle 5 Starts. Cycle 4 ends.
        (, uint256 airdropPendingC4) = mining.getPendingROI(user1);

        console.log("Pending Airdrop for Recovered Cycle 4: $", airdropPendingC4 / 1e18);
        assertEq(airdropPendingC4, 28 * 1e18, "Recovery failed. Pipeline did not restart.");
    }

    // ==========================================
    // 🧪 TEST 4: THE ULTIMATE WITHDRAWAL PENALTY
    // ==========================================
    function test_Airdrop_PermanentWithdrawalPenalty() public {
        console.log("-----------------------------------------");
        console.log("TEST 4: The Diamond Hand Permanent Penalty");

        _invest(user1, company, 1000 * 1e18);
        _invest(address(dummyNonce++), user1, 100 * 1e18); // Unlocks C1
        
        vm.warp(mining.launchTime() + 56 days); // C2 Starts
        
        vm.prank(user1);
        mining.claimROI(); 
        
        vm.prank(user1);
        mining.withdraw(10 * 1e18, true); // true = Withdraw from Airdrop Vault

        (,,,,,,,,,,,,,,, bool hasWithdrawn,,,,) = mining.users(user1);
        assertTrue(hasWithdrawn, "hasWithdrawn flag not triggered");

        _invest(address(dummyNonce++), user1, 100 * 1e18);
        vm.warp(mining.launchTime() + 150 days); 
        
        (, uint256 airdropPending) = mining.getPendingROI(user1);
        
        console.log("Pending Airdrop after Withdrawal Penalty: $", airdropPending / 1e18);
        assertEq(airdropPending, 0, "User continued earning after withdrawing airdrop!");
    }

    // ==========================================
    // 🧪 TEST 5: UNDERFUNDED FAILS
    // ==========================================
    function test_Airdrop_UnderfundedChecks() public {
        // Test A: Sponsor is underfunded ($99)
        _invest(user1, company, 99 * 1e18);
        _invest(address(dummyNonce++), user1, 100 * 1e18); 
        
        vm.warp(mining.launchTime() + 56 days);
        (, uint256 pendingA) = mining.getPendingROI(user1);
        assertEq(pendingA, 0, "Sponsor with < $100 earned airdrop");

        // Test B: Referral is underfunded ($99)
        _invest(user2, company, 1000 * 1e18);
        _invest(address(dummyNonce++), user2, 99 * 1e18); 
        
        vm.warp(mining.launchTime() + 56 days);
        (, uint256 pendingB) = mining.getPendingROI(user2);
        assertEq(pendingB, 0, "Referral with < $100 unlocked the pipeline");
    }

    // ==========================================
    // 🧪 TEST 6: THE 5x HARD CAP
    // ==========================================
    function test_Airdrop_5xHardCap() public {
        console.log("-----------------------------------------");
        console.log("TEST 6: 16-Year Simulation (500% Hard Cap)");

        _invest(user1, company, 100 * 1e18);

        for(uint160 i = 0; i < 200; i++) {
            address dummy = address(dummyNonce + i);
            _invest(dummy, user1, 100 * 1e18); 
            vm.warp(mining.launchTime() + ((i + 1) * 28 days));
        }

        (, uint256 airdropPending) = mining.getPendingROI(user1);
        
        console.log("Airdrop Pending after 200 Cycles: $", airdropPending / 1e18);
        assertEq(airdropPending, 500 * 1e18, "Airdrop did not strictly hard-cap at 5x total investment!");
    }
}