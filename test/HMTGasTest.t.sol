// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import "forge-std/console.sol"; 
import {HMTMining} from "../src/HMTMining.sol";
import "../src/HMTToken.sol"; 
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

interface IPancakeRouter02Test {
    function addLiquidity(address tokenA, address tokenB, uint amountADesired, uint amountBDesired, uint amountAMin, uint amountBMin, address to, uint deadline) external returns (uint amountA, uint amountB, uint liquidity);
}

// 🟢 Upgraded MockNFT
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

contract HMTGasTest is Test {
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

        uint256 hmtLiquidity = 14_700_000 * 1e18;
        uint256 ownerShare = 2_100_100 * 1e18;
        uint256 usdtLiquidity = 2500 * 1e18;     

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
        
        hmt.transfer(address(mining), 1_000_000 * 1e18);
    }

    function test_NormalUserGasCosts() public {
        address normalUser = address(0x12345);
        deal(BSC_USDT, normalUser, 1000 * 1e18); 

        vm.startPrank(normalUser);
        IERC20(BSC_USDT).approve(address(mining), type(uint256).max);

        uint256 gasBeforeInvest = gasleft();
        mining.invest(company, 100 * 1e18, false); // boolean parameter unchanged for testing
        uint256 gasUsedInvest = gasBeforeInvest - gasleft();
        
        console.log("-----------------------------------------");
        console.log(" GAS USED FOR FIRST INVEST: ", gasUsedInvest);

        vm.warp(block.timestamp + 10 days);

        uint256 gasBeforeClaim = gasleft();
        mining.claimROI();
        uint256 gasUsedClaim = gasBeforeClaim - gasleft();
        
        console.log(" GAS USED FOR CLAIM ROI:    ", gasUsedClaim);

        vm.warp(block.timestamp + 10 days);

        // 🟢 UPDATED: Unpacks dual-vault return tuple
        (uint256 available, ) = mining.getTotalWithdrawable(normalUser);
        
        uint256 gasBeforeWithdraw = gasleft();
        mining.withdraw(available, false); // 🟢 UPDATED: Requires boolean parameter
        uint256 gasUsedWithdraw = gasBeforeWithdraw - gasleft();
        
        console.log(" GAS USED FOR WITHDRAWAL:   ", gasUsedWithdraw);
        console.log("-----------------------------------------");

        vm.stopPrank();
        assertTrue(gasUsedInvest > 0);
    }
}