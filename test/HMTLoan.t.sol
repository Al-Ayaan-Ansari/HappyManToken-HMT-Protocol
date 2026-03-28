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
    function swapExactTokensForTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external returns (uint[] memory amounts);
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

contract HMTLoanTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    MockNFT public nft;

    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    
    address public company = address(0x100);
    address public ownerWallet = address(0x200);
    address public whale = address(0x999); 

    uint160 private dummyNonce = 1000000;

    function setUp() public {
        hmt = new HMTToken(BSC_USDT, PANCAKESWAP_ROUTER);
        nft = new MockNFT();
        mining = new HMTMining(BSC_USDT, address(hmt), PANCAKESWAP_ROUTER, company, ownerWallet, address(nft));
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

        deal(BSC_USDT, address(mining), 500_000 * 1e18);
        hmt.transfer(whale, 10_000_000 * 1e18);
    }

    function _crashHMTPrice() internal {
        vm.startPrank(whale);
        hmt.approve(PANCAKESWAP_ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = address(hmt);
        path[1] = BSC_USDT;
        IPancakeRouter02Test(PANCAKESWAP_ROUTER).swapExactTokensForTokens(
            1_500_000 * 1e18, 0, path, whale, block.timestamp + 1000
        );
        vm.stopPrank();
    }

    function test_Loan_TakingLoanWorksAndEnforcesLTV() public {
        address borrower = address(dummyNonce + 100);
        hmt.transfer(borrower, 1000 * 1e18);

        vm.startPrank(borrower);
        hmt.approve(address(mining), 1000 * 1e18);
        
        uint256 usdtBalanceBefore = IERC20(BSC_USDT).balanceOf(borrower);
        uint256 expectedCollateralValue = hmt.getUSDTForHMT(1000 * 1e18);
        uint256 expectedLoanAmt = (expectedCollateralValue * 50) / 100;

        mining.takeLoan(1000 * 1e18);
        
        uint256 usdtBalanceAfter = IERC20(BSC_USDT).balanceOf(borrower);
        assertEq(usdtBalanceAfter - usdtBalanceBefore, expectedLoanAmt, "Did not receive exactly 50% LTV in USDT");
        
        (uint256 colHMT, uint256 loanAmt, uint256 initVal, , bool isActive) = mining.userLoans(borrower);
        assertTrue(isActive, "Loan not marked active");
        assertEq(colHMT, 1000 * 1e18, "Collateral not tracked");
        assertEq(loanAmt, expectedLoanAmt, "Loan amount not tracked");
        assertEq(initVal, expectedCollateralValue, "Initial value not tracked");
        assertEq(mining.activeLoanUsers(0), borrower, "Not added to active loop array");
        vm.stopPrank();
    }

    function test_Loan_RevertIfTakingMultipleLoans() public {
        address borrower = address(dummyNonce + 101);
        hmt.transfer(borrower, 2000 * 1e18); 

        vm.startPrank(borrower);
        hmt.approve(address(mining), 2000 * 1e18);
        mining.takeLoan(1000 * 1e18); 

        vm.expectRevert(abi.encodeWithSignature("LoanActive()"));
        mining.takeLoan(1000 * 1e18); 
        vm.stopPrank();
    }

    function test_Loan_DebtAccumulatesCorrectlyOverTime() public {
        address borrower = address(dummyNonce + 102);
        hmt.transfer(borrower, 1000 * 1e18); 

        vm.startPrank(borrower);
        hmt.approve(address(mining), 1000 * 1e18);
        
        uint256 expectedCollateralValue = hmt.getUSDTForHMT(1000 * 1e18); // ~ $1000
        uint256 expectedLoanAmt = (expectedCollateralValue * 50) / 100;   // ~ $500

        mining.takeLoan(1000 * 1e18); 
        vm.stopPrank();

        (,,, uint256 actualStartTime, ) = mining.userLoans(borrower);
        
        // Day 0: 10% of INITIAL VALUE ($1000 * 10% = $100). Total Debt = $600.
        uint256 dayZeroDebt = mining.getLoanDebt(borrower);
        uint256 expectedDayZero = expectedLoanAmt + ((expectedCollateralValue * 10) / 100);
        assertEq(dayZeroDebt, expectedDayZero, "Upfront 10% interest on whole amount failed");
        
        // Cycle 1 (Day 28): Another 10% of INITIAL VALUE. Total Debt = $700.
        vm.warp(actualStartTime + 28 days);
        uint256 day28Debt = mining.getLoanDebt(borrower);
        uint256 expectedDay28 = expectedLoanAmt + ((expectedCollateralValue * 20) / 100);
        assertEq(day28Debt, expectedDay28, "Cycle 1 interest failed");

        // Cycle 2 (Day 56): Another 10% of INITIAL VALUE. Total Debt = $800.
        vm.warp(actualStartTime + 56 days);
        uint256 day56Debt = mining.getLoanDebt(borrower);
        uint256 expectedDay56 = expectedLoanAmt + ((expectedCollateralValue * 30) / 100);
        assertEq(day56Debt, expectedDay56, "Cycle 2 interest failed");
    }

    // 🟢 NEW: Hard Liquidation Test
    function test_Loan_HardLiquidationAfterThreeCycles() public {
        address borrower = address(dummyNonce + 999);
        hmt.transfer(borrower, 1000 * 1e18); 

        vm.startPrank(borrower);
        hmt.approve(address(mining), 1000 * 1e18);
        mining.takeLoan(1000 * 1e18); 
        vm.stopPrank();

        // Ensure price is completely healthy and borrower is safe on Day 1
        assertFalse(mining.isLiquidatable(borrower), "Should not be liquidatable yet");

        // Warp exactly 84 days (3 full cycles = enters 4th cycle)
        vm.warp(block.timestamp + 84 days);

        // Borrower is now instantly liquidatable due to time limit, even though price didn't drop!
        assertTrue(mining.isLiquidatable(borrower), "Time-based liquidation failed");

        // Liquidate
        mining.liquidateLoan(borrower);

        (uint256 colHMT,,,, bool isActive) = mining.userLoans(borrower);
        assertFalse(isActive, "Loan was not wiped out");
        assertEq(colHMT, 0, "Struct not deleted");
    }

    function test_Loan_RepayingLoanUnlocksCollateral() public {
        address borrower = address(dummyNonce + 103);
        hmt.transfer(borrower, 1000 * 1e18); 

        vm.startPrank(borrower);
        hmt.approve(address(mining), 1000 * 1e18);
        mining.takeLoan(1000 * 1e18);
        
        deal(BSC_USDT, borrower, 1000 * 1e18); // Give enough to cover the new higher interest
        IERC20(BSC_USDT).approve(address(mining), type(uint256).max);

        mining.repayLoan();
        vm.stopPrank();

        assertEq(hmt.balanceOf(borrower), 1000 * 1e18, "HMT Collateral not returned");

        (,,,, bool isActive) = mining.userLoans(borrower);
        assertFalse(isActive, "Loan still active");
        
        vm.expectRevert(); 
        mining.activeLoanUsers(0);
    }

    function test_Loan_ManualLiquidationOnPriceCrash() public {
        address borrower = address(dummyNonce + 104);
        hmt.transfer(borrower, 1000 * 1e18); 

        uint256 usdtBalanceBefore = IERC20(BSC_USDT).balanceOf(borrower);

        vm.startPrank(borrower);
        hmt.approve(address(mining), 1000 * 1e18);
        
        uint256 expectedCollateralValue = hmt.getUSDTForHMT(1000 * 1e18);
        uint256 expectedLoanAmt = (expectedCollateralValue * 50) / 100;

        mining.takeLoan(1000 * 1e18); 
        vm.stopPrank();

        assertFalse(mining.isLiquidatable(borrower), "Should not be liquidatable yet");
        
        vm.expectRevert(abi.encodeWithSignature("HealthyCollateral()"));
        mining.liquidateLoan(borrower);

        _crashHMTPrice();

        assertTrue(mining.isLiquidatable(borrower), "Oracle did not flag loan for liquidation");

        mining.liquidateLoan(borrower);
        
        (uint256 colHMT,,,, bool isActive) = mining.userLoans(borrower);
        assertFalse(isActive, "Loan was not wiped out");
        assertEq(colHMT, 0, "Struct not deleted");
        
        uint256 usdtBalanceAfter = IERC20(BSC_USDT).balanceOf(borrower);
        assertEq(usdtBalanceAfter - usdtBalanceBefore, expectedLoanAmt, "Borrower USDT was seized incorrectly");
    }

    function test_Loan_BatchAndAutoCranks() public {
        address[] memory borrowers = new address[](5);
        
        for(uint160 i = 0; i < 5; i++) {
            borrowers[i] = address(dummyNonce + 200 + i);
            hmt.transfer(borrowers[i], 1000 * 1e18); 
            
            vm.startPrank(borrowers[i]);
            hmt.approve(address(mining), 1000 * 1e18);
            mining.takeLoan(1000 * 1e18);
            vm.stopPrank();
        }

        _crashHMTPrice();
        mining.batchLiquidate(3);

        vm.expectRevert();
        mining.activeLoanUsers(4);

        address user6 = address(0x666);
        deal(BSC_USDT, user6, 2500 * 1e18);
        vm.startPrank(user6);
        IERC20(BSC_USDT).approve(address(mining), type(uint256).max);
        mining.invest(company, 100 * 1e18, false);
        vm.stopPrank();

        vm.expectRevert(); 
        mining.activeLoanUsers(0);
        
        (,,,, bool active) = mining.userLoans(borrowers[0]);
        assertFalse(active, "Auto-crank failed to liquidate remaining users");
    }
}