// SPDX-License-Identifier: MIT
pragma solidity ^0.8.31;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {HMTMining} from "../src/HMTMining.sol";
import {HMTToken} from "../src/HMTToken.sol"; 
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721.sol";

// ==========================================
// 🔌 INTERFACES REQUIRED FOR DEX TESTING
// ==========================================
interface IPancakeRouter02Test {
    function factory() external pure returns (address);
    function addLiquidity(address tokenA, address tokenB, uint amountADesired, uint amountBDesired, uint amountAMin, uint amountBMin, address to, uint deadline) external returns (uint amountA, uint amountB, uint liquidity);
}

interface IPancakeFactoryTest {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IPancakePairTest {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function balanceOf(address owner) external view returns (uint256);
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

contract HMTAutoBalanceTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    MockNFT public nft;

    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    
    address public company = address(0x100);
    address public ownerWallet = address(0x200);

    uint160 private dummyNonce = 8000000;
    address public liquidityPair;

    function setUp() public {
        hmt = new HMTToken(BSC_USDT, PANCAKESWAP_ROUTER);
        nft = new MockNFT();
        mining = new HMTMining(BSC_USDT, address(hmt), PANCAKESWAP_ROUTER, company, ownerWallet, address(nft));
        hmt.setMiningContract(address(mining));

        // 🟢 INITIAL LIQUIDITY: 1000 HMT and 5000 USDT (As requested)
        uint256 hmtLiquidity = 1000 * 1e18;  
        uint256 usdtLiquidity = 5000 * 1e18;

        deal(BSC_USDT, company, usdtLiquidity);
        hmt.transfer(company, hmtLiquidity); 

        vm.startPrank(company);
        IERC20(BSC_USDT).approve(PANCAKESWAP_ROUTER, usdtLiquidity);
        hmt.approve(PANCAKESWAP_ROUTER, hmtLiquidity);
        
        IPancakeRouter02Test(PANCAKESWAP_ROUTER).addLiquidity(
            address(hmt), BSC_USDT, hmtLiquidity, usdtLiquidity, 0, 0, company, block.timestamp + 1000 
        );
        vm.stopPrank();

        // Retrieve the pair address
        liquidityPair = IPancakeFactoryTest(IPancakeRouter02Test(PANCAKESWAP_ROUTER).factory()).getPair(address(hmt), BSC_USDT);

        // 🟢 FUND TREASURY: Give the Mining Contract funds to use for Auto-Balancing
        deal(BSC_USDT, address(mining), 50_000 * 1e18);
        hmt.transfer(address(mining), 100_000 * 1e18);
    }

    // Helper to view live pool reserves
    function _getHMTReserve() internal view returns (uint256) {
        address token0 = IPancakePairTest(liquidityPair).token0();
        (uint112 reserve0, uint112 reserve1, ) = IPancakePairTest(liquidityPair).getReserves();
        return token0 == address(hmt) ? uint256(reserve0) : uint256(reserve1);
    }

    // Helper to simulate users buying heavily (80% DEX strategy)
    function _simulateMarketBuying() internal {
        console.log("-----------------------------------------");
        console.log("[MARKET] Simulating 5 users investing $1,000 each (80% DEX Buy)...");
        
        // 5 staggered investments to avoid triggering the 25% slippage revert!
        for(uint i = 0; i < 5; i++) {
            address buyer = address(dummyNonce++);
            deal(BSC_USDT, buyer, 1000 * 1e18);
            
            vm.startPrank(buyer);
            IERC20(BSC_USDT).approve(address(mining), 1000 * 1e18);
            // 'false' triggers the 80% buy ratio, heavily draining HMT from the pool
            mining.invest(company, 1000 * 1e18, false);
            vm.stopPrank();
        }
        
        uint256 currentHMT = _getHMTReserve();
        console.log("[MARKET] Pool HMT Reserve drained to: ", currentHMT / 1e18);
        console.log("-----------------------------------------");
    }

    // ==========================================
    // 🧪 TEST 1: REVERT IF POOL IS HEALTHY
    // ==========================================
    function test_AutoBalance_RevertsIfAboveThreshold() public {
        uint256 currentHMT = _getHMTReserve();
        assertEq(currentHMT, 1000 * 1e18, "Initial setup failed");

        console.log("Attempting Auto-Balance while pool is healthy (1000 HMT)...");
        
       vm.expectRevert(abi.encodeWithSignature("HMTCapacityAboveLimit()"));
        mining.autoBalanceLiquidity();
        console.log("SUCCESS: Contract rejected the Auto-Balance!");
    }

    // ==========================================
    // 🧪 TEST 2: SUCCESSFUL AUTO-BALANCE & BURN
    // ==========================================
    function test_AutoBalance_SuccessAndPermanentLock() public {
        // 1. Drain the pool
        _simulateMarketBuying();
        
        uint256 preHMTReserve = _getHMTReserve();
        assertTrue(preHMTReserve < 600 * 1e18, "Pool did not drop below 600 threshold");

        // 2. Capture Treasury Balances & LP State
        uint256 treasuryHMTBefore = hmt.balanceOf(address(mining));
        uint256 treasuryUSDTBefore = IERC20(BSC_USDT).balanceOf(address(mining));
        uint256 deadAddressLPBefore = IPancakePairTest(liquidityPair).balanceOf(DEAD_ADDRESS);
        
        // 3. Any random user triggers the Auto-Balance
        address randomCaller = address(0x7777);
        vm.prank(randomCaller);
        mining.autoBalanceLiquidity();

        // 4. Verification
        uint256 treasuryHMTAfter = hmt.balanceOf(address(mining));
        uint256 treasuryUSDTAfter = IERC20(BSC_USDT).balanceOf(address(mining));
        uint256 deadAddressLPAfter = IPancakePairTest(liquidityPair).balanceOf(DEAD_ADDRESS);
        uint256 postHMTReserve = _getHMTReserve();

        console.log("-----------------------------------------");
        console.log("[RESULT] Auto-Balance Executed!");
        console.log("Treasury HMT Deducted:   ", (treasuryHMTBefore - treasuryHMTAfter) / 1e18);
        console.log("Treasury USDT Deducted:  ", (treasuryUSDTBefore - treasuryUSDTAfter) / 1e18);
        console.log("LP Tokens at Dead Address:", deadAddressLPAfter);
        console.log("New Pool HMT Reserve:    ", postHMTReserve / 1e18);
        console.log("-----------------------------------------");

        // Assertions
        assertEq(treasuryHMTBefore - treasuryHMTAfter, 1000 * 1e18, "Exactly 1000 HMT was not deducted");
        assertTrue(treasuryUSDTBefore > treasuryUSDTAfter, "USDT was not deducted");
        assertTrue(deadAddressLPAfter > deadAddressLPBefore, "LP tokens were not minted to the Dead Address");
        assertTrue(postHMTReserve > 1500 * 1e18, "Pool reserve was not restored");
    }

    // ==========================================
    // 🧪 TEST 3: REVERT IF TREASURY LACKS HMT
    // ==========================================
    function test_AutoBalance_RevertsIfTreasuryEmptyHMT() public {
        _simulateMarketBuying();
        
        // Empty out the Treasury's HMT (simulating a protocol that gave out too many rewards)
        uint256 balance = hmt.balanceOf(address(mining));
        vm.prank(address(mining));
        hmt.transfer(ownerWallet, balance); // Drain it
        
vm.expectRevert(abi.encodeWithSignature("InsufficientTreasuryHMT()"));
        mining.autoBalanceLiquidity();
    }

    // ==========================================
    // 🧪 TEST 4: REVERT IF TREASURY LACKS USDT
    // ==========================================
    function test_AutoBalance_RevertsIfTreasuryEmptyUSDT() public {
        _simulateMarketBuying();
        
        // Empty out the Treasury's USDT (simulating massive user withdrawals)
        uint256 balance = IERC20(BSC_USDT).balanceOf(address(mining));
        vm.prank(address(mining));
        IERC20(BSC_USDT).transfer(ownerWallet, balance); // Drain it
        
vm.expectRevert(abi.encodeWithSignature("InsufficientTreasuryUSDT()"));
        mining.autoBalanceLiquidity();
    }
}