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

        uint256 newPrice = hmt.getUSDTForHMT(1e18);
        console.log("CRASH: New HMT Price is: ", newPrice / 1e18, " USDT");
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

        vm.expectRevert("Must repay existing loan before taking another");
        mining.takeLoan(1000 * 1e18); 
        vm.stopPrank();
    }

    function test_Loan_DebtAccumulatesCorrectlyOverTime() public {
        address borrower = address(dummyNonce + 102);
        hmt.transfer(borrower, 1000 * 1e18); 

        vm.startPrank(borrower);
        hmt.approve(address(mining), 1000 * 1e18);
        
        uint256 expectedCollateralValue = hmt.getUSDTForHMT(1000 * 1e18);
        uint256 expectedLoanAmt = (expectedCollateralValue * 50) / 100;

        mining.takeLoan(1000 * 1e18); 
        vm.stopPrank();

        (,,, uint256 actualStartTime, ) = mining.userLoans(borrower);

        uint256 dayZeroDebt = mining.getLoanDebt(borrower);
        uint256 expectedDayZero = expectedLoanAmt + ((expectedLoanAmt * 10) / 100);
        assertEq(dayZeroDebt, expectedDayZero, "Upfront 10% interest failed");

        vm.warp(actualStartTime + 30 days);
        uint256 dayThirtyDebt = mining.getLoanDebt(borrower);
        uint256 expectedDayThirty = expectedLoanAmt + ((expectedLoanAmt * 20) / 100);
        assertEq(dayThirtyDebt, expectedDayThirty, "Month 1 interest failed");

        vm.warp(actualStartTime + 60 days);
        uint256 daySixtyDebt = mining.getLoanDebt(borrower);
        uint256 expectedDaySixty = expectedLoanAmt + ((expectedLoanAmt * 30) / 100);
        assertEq(daySixtyDebt, expectedDaySixty, "Month 2 interest failed");
    }

    function test_Loan_RepayingLoanUnlocksCollateral() public {
        address borrower = address(dummyNonce + 103);
        hmt.transfer(borrower, 1000 * 1e18); 

        vm.startPrank(borrower);
        hmt.approve(address(mining), 1000 * 1e18);
        mining.takeLoan(1000 * 1e18);
        
        deal(BSC_USDT, borrower, 600 * 1e18);
        IERC20(BSC_USDT).approve(address(mining), 600 * 1e18);

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

        vm.expectRevert("Collateral is healthy, cannot liquidate");
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

    function test_OTC_SwapHMTForUSDT() public {
        address swapper = address(dummyNonce + 300);
        uint256 hmtToSwap = 1000 * 1e18;
        hmt.transfer(swapper, hmtToSwap);

        uint256 expectedUSDTOut = hmt.getUSDTForHMT(hmtToSwap);

        deal(BSC_USDT, address(mining), 50_000 * 1e18);

        uint256 userUSDTBefore = IERC20(BSC_USDT).balanceOf(swapper);
        uint256 contractHMTBefore = hmt.balanceOf(address(mining));

        vm.startPrank(swapper);
        hmt.approve(address(mining), hmtToSwap);
        mining.swapHMTForUSDT(hmtToSwap);
        vm.stopPrank();

        uint256 userUSDTAfter = IERC20(BSC_USDT).balanceOf(swapper);
        uint256 contractHMTAfter = hmt.balanceOf(address(mining));

        assertEq(userUSDTAfter - userUSDTBefore, expectedUSDTOut, "User did not receive correct USDT payout");
        assertEq(contractHMTAfter - contractHMTBefore, hmtToSwap, "Contract did not receive the swapped HMT");
        assertEq(hmt.balanceOf(swapper), 0, "User's HMT was not fully deducted");
    }

    function test_OTC_SwapRevertsIfTreasuryEmpty() public {
        address swapper = address(dummyNonce + 301);
        uint256 hmtToSwap = 1000 * 1e18;
        hmt.transfer(swapper, hmtToSwap); 

        deal(BSC_USDT, address(mining), 0);

        vm.startPrank(swapper);
        hmt.approve(address(mining), hmtToSwap);
        
        vm.expectRevert("Insufficient USDT liquidity in protocol");
        mining.swapHMTForUSDT(hmtToSwap);
        vm.stopPrank();
    }
}