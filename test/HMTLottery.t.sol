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
    function getNFTTier(uint256 id) external view returns (uint8) { return tokenTier[id]; }
    function getTierPrice(uint8) external pure returns (uint256) { return 10000 * 1e18; }
}

contract HMTLotteryTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    MockNFT public nft;

    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    
    address public company = address(0x100);
    address public ownerWallet = address(0x200);

    uint160 private dummyNonce = 5000000;

    function setUp() public {
        hmt = new HMTToken(BSC_USDT, PANCAKESWAP_ROUTER);
        nft = new MockNFT();
        mining = new HMTMining(BSC_USDT, address(hmt), PANCAKESWAP_ROUTER, company, ownerWallet, address(nft));
        hmt.setMiningContract(address(mining));
        
        uint256 hmtLiquidity = 1_000_000 * 1e18;  
        uint256 usdtLiquidity = 1_000_000 * 1e18;
        uint256 ownerShare = 2_100_100 * 1e18;

        deal(BSC_USDT, company, usdtLiquidity);
        hmt.transfer(company, hmtLiquidity); 
        hmt.transfer(address(mining), ownerShare);

        vm.startPrank(company);
        IERC20(BSC_USDT).approve(PANCAKESWAP_ROUTER, usdtLiquidity);
        hmt.approve(PANCAKESWAP_ROUTER, hmtLiquidity);
        
        IPancakeRouter02Test(PANCAKESWAP_ROUTER).addLiquidity(
            address(hmt), BSC_USDT, hmtLiquidity, usdtLiquidity, 0, 0, company, block.timestamp + 1000 
        );
        vm.stopPrank();
        
        uint256 remainingHMT = hmt.balanceOf(address(this));
        hmt.transfer(address(mining), remainingHMT);
    }

    function _enterLottery(address _user) internal {
        deal(BSC_USDT, _user, 100 * 1e18);
        vm.startPrank(_user);
        IERC20(BSC_USDT).approve(address(mining), 100 * 1e18);
        mining.enterLottery();
        vm.stopPrank();
    }

    function test_Lottery_EntryTakesUSDTAndUpdatesState() public {
        address user1 = address(0x999);
        _enterLottery(user1);

        assertEq(IERC20(BSC_USDT).balanceOf(user1), 0, "USDT fee was not deducted");
        
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
        
        // 🟢 FIXED: Expecting Custom Error
        vm.expectRevert(abi.encodeWithSignature("AlreadyEntered()"));
        mining.enterLottery();
        vm.stopPrank();
    }

    function test_Lottery_PoolAutoRolloverAt100Participants() public {
        assertEq(mining.currentLotteryId(), 1, "Should start at pool 1");
        
        for (uint160 i = 1; i <= 100; i++) {
            _enterLottery(address(dummyNonce + i));
        }

        assertEq(mining.currentLotteryId(), 2, "Failed to rollover to pool 2");
        
        address user101 = address(dummyNonce + 101);
        _enterLottery(user101);
        assertTrue(mining.poolHasEntered(2, user101), "User 101 was not placed in Pool 2");
    }

    function test_Lottery_RevertIfResolvedTooEarly() public {
        for (uint160 i = 1; i <= 100; i++) {
            _enterLottery(address(dummyNonce + i));
        }

        // 🟢 FIXED: Expecting Custom Error
vm.expectRevert(abi.encodeWithSignature("LotteryNotReady()"));
        mining.resolveReadyLottery();

        vm.warp(block.timestamp + 44 days);
        
        // 🟢 FIXED: Expecting Custom Error
vm.expectRevert(abi.encodeWithSignature("LotteryNotReady()"));
        mining.resolveReadyLottery();
    }

    function test_Lottery_HeavyResolverAndDynamicOracleMath() public {
        address[] memory players = new address[](100);
        for (uint160 i = 0; i < 100; i++) {
            players[i] = address(dummyNonce + i);
            _enterLottery(players[i]);
        }

        vm.warp(block.timestamp + 45 days);
        mining.resolveReadyLottery();
        assertEq(mining.lastResolvedLotteryId(), 2, "Resolver crank did not advance");
        
      // 🟢 FIXED: The test must now expect the Base Rate Multiplier math!
        uint256 baseRate = hmt.getHMTForUSDT(1e18);
        uint256 expected400 = baseRate * 400;
        uint256 expected200 = baseRate * 200;
        uint256 expected150 = baseRate * 150;
        uint256 expected100 = baseRate * 100;

        uint256 count400 = 0;
        uint256 count200 = 0;
        uint256 count150 = 0;
        uint256 count100 = 0;

        for (uint i = 0; i < 100; i++) {
            uint256 bal = hmt.balanceOf(players[i]);
            if (bal == expected400) count400++;
            else if (bal == expected200) count200++;
            else if (bal == expected150) count150++;
            else if (bal == expected100) count100++;
            else {
                console.log("CRITICAL FAILURE: User received unknown amount: ", bal);
            }
        }

        console.log("=== REAL AMM LOTTERY PAYOUTS ===");
        console.log("HMT Payout for $400: ", expected400 / 1e18);
        console.log("HMT Payout for $200: ", expected200 / 1e18);
        console.log("HMT Payout for $150: ", expected150 / 1e18);
        console.log("HMT Payout for $100: ", expected100 / 1e18);

        assertEq(count400, 5, "Incorrect number of $400 winners");
        assertEq(count200, 5, "Incorrect number of $200 winners");
        assertEq(count150, 40, "Incorrect number of $150 winners");
        assertEq(count100, 50, "Incorrect number of $100 winners");
    }
}