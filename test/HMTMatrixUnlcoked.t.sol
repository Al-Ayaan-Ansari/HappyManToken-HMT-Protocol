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

contract HMTMatrixUnlockTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    HMT_NFT public nft;

    // Use BSC Mainnet for accurate PancakeSwap fork testing
    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;

    address public company = address(0x100);
    address public ownerWallet = address(0x200);

    function setUp() public {
        hmt = new HMTToken(BSC_USDT, PANCAKESWAP_ROUTER);
        nft = new HMT_NFT(BSC_USDT, ownerWallet);
        mining = new HMTMining(BSC_USDT, address(hmt), PANCAKESWAP_ROUTER, company, ownerWallet, address(nft));
        
        hmt.setMiningContract(address(mining));
        nft.setMiningContract(address(mining));

        // Add Initial Liquidity
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

    // Helper function to quickly invest $100 USDT for a user
    function _invest(address _user, address _sponsor) internal {
        uint256 amt = 100 * 1e18;
        deal(BSC_USDT, _user, amt);
        vm.startPrank(_user);
        IERC20(BSC_USDT).approve(address(mining), amt);
        mining.invest(_sponsor, amt, true);
        vm.stopPrank();
    }

    // ========================================================
    // 🧪 TEST 1: PROVE THAT 12 PEOPLE DOES NOT UNLOCK THE MATRIX
    // ========================================================
    function test_TwelvePeopleFailsToUnlock() public {
        address userA = address(0xA);
        _invest(userA, company);

        // --- LEVEL 1 (3 People) ---
        address b1 = address(0xB1); _invest(b1, userA);
        address b2 = address(0xB2); _invest(b2, userA);
        address b3 = address(0xB3); _invest(b3, userA);

        // --- LEVEL 2 (9 People) ---
        address c1 = address(0xC1); _invest(c1, b1);
        address c2 = address(0xC2); _invest(c2, b1);
        address c3 = address(0xC3); _invest(c3, b1);

        address c4 = address(0xC4); _invest(c4, b2);
        address c5 = address(0xC5); _invest(c5, b2);
        address c6 = address(0xC6); _invest(c6, b2);

        address c7 = address(0xC7); _invest(c7, b3);
        address c8 = address(0xC8); _invest(c8, b3);
        address c9 = address(0xC9); _invest(c9, b3);

        // Fetch User A's Profile
        (,,,,,, bool isMatrixUnlocked,,,,,,,,,,,,) = mining.users(userA);
        
        // Assert Matrix is FALSE
        assertFalse(isMatrixUnlocked, "ERROR: The Matrix unlocked at 12 people. It should be strictly 39!");
        console.log("Matrix Status at 12 People (3x3): LOCKED");
    }

    // ========================================================
    // 🧪 TEST 2: PROVE THAT EXACTLY 39 PEOPLE UNLOCKS THE MATRIX
    // ========================================================
    function test_ThirtyNinePeopleUnlocksMatrix() public {
        address userA = address(0xA);
        _invest(userA, company);

        // --- LEVEL 1 (3 People) ---
        address b1 = address(0xB1); _invest(b1, userA);
        address b2 = address(0xB2); _invest(b2, userA);
        address b3 = address(0xB3); _invest(b3, userA);

        // --- LEVEL 2 (9 People) ---
        address c1 = address(0xC1); _invest(c1, b1);
        address c2 = address(0xC2); _invest(c2, b1);
        address c3 = address(0xC3); _invest(c3, b1);

        address c4 = address(0xC4); _invest(c4, b2);
        address c5 = address(0xC5); _invest(c5, b2);
        address c6 = address(0xC6); _invest(c6, b2);

        address c7 = address(0xC7); _invest(c7, b3);
        address c8 = address(0xC8); _invest(c8, b3);
        address c9 = address(0xC9); _invest(c9, b3);

        // --- LEVEL 3 (27 People) ---
        // C1, C2, C3 each get 3
        _invest(address(0xD1), c1); _invest(address(0xD2), c1); _invest(address(0xD3), c1);
        _invest(address(0xD4), c2); _invest(address(0xD5), c2); _invest(address(0xD6), c2);
        _invest(address(0xD7), c3); _invest(address(0xD8), c3); _invest(address(0xD9), c3);

        // C4, C5, C6 each get 3
        _invest(address(0xD10), c4); _invest(address(0xD11), c4); _invest(address(0xD12), c4);
        _invest(address(0xD13), c5); _invest(address(0xD14), c5); _invest(address(0xD15), c5);
        _invest(address(0xD16), c6); _invest(address(0xD17), c6); _invest(address(0xD18), c6);

        // C7, C8, C9 each get 3
        _invest(address(0xD19), c7); _invest(address(0xD20), c7); _invest(address(0xD21), c7);
        _invest(address(0xD22), c8); _invest(address(0xD23), c8); _invest(address(0xD24), c8);
        _invest(address(0xD25), c9); _invest(address(0xD26), c9); _invest(address(0xD27), c9);

        // Fetch User A's Profile again
        (,,,,,, bool isMatrixUnlocked,,,,,,,,,,,,) = mining.users(userA);
        
        // Assert Matrix is TRUE
        assertTrue(isMatrixUnlocked, "ERROR: The Matrix failed to unlock at 39 people!");
        console.log("Matrix Status at 39 People (3x3x3): UNLOCKED!");
    }
}