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

contract HMTMatrixMicroTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    MockNFT public nft;

    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public company = address(0x100);
    address public ownerWallet = address(0x200);

    // 🟢 Global Nonce to guarantee unique dummy addresses
    uint160 private dummyNonce = 1000000;

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

    // 🟢 Upgraded Smart Invest (V2 24-Hour Window Compatible)
    function _invest(address _user, address _sponsor, uint256 _totalAmount) internal {
        (uint256 windowStartTime, uint256 windowTotalInvested) = mining.userInvestmentWindows(_user);
        uint256 userInvestedToday = (block.timestamp >= windowStartTime + 24 hours) ? 0 : windowTotalInvested;
        uint256 userCanInvest = 2500 * 1e18 > userInvestedToday ? (2500 * 1e18) - userInvestedToday : 0;
        uint256 amountForUser = _totalAmount > userCanInvest ? userCanInvest : _totalAmount;

        if (amountForUser > 0) {
            deal(BSC_USDT, _user, amountForUser);
            vm.startPrank(_user);
            IERC20(BSC_USDT).approve(address(mining), amountForUser);
            mining.invest(_sponsor, amountForUser, false);
            vm.stopPrank();
        }

        uint256 amountLeft = _totalAmount - amountForUser;
        while(amountLeft > 0) {
            uint256 chunk = amountLeft > 2500 * 1e18 ? 2500 * 1e18 : amountLeft;
            address dummy = address(dummyNonce++);
            deal(BSC_USDT, dummy, chunk);
            vm.startPrank(dummy);
            IERC20(BSC_USDT).approve(address(mining), chunk);
            mining.invest(_user, chunk, false); 
            vm.stopPrank();
            amountLeft -= chunk;
        }
    }

    function _build3x3(address _leader, uint160 _seed) internal {
        for (uint i = 1; i <= 3; i++) {
            address l1 = address(uint160(_seed + i * 10000));
            _invest(l1, _leader, 100 * 1e18);
            for (uint j = 1; j <= 3; j++) {
                address l2 = address(uint160(uint160(l1) + j * 100));
                _invest(l2, l1, 100 * 1e18);
                for (uint k = 1; k <= 3; k++) {
                    address l3 = address(uint160(uint160(l2) + k));
                    _invest(l3, l2, 100 * 1e18);
                }
            }
        }
    }

    function test_Micro_Maintenance_SnapBack() public {
        address leader = address(0x777);
        _invest(leader, company, 500 * 1e18);
        _build3x3(leader, 0x3000);

        _invest(address(0x3001), leader, 35000 * 1e18); 
        _invest(address(0x3002), leader, 35000 * 1e18); 
        vm.prank(leader);
        mining.claimROI();

        // 🟢 CYCLE 1 (Days 28 - 55): Passes Maintenance every week.
        vm.warp(mining.launchTime() + 30 days); 
        _invest(address(0x3001), leader, 1000 * 1e18); 
        _invest(address(0x3002), leader, 1250 * 1e18); 
        vm.warp(mining.launchTime() + 37 days); 
        _invest(address(0x3001), leader, 1000 * 1e18); 
        _invest(address(0x3002), leader, 1250 * 1e18); 
        vm.warp(mining.launchTime() + 44 days); 
        _invest(address(0x3001), leader, 1000 * 1e18); 
        _invest(address(0x3002), leader, 1250 * 1e18); 
        vm.warp(mining.launchTime() + 51 days); 
        _invest(address(0x3001), leader, 1000 * 1e18); 
        _invest(address(0x3002), leader, 1250 * 1e18); 
        
        // 🛑 CYCLE 2 (Days 56 - 83): Fails Maintenance! (Only Weeks 8 is active, 9-11 are $0)
        vm.warp(mining.launchTime() + 58 days); 
        _invest(address(0x3001), leader, 1000 * 1e18); 
        _invest(address(0x3002), leader, 2000 * 1e18); 
        
        // 🟢 CYCLE 3 (Days 84 - 111): Passes Maintenance every week.
        vm.warp(mining.launchTime() + 86 days); 
        _invest(address(0x3001), leader, 1000 * 1e18);
        _invest(address(0x3002), leader, 2000 * 1e18); 
        vm.warp(mining.launchTime() + 93 days); 
        _invest(address(0x3001), leader, 1000 * 1e18);
        _invest(address(0x3002), leader, 2000 * 1e18); 
        vm.warp(mining.launchTime() + 100 days); 
        _invest(address(0x3001), leader, 1000 * 1e18);
        _invest(address(0x3002), leader, 2000 * 1e18); 
        vm.warp(mining.launchTime() + 107 days); 
        _invest(address(0x3001), leader, 1000 * 1e18);
        _invest(address(0x3002), leader, 2000 * 1e18); 

        vm.warp(mining.launchTime() + 115 days); 
        
        // 🟢 Expect Cycle 1: Passed (Tier 2 Payout)
        vm.expectEmit(true, false, false, true);
        emit HMTMining.MatrixRoyaltyClaimed(leader, 486 * 1e17, 1, true);
        
        // 🛑 Expect Cycle 2: FAILED (Tier 0 Payout)
        // 2% of 54000 total pool / 20 users = 54. 18% of 3000 volume = 540. 
        // Logic will emit the Tier 0 fallback amount.
        vm.expectEmit(true, false, false, true);
emit HMTMining.MatrixRoyaltyClaimed(leader, 54 * 1e17, 2, false);
        // 🟢 Expect Cycle 3: Passed (Tier 2 Payout)
        vm.expectEmit(true, false, false, true);
        emit HMTMining.MatrixRoyaltyClaimed(leader, 648 * 1e17, 3, true);

        vm.prank(leader);
        mining.claimROI();
    }

    function test_Micro_ExclusivePayouts() public {
        address leaderT2 = address(0x111);
        address leaderT1 = address(0x222);

        _invest(leaderT2, company, 500 * 1e18);
        _build3x3(leaderT2, 0x4000);
        _invest(address(0x4001), leaderT2, 35000 * 1e18); 
        _invest(address(0x4002), leaderT2, 35000 * 1e18); 
        vm.prank(leaderT2); mining.claimROI();

        _invest(leaderT1, company, 500 * 1e18);
        _build3x3(leaderT1, 0x5000);
        _invest(address(0x5001), leaderT1, 10000 * 1e18); 
        _invest(address(0x5002), leaderT1, 10000 * 1e18); 
        vm.prank(leaderT1); mining.claimROI();

        // 🟢 Spread the 28k Total Volume across all 4 weeks to pass maintenance
        vm.warp(mining.launchTime() + 30 days);
        _invest(address(0x9999), company, 10000 * 1e18); // Global Volume Chunk
        _invest(address(0x4001), leaderT2, 2000 * 1e18); // Weak leg = 1000
        _invest(address(0x4002), leaderT2, 1000 * 1e18);
        _invest(address(0x5001), leaderT1, 2000 * 1e18); // Weak leg = 1000
        _invest(address(0x5002), leaderT1, 1000 * 1e18);

        vm.warp(mining.launchTime() + 37 days);
        _invest(address(0x4001), leaderT2, 1000 * 1e18); // Weak leg = 1000
        _invest(address(0x4002), leaderT2, 1000 * 1e18);
        _invest(address(0x5001), leaderT1, 1000 * 1e18); // Weak leg = 1000
        _invest(address(0x5002), leaderT1, 1000 * 1e18);

        vm.warp(mining.launchTime() + 44 days);
        _invest(address(0x4001), leaderT2, 1000 * 1e18); // Weak leg = 1000
        _invest(address(0x4002), leaderT2, 1000 * 1e18);
        _invest(address(0x5001), leaderT1, 1000 * 1e18); // Weak leg = 1000
        _invest(address(0x5002), leaderT1, 1000 * 1e18);

        vm.warp(mining.launchTime() + 51 days);
        _invest(address(0x4001), leaderT2, 1000 * 1e18); // Weak leg = 1000
        _invest(address(0x4002), leaderT2, 1000 * 1e18);
        _invest(address(0x5001), leaderT1, 1000 * 1e18); // Weak leg = 1000
        _invest(address(0x5002), leaderT1, 1000 * 1e18);

        vm.warp(mining.launchTime() + 60 days);
        
        uint256 t1Pending = mining.getPendingMatrixRewards(leaderT1);
        uint256 t2Pending = mining.getPendingMatrixRewards(leaderT2);

        // Math: 28k * 18% = 5040 Global Pool. Tier 1 gets 2% = 100.8. Tier 2 gets 3% = 151.2
        assertEq(t1Pending, 1008 * 1e17, "Tier 1 Leader must strictly get the 2% bucket");
        assertEq(t2Pending, 1512 * 1e17, "Tier 2 Leader must strictly get the 3% bucket");
    }
}