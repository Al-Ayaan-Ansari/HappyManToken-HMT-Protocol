// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
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

contract HMTMiningForkTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    MockNFT public nft;

    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;

    address public company = address(0x100);
    address public ownerWallet = address(0x200);
    address public user1 = address(0x1);
    address public user2 = address(0x2);
    address public user3 = address(0x3);
    address public user4 = address(0x4);

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
        IPancakeRouter02Test(PANCAKESWAP_ROUTER).addLiquidity(address(hmt), BSC_USDT, hmtLiquidity, usdtLiquidity, 0, 0, company, block.timestamp + 1000);
        vm.stopPrank();

        deal(BSC_USDT, user1, 5000 * 1e18);
        deal(BSC_USDT, user2, 5000 * 1e18);
        deal(BSC_USDT, user3, 5000 * 1e18);
        deal(BSC_USDT, user4, 5000 * 1e18);
        hmt.transfer(address(mining), 1_000_000 * 1e18);
    }

    // 🟢 Safe Dummy Spawning Invest
    function _invest(address _user, address _sponsor, uint256 _totalAmount) internal {
        if (_totalAmount <= 2500 * 1e18) {
            vm.startPrank(_user);
            IERC20(BSC_USDT).approve(address(mining), _totalAmount);
            mining.invest(_sponsor, _totalAmount, false);
            vm.stopPrank();
        } else {
            vm.startPrank(_user);
            IERC20(BSC_USDT).approve(address(mining), 2500 * 1e18);
            mining.invest(_sponsor, 2500 * 1e18, false);
            vm.stopPrank();
            
            uint256 amountLeft = _totalAmount - (2500 * 1e18);
            uint160 dummySeed = uint160(_user) + 100000;
            while(amountLeft > 0) {
                uint256 chunk = amountLeft > 2500 * 1e18 ? 2500 * 1e18 : amountLeft;
                address dummy = address(dummySeed++);
                deal(BSC_USDT, dummy, chunk);
                vm.startPrank(dummy);
                IERC20(BSC_USDT).approve(address(mining), chunk);
                mining.invest(_user, chunk, false);
                vm.stopPrank();
                amountLeft -= chunk;
            }
        }
    }

    function test_DailyBaseROI() public {
        _invest(user1, company, 1000 * 1e18);
        vm.warp(block.timestamp + 24 hours);
        (uint256 pendingBase, ) = mining.getPendingROI(user1);
        assertEq(pendingBase, 6 * 1e18, "Base ROI should be exactly 6 USDT after 24 hours");
        vm.prank(user1);
        mining.claimROI();
        (,,,,,,,,,,,,,,,,, uint256 vaultBalance, ) = mining.users(user1);
        assertEq(vaultBalance, 11 * 1e18, "Vault should contain 6 USDT (Base) + 5 USDT (Airdrop)");
    }

    function test_AirdropROI_And_Penalty() public {
        _invest(user2, company, 1000 * 1e18);
        vm.warp(block.timestamp + 2 days);
        (uint256 basePending, uint256 airdropPending) = mining.getPendingROI(user2);
        assertEq(airdropPending, 10 * 1e18, "Airdrop should be 10 USDT for 2 days");
        vm.prank(user2);
        mining.withdraw(1 * 1e18);
        vm.warp(block.timestamp + 1 days);
        (, uint256 airdropPendingAfter) = mining.getPendingROI(user2);
        assertEq(airdropPendingAfter, 0, "Airdrop ROI should permanently halt after withdrawal");
    }

    function test_LevelIncome_Push() public {
        _invest(user1, company, 100 * 1e18);
        address dummy1 = address(0x101); address dummy2 = address(0x102);
        deal(BSC_USDT, dummy1, 100 * 1e18); deal(BSC_USDT, dummy2, 100 * 1e18);
        _invest(dummy1, user1, 100 * 1e18); 
        _invest(dummy2, user1, 100 * 1e18);
        _invest(user2, user1, 100 * 1e18);
        address dummy3 = address(0x201);
        deal(BSC_USDT, dummy3, 100 * 1e18);
        _invest(dummy3, user2, 100 * 1e18);
        _invest(user3, user2, 100 * 1e18);
        _invest(user4, user3, 1000 * 1e18);

        vm.warp(block.timestamp + 24 hours);
        vm.prank(user4);
        mining.claimROI();
        (,,,,,,,,,,,,,,,,, uint256 u1Vault, ) = mining.users(user1);
        (,,,,,,,,,,,,,,,,, uint256 u2Vault, ) = mining.users(user2);
        (,,,,,,,,,,,,,,,,, uint256 u3Vault, ) = mining.users(user3);

        assertEq(u3Vault, 0.9 * 1e18, "User3 should get 15% Level 1 Income");
        assertEq(u2Vault, 0.6 * 1e18, "User2 should get 10% Level 2 Income");
        assertEq(u1Vault, 0.3 * 1e18, "User1 should get 5% Level 3 Income");
    }

    function test_Withdrawal_And_Fee() public {
        _invest(user1, company, 1000 * 1e18);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(user1);
        mining.claimROI();

        uint256 initialUserBalance = IERC20(BSC_USDT).balanceOf(user1);
        uint256 initialOwnerBalance = IERC20(BSC_USDT).balanceOf(ownerWallet);

        vm.prank(user1);
        mining.withdraw(5 * 1e18);
        uint256 finalUserBalance = IERC20(BSC_USDT).balanceOf(user1);
        uint256 finalOwnerBalance = IERC20(BSC_USDT).balanceOf(ownerWallet);
        
        assertEq(finalUserBalance - initialUserBalance, 4.75 * 1e18, "User should receive 95% of withdrawal in USDT");
        assertEq(finalOwnerBalance - initialOwnerBalance, 0.25 * 1e18, "Owner should receive 5% withdrawal fee");
    }
}