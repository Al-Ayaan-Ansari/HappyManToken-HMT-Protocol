// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {HMTMining} from "../src/HMTMining.sol";
import {HMTToken} from "../src/HMTToken.sol"; 
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

// --- INTERFACES & MOCKS ---
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

// --- TEST SUITE ---
contract HMTLotteryTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    MockNFT public nft;

    // Real BSC Mainnet Addresses
    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    
    address public company = address(0x100);
    address public ownerWallet = address(0x200);

    uint160 private dummyNonce = 5000000;

    function setUp() public {
        // 1. Deploy Core Contracts
        hmt = new HMTToken(BSC_USDT, PANCAKESWAP_ROUTER);
        nft = new MockNFT();
        mining = new HMTMining(BSC_USDT, address(hmt), PANCAKESWAP_ROUTER, company, ownerWallet, address(nft));
        hmt.setMiningContract(address(mining));

        // 2. Setup Balanced Liquidity ($1.00 per HMT)
        // By making it 1:1, we ensure the Oracle doesn't demand 82 Million tokens!
        uint256 hmtLiquidity = 1_000_000 * 1e18;  // 1 Million HMT
        uint256 usdtLiquidity = 1_000_000 * 1e18; // 1 Million USDT
        uint256 ownerShare = 2_100_100 * 1e18;

        deal(BSC_USDT, company, usdtLiquidity);
        hmt.transfer(company, hmtLiquidity); 
        hmt.transfer(address(mining), ownerShare);

        vm.startPrank(company);
        IERC20(BSC_USDT).approve(PANCAKESWAP_ROUTER, usdtLiquidity);
        hmt.approve(PANCAKESWAP_ROUTER, hmtLiquidity);
        
        // Inject Liquidity
        IPancakeRouter02Test(PANCAKESWAP_ROUTER).addLiquidity(
            address(hmt), BSC_USDT, hmtLiquidity, usdtLiquidity, 0, 0, company, block.timestamp + 1000 
        );
        vm.stopPrank();
        
        // 3. Send ALL remaining HMT to the Mining Contract for Lottery Payouts
        // (Roughly ~17.8 Million tokens left over)
        uint256 remainingHMT = hmt.balanceOf(address(this));
        hmt.transfer(address(mining), remainingHMT);
    }

    // 🟢 Helper: Simulates a user getting USDT and entering the lottery
    function _enterLottery(address _user) internal {
        deal(BSC_USDT, _user, 100 * 1e18); // Give exactly 100 USDT
        vm.startPrank(_user);
        IERC20(BSC_USDT).approve(address(mining), 100 * 1e18);
        mining.enterLottery();
        vm.stopPrank();
    }

    // ==========================================
    // 🧪 THE TESTS
    // ==========================================

    function test_Lottery_EntryTakesUSDTAndUpdatesState() public {
        address user1 = address(0x999);
        _enterLottery(user1);

        // Verify USDT was successfully taken
        assertEq(IERC20(BSC_USDT).balanceOf(user1), 0, "USDT fee was not deducted");

        // Verify Pool State
        (uint256 startTime, bool isResolved) = mining.lotteryPools(1);
        assertEq(startTime, block.timestamp, "Start time should be set for the first user");
        assertFalse(isResolved, "Pool should not be resolved yet");
        assertTrue(mining.poolHasEntered(1, user1), "User not marked as entered");
    }

    function test_Lottery_RevertIfSameWalletEntersTwice() public {
        address whale = address(0x999);
        _enterLottery(whale);

        deal(BSC_USDT, whale, 100 * 1e18);
        vm.startPrank(whale);
        IERC20(BSC_USDT).approve(address(mining), 100 * 1e18);
        
        vm.expectRevert("You have already entered this pool");
        mining.enterLottery();
        vm.stopPrank();
    }

    function test_Lottery_PoolAutoRolloverAt100Participants() public {
        assertEq(mining.currentLotteryId(), 1, "Should start at pool 1");

        // Fill Pool 1 with 100 unique users
        for (uint160 i = 1; i <= 100; i++) {
            _enterLottery(address(dummyNonce + i));
        }

        // The ID should have instantly ticked over
        assertEq(mining.currentLotteryId(), 2, "Failed to rollover to pool 2");

        // Ensure 101st user goes into Pool 2 safely
        address user101 = address(dummyNonce + 101);
        _enterLottery(user101);
        assertTrue(mining.poolHasEntered(2, user101), "User 101 was not placed in Pool 2");
    }

    function test_Lottery_RevertIfResolvedTooEarly() public {
        // Fill pool 1
        for (uint160 i = 1; i <= 100; i++) {
            _enterLottery(address(dummyNonce + i));
        }

        // Try to crank the heavy resolver immediately
        vm.expectRevert("45 days have not passed for the next pool");
        mining.resolveReadyLottery();

        // Warp 44 days
        vm.warp(block.timestamp + 44 days);
        vm.expectRevert("45 days have not passed for the next pool");
        mining.resolveReadyLottery();
    }

    function test_Lottery_HeavyResolverAndDynamicOracleMath() public {
        // 1. Create 100 unique users and push them into the array
        address[] memory players = new address[](100);
        for (uint160 i = 0; i < 100; i++) {
            players[i] = address(dummyNonce + i);
            _enterLottery(players[i]);
        }

        // 2. Warp 45 Days to mature the pool
        vm.warp(block.timestamp + 45 days);

        // 3. Anyone calls the heavy resolver
        mining.resolveReadyLottery();

        // 4. Verify the state shifted to the next pool
        assertEq(mining.lastResolvedLotteryId(), 2, "Resolver crank did not advance");

        // 5. Pre-calculate exact HMT expected payouts using the live AMM Oracle
        uint256 expected400 = hmt.getHMTForUSDT(400 * 1e18);
        uint256 expected200 = hmt.getHMTForUSDT(200 * 1e18);
        uint256 expected150 = hmt.getHMTForUSDT(150 * 1e18);
        uint256 expected100 = hmt.getHMTForUSDT(100 * 1e18);

        uint256 count400 = 0;
        uint256 count200 = 0;
        uint256 count150 = 0;
        uint256 count100 = 0;

        // 6. Loop through all 100 users and verify their exact HMT balances match the Oracle
        for (uint256 i = 0; i < 100; i++) {
            uint256 balance = hmt.balanceOf(players[i]);

            if (balance == expected400) count400++;
            else if (balance == expected200) count200++;
            else if (balance == expected150) count150++;
            else if (balance == expected100) count100++;
            else {
                console.log("CRITICAL FAILURE: User received unknown amount: ", balance);
            }
        }

        console.log("=== REAL AMM LOTTERY PAYOUTS ===");
        console.log("HMT Payout for $400: ", expected400 / 1e18);
        console.log("HMT Payout for $200: ", expected200 / 1e18);
        console.log("HMT Payout for $150: ", expected150 / 1e18);
        console.log("HMT Payout for $100: ", expected100 / 1e18);

        // 7. Verify the Fisher-Yates shuffle distributed the exact count of each prize tier
        assertEq(count400, 5, "Incorrect number of $400 winners");
        assertEq(count200, 5, "Incorrect number of $200 winners");
        assertEq(count150, 40, "Incorrect number of $150 winners");
        assertEq(count100, 50, "Incorrect number of $100 winners");
    }
}