// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

// --- DEX Interfaces ---
interface IPancakeFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IPancakeRouter02 {
    function factory() external pure returns (address);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

interface IPancakePair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    
}

contract HMTToken is ERC20, Ownable {
    // --- Core DEX Variables ---
    IPancakeRouter02 public pancakeRouter;
    address public pancakePair;
    address public USDT;
    
    // The "Buy Granted" address (This will be your Mining Contract)
    address public miningContract;

    // --- Dump-Proof Tax Parameters (bps = basis points. 10000 = 100%) ---
    uint256 public defaultSellTaxBps = 0;      // Starts at 0%
    uint256 public stepBps = 50;               // 0.5% price drop step
    uint256 public stepTaxIncrease = 100;      // +1% tax increase per step
    uint256 public maxSellTaxBps = 5000;       // Hard cap at 50%

    // --- Price & Tax Tracking ---
    uint256 public ATHPrice;                   // All-Time High price (scaled 1e18)
    uint256 public currentSellTaxBps;          // Current active sell tax

    // --- Events ---
    event TaxRecalculated(uint256 newTaxBps, uint256 currentPrice, uint256 athPrice);
    event MiningContractUpdated(address newMiningContract);

    error TransferNotAllowed(address to);

    constructor(address _usdt, address _router) 
        ERC20("HMT Token", "HMT") 
        Ownable(msg.sender) 
    {
        require(_usdt != address(0) && _router != address(0), "Zero address provided");
        USDT = _usdt;
        pancakeRouter = IPancakeRouter02(_router);
        
        // Automatically create the PancakeSwap Pair for HMT/USDT
        pancakePair = IPancakeFactory(pancakeRouter.factory()).createPair(address(this), _usdt);

        // Initialize Sell Tax
        currentSellTaxBps = defaultSellTaxBps;

        // Mint initial supply to the deployer (Adjust 21,000,000 to your desired supply)
        _mint(msg.sender, 21_000_000 * 10 ** decimals());
    }

    // --- Setup Functions ---

    // Set the Mining Contract (The only address allowed to buy from PancakeSwap)
    function setMiningContract(address _miningContract) external onlyOwner {
        require(_miningContract != address(0), "Zero address");
        miningContract = _miningContract;
        emit MiningContractUpdated(_miningContract);
    }

    // --- Core Transfer Logic (Overriding OpenZeppelin v5) ---

    function _update(address from, address to, uint256 value) internal override {
        // Skip tax and logic for minting or burning
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        // 1. BUY RESTRICTION: If buying from PancakeSwap, ONLY the Mining Contract can receive it
        if (from == pancakePair) {
            if (miningContract == address(0) || to != miningContract) {
                revert TransferNotAllowed(to);
            }
        }

        // 2. RECALCULATE FEE: Check price against ATH before processing transfer
        _recalculateFee();

        uint256 taxAmount = 0;

        // 3. SELL TAX LOGIC: If selling to PancakeSwap (and not the Mining Contract itself selling)
        if (to == pancakePair && from != miningContract) {
            uint256 calculatedTax = (value * currentSellTaxBps) / 10000;
            uint256 capTax = (value * maxSellTaxBps) / 10000;
            
            // Enforce the 50% hard cap
            taxAmount = calculatedTax > capTax ? capTax : calculatedTax;
        }

        // 4. EXECUTE TRANSFER
        if (taxAmount > 0) {
            require(miningContract != address(0), "Mining contract not set for taxes");
            
            // Send Tax to Mining Contract
            super._update(from, miningContract, taxAmount);
            
            // Send remaining to the PancakeSwap Pair (Seller)
            super._update(from, to, value - taxAmount);
        } else {
            // Standard transfer with 0 tax
            super._update(from, to, value);
        }
    }

    // --- Dump-Proof Price & Fee Calculation ---

    function _recalculateFee() internal {
        uint256 currentPrice = _fetchPrice1e18();
        if (currentPrice == 0) return; // Pair not funded yet

        // If price breaks ATH: Reset tax to 0% and set new ATH
        if (ATHPrice == 0 || currentPrice > ATHPrice) {
            ATHPrice = currentPrice;
            if (currentSellTaxBps != defaultSellTaxBps) {
                currentSellTaxBps = defaultSellTaxBps;
                emit TaxRecalculated(currentSellTaxBps, currentPrice, ATHPrice);
            }
            return;
        }

        // If price drops below ATH: Calculate the drawdown percentage
        uint256 drawdownBps = ((ATHPrice - currentPrice) * 10000) / ATHPrice;
        
        // Calculate how many 0.5% (50 bps) steps it dropped
        uint256 steps = drawdownBps / stepBps; 
        
        // Add 1% (100 bps) tax for every step dropped
        uint256 newFee = defaultSellTaxBps + (steps * stepTaxIncrease);
        if (newFee > maxSellTaxBps) newFee = maxSellTaxBps;

        // The "Ratchet" mechanic: The fee only goes UP, never down (until ATH is broken)
        if (newFee > currentSellTaxBps) {
            currentSellTaxBps = newFee;
            emit TaxRecalculated(newFee, currentPrice, ATHPrice);
        }
    }

    // --- Oracle: Fetch Price from PancakeSwap Reserves ---

    function _fetchPrice1e18() internal view returns (uint256 price) {
        if (pancakePair == address(0)) return 0;
        
        (uint112 reserve0, uint112 reserve1,) = IPancakePair(pancakePair).getReserves();
        address token0 = IPancakePair(pancakePair).token0();
        address token1 = IPancakePair(pancakePair).token1();
        
        if (token0 == address(0) || token1 == address(0)) return 0;

        // Calculate price based on token sorting (USDT per HMT, scaled by 1e18)
        if (token0 == address(this) && token1 == USDT) {
            if (reserve0 == 0) return 0;
            price = (uint256(reserve1) * 1e18) / uint256(reserve0);
        } else if (token0 == USDT && token1 == address(this)) {
            if (reserve1 == 0) return 0;
            price = (uint256(reserve0) * 1e18) / uint256(reserve1);
        } else {
            return 0;
        }
    }
    // --- Dedicated Price Helpers ---

    /**
     * @dev Calculates how much USDT you get for a specific amount of HMT
     * Useful for the Staking/Loan contract to calculate liquidation thresholds
     */
    function getUSDTForHMT(uint256 hmtAmount) external view returns (uint256) {
        address[] memory paths = new address[](2);
        paths[0] = address(this); // Token In: HMT
        paths[1] = USDT;          // Token Out: USDT
        
        uint256[] memory amounts = pancakeRouter.getAmountsOut(hmtAmount, paths);
        return amounts[1];
    }

    /**
     * @dev Calculates how much HMT you get for a specific amount of USDT
     * Useful for the Mining contract to calculate how much HMT to give for a USDT reward
     */
    function getHMTForUSDT(uint256 usdtAmount) external view returns (uint256) {
        address[] memory paths = new address[](2);
        paths[0] = USDT;          // Token In: USDT
        paths[1] = address(this); // Token Out: HMT
        
        uint256[] memory amounts = pancakeRouter.getAmountsOut(usdtAmount, paths);
        return amounts[1];
    }
}