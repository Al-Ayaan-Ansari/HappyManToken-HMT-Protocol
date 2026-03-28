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

contract HMTMatrixTest is Test {
    HMTMining public mining;
    HMTToken public hmt;
    MockNFT public nft;

    address constant PANCAKESWAP_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant BSC_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public company = address(0x100);
    address public ownerWallet = address(0x200);
    uint160 private dummyNonce = 2000000;

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

    function test_MatchingVolume_And_ShareMigration() public {
        address leader = address(0x888);
        _invest(leader, company, 1000 * 1e18); 
        _build3x3(leader, 0x2000); 

        _invest(address(0x2001), leader, 50000 * 1e18); 
        _invest(address(0x2002), leader, 5000 * 1e18);  
        _invest(address(0x2003), leader, 5000 * 1e18);  

        vm.prank(leader);
        mining.claimROI(); 

        uint8 currentTier = mining.userMatrixData(leader);
        assertEq(currentTier, 1, "Matching volume is 10k. Leader should be Tier 1.");
        assertEq(mining.totalSharesPerTier(1), 1, "Tier 1 pool should have 1 share.");
        
        _invest(address(0x2002), leader, 25000 * 1e18); 

        vm.prank(leader);
        mining.claimROI(); 

        currentTier = mining.userMatrixData(leader);
        assertEq(currentTier, 2, "Matching volume is 35k. Leader upgraded to Tier 2.");
        assertEq(mining.totalSharesPerTier(1), 0, "Share must be deleted from Tier 1.");
        assertEq(mining.totalSharesPerTier(2), 1, "Share must migrate to Tier 2.");
    }
}