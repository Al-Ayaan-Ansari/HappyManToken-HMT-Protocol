// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HMTMining} from "../src/HMTMining.sol";
import {HMTToken} from "../src/HMTToken.sol";
import {HMT_NFT} from "../src/HMTNFT.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol"; 

// A fake USDT to play with locally
contract MockUSDT is ERC20 {
    constructor() ERC20("Tether USD", "USDT") {
        // Mints 1 Million USDT to the deployer
        _mint(msg.sender, 1_000_000 * 10 ** decimals());
    }
}

// 🟢 NEW: Minimal Router Interface for Adding Liquidity
interface IRouter {
    function addLiquidity(
        address tokenA, address tokenB,
        uint amountADesired, uint amountBDesired,
        uint amountAMin, uint amountBMin,
        address to, uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
}

contract DeployLocal is Script {
    function run() external {
        // Use the first default Anvil private key
        uint256 deployerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        vm.startBroadcast(deployerPrivateKey);

        address deployer = vm.addr(deployerPrivateKey);
        address companyWallet = 0xcdA255C7a704281ac3F9F643f3B529C546a83fA9; 
        address ownerWallet = 0xcdA255C7a704281ac3F9F643f3B529C546a83fA9;

        // The real PancakeSwap V2 Router on BSC Mainnet (we forked this!)
        address pancakeRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

        // 1. Deploy Mock USDT
        MockUSDT usdt = new MockUSDT();

        // 2. Deploy HMT Token
        HMTToken hmt = new HMTToken(address(usdt), pancakeRouter);

        // 3. Deploy NFT Contract
        HMT_NFT nft = new HMT_NFT(address(usdt), ownerWallet);

        // 4. Deploy Mining Contract
        HMTMining mining = new HMTMining(
            address(usdt),
            address(hmt),
            pancakeRouter,
            companyWallet,
            ownerWallet,
            address(nft)
        );

        // 5. Connect the ecosystem together
        hmt.setMiningContract(address(mining));
        nft.setMiningContract(address(mining));

        // 6. Seed the Mining Contract with some USDT for Loan testing
        usdt.transfer(address(mining), 50_000 * 1e18);

        // ==========================================
        // 🟢 7. FUND THE PANCAKESWAP LIQUIDITY POOL
        // ==========================================
        uint256 hmtLiquidity = 14_700_000 * 1e18; // 70% of 21,000,000 Total Supply
        uint256 usdtLiquidity = 2500 * 1e18;      // 2,500 USDT

        // Approve the Router to spend the deployer's tokens
        usdt.approve(pancakeRouter, usdtLiquidity);
        hmt.approve(pancakeRouter, hmtLiquidity);

        // Add Liquidity to the DEX
        IRouter(pancakeRouter).addLiquidity(
            address(usdt),
            address(hmt),
            usdtLiquidity,
            hmtLiquidity,
            0, // Slippage min (Not needed for initial local deploy)
            0, // Slippage min
            deployer, // LP tokens go to the deployer
            block.timestamp + 300
        );

        vm.stopBroadcast();

        // Copy these to your index.html!
        console.log("--- CONTRACTS DEPLOYED & POOL FUNDED ---");
        console.log("USDT_ADDRESS: ", address(usdt));
        console.log("HMT_ADDRESS: ", address(hmt));
        console.log("NFT_ADDRESS: ", address(nft));
        console.log("MINING_ADDRESS:", address(mining));
        console.log("Initial LP Added: 14.7M HMT / 2,500 USDT");
    }
}