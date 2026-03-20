// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {HMTMining} from "../src/HMTMining.sol";
import {HMTToken} from "../src/HMTToken.sol"; 
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

// Interfaces
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

contract HMTStakingTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    MockNFT public nft;

    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    
    address public company = address(0x100);
    address public ownerWallet = address(0x200);

    function setUp() public {
        hmt = new HMTToken(BSC_USDT, PANCAKESWAP_ROUTER);
        nft = new MockNFT();
        mining = new HMTMining(BSC_USDT, address(hmt), PANCAKESWAP_ROUTER, company, ownerWallet, address(nft));
        hmt.setMiningContract(address(mining));

        // Fund treasury to pay out rewards
        hmt.transfer(address(mining), 5_000_000 * 1e18);
    }

    function test_Staking_CompoundInterestAndPenalty() public {
        address staker = address(0x400);
        hmt.transfer(staker, 1000 * 1e18); 

        vm.startPrank(staker);
        hmt.approve(address(mining), type(uint256).max);
        
        // Stake 1000 HMT
        mining.stakeHMTTokens(1000 * 1e18);
        vm.stopPrank();

        // 1. Warp 10 Days Forward
        vm.warp(block.timestamp + 10 days);
        
        (uint256 gross, uint256 penalty, uint256 net) = mining.getStakingOverview(staker);
        
        // 1000 * (1.006)^10 = ~1061.64
        // Because it's < 30 days, penalty is 15% of 1061.64 = ~159.24
        // Net = ~902.40 (User loses money for unstaking early!)
        assertTrue(gross > 1060 * 1e18 && gross < 1062 * 1e18, "Compound logic failed for 10 days");
        assertTrue(penalty > 150 * 1e18, "15% Penalty not applied");
        assertTrue(net < 1000 * 1e18, "Net should be a loss if unstaked early");

        // 2. Warp 181 Days Forward (Passes 6 month lock)
        vm.warp(block.timestamp + 171 days); // 10 + 171 = 181 total days
        
        (uint256 finalGross, uint256 finalPenalty, uint256 finalNet) = mining.getStakingOverview(staker);
        
        // At 181 days, penalty must be exactly 0%
        assertEq(finalPenalty, 0, "Penalty not reduced to 0% after 6 months");
        assertEq(finalNet, finalGross, "Net and Gross must match exactly");
        
        // 1000 * (1.006)^181 = ~2953.50
        assertTrue(finalNet > 2950 * 1e18, "6-Month Yield Calculation Failed");

        // 3. User claims
        vm.prank(staker);
        mining.unstakeAllHMT();

        assertEq(hmt.balanceOf(staker), finalNet, "Payout not transferred accurately");
    }
}