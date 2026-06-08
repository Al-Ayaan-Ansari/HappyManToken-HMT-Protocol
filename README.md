# 🚀 HappyManToken (HMT) Protocol - Complete Documentation Suite

**The Ultimate Multi-Yield DeFi Ecosystem.** HMT Protocol is an advanced, sustainable, and gamified decentralized finance platform built on the BNB Smart Chain. It seamlessly integrates algorithmic passive yield, dynamic matrix team building, over-collateralized lending, NFT utility, and a mathematically secure "no-loss" lottery into a single, bulletproof smart contract architecture.

---

## 📑 Table of Contents

1. [Ecosystem Guide & Mechanics (Plain English)](https://www.google.com/search?q=%231-ecosystem-guide--mechanics-plain-english)
2. [Master Technical Documentation & Smart Contract Architecture](https://www.google.com/search?q=%232-master-technical-documentation--smart-contract-architecture)
3. [Master Timing & Interval Architecture](https://www.google.com/search?q=%233-master-timing--interval-architecture)
4. [Deployment & Local Development Guide (Foundry)](https://www.google.com/search?q=%234-deployment--local-development-guide-foundry)

---

## 1. Ecosystem Guide & Mechanics (Plain English)

*This section explains every investment rule, earning mechanism, staking option, and security feature built into the platform for users and investors.*

### 🚀 The Core Investment System

The primary way to enter the HMT ecosystem is by inviting USDT. This initial deposit activates your account and begins generating yields.

* **Minimum Investment:** $2 USDT.
* **Maximum Daily Limit:** $2,500 USDT per rolling 24-hour window. This strict security feature prevents "whales" from dumping massive amounts of capital into the system at once.
* **Bot Protection:** Smart contracts and trading bots are permanently banned from investing or manipulating the system.
* **Capital Routing:**
* **Ecosystem Fee:** 10% is sent to the Trade Wallet to cover platform maintenance.
* **NFT Royalty Pool:** Exactly 18% is routed into a shared pool that pays out dividends to NFT holders.
* **Liquidity & Market Buying:** The rest is used to instantly buy HMT tokens from the open market. Users choose between a **Standard Strategy** (80% buys HMT / 20% stays in reserves) or a **Trade Engine Strategy** (20% buys HMT / 80% stays in reserves).



### 📈 Passive Income: The Dual Yield System

* **Yield 1: The Base ROI:** Earn a **0.6% daily** return on your total personal investment (compounding 0.2% every 8 hours) up to a hardcap of **200%**.
* **Yield 2: The Builder's Airdrop ROI:** Earn a **0.1% daily** linear stream up to **500%**. Unlocked for the *next* 28-day cycle only if you refer at least one direct user who invests $100 USDT or more in the current cycle.

### 🤝 Active Income: Level Rewards

Earn a percentage of the Base ROI your team *actually claims*. (Requires $100 USDT personal investment).

* **Level 1 (Direct Referrals):** 15% match (Requires 1 direct referral).
* **Level 2 (Their Referrals):** 10% match (Requires 2 direct referrals).
* **Level 3 (Third Generation):** 5% match (Requires 3 direct referrals).

### 🌐 Elite Income: Deep Matrix & Global Matching

* **The 50-Level Matrix:** Unlocked by building a 3x3x3 structure (39 total people). Pays a permanent 1% or 2% (if unlocked within 28 days) cut of your entire 50-level downline's ROI. Requires weaker teams to generate $1,000 USDT weekly.
* **The 7 Global Matching Pools:** 10% of global ROI is split into 7 exclusive pools based on balanced team volume (ranging from $10k to $16.6M). *Forfeiture Rule:* You must have a direct referral invest $100+ during a cycle to claim your share for that cycle.

### 🎨 The NFT Utility Ecosystem

7 Tiers of NFTs ($1,000 to $100,000).

* **Instant Sponsor Bonus:** 5% of the NFT purchase price is converted to HMT and sent directly to the sponsor.
* **"Greater Of" Yield:** Stakers earn the *higher* of two payouts every 28 days: A 1% guaranteed floor OR their slice of the 18% Global NFT Royalty Pool.
* **Sponsor Match:** Sponsors receive an automatic 15% matching bonus when downlines claim NFT yields.

### 🥩 Native HMT Token Staking

* **The Yield:** Staked HMT earns **0.6% daily**.
* **The Cap:** Max 50 stakes per wallet. Shuts down globally once 2.1M HMT is distributed.
* **Anti-Dump Penalty:** Early withdrawals (<6 months) burn principal. Month 1 = 20% Penalty, decreasing to 0% after 180 days.

### 🏦 Collateralized Cash Advances

Lock HMT as collateral and instantly receive **50% LTV in USDT**.

* **Repayment:** Principal + 10% upfront fee + 10% interest per 28-day cycle.
* **Liquidation Risk:** Automated liquidation if the HMT market value falls below 75% of its original value OR the loan is left open longer than 84 days.

### 🎲 Gamified Ecosystem Lottery

* **Entry:** 100 USDT. Max 100 participants per pool.
* **Maturity:** Resolves when 100 seats are filled AND 45 days have passed.
* **"No-Loss" Payout:** 100% of participants win HMT. Top 5 get 400x multipliers, while the bottom 50 get 100x (perfectly breaking even).

### 💸 Withdrawals & The Bank-Run Lock

* **The Daily Limit:** Max withdrawal of 10% of total investment (capped at $1,000) per 24 hours.
* **Network Fee:** Flat 5% deduction.
* **The $5.00 Latch:** Once HMT touches $5.00 on the live market, the protocol permanently matures and forces all global withdrawals to pay out in native HMT tokens instead of USDT.

---

## 2. Master Technical Documentation & Smart Contract Architecture

*This section maps the exact execution flows, state variable mutations, constraint checks, and mathematical algorithms embedded in `HMTMining.sol`.*

### 2.1 The Core Investment Engine (`invest`)

* **Constraint Validation:** Validates `2e18` minimum and `2500e18` rolling 24-hour maximum via `InvestmentWindow`. Calls `_runGlobalCheckpoints` to sweep pending yields before state mutation.
* **Eligibility Targeting:**
* Flags `matchingEligible[aSponsor][curCycle] = true` (Unlocks current cycle).
* Flags `airdropEligible[aSponsor][curCycle + 1] = true` (Unlocks next cycle).


* **39-Node Matrix Unlock:** Dynamically traces up to Great-Grand-Sponsor (`u2`). If `directsWith9Count == 3`, flips `isMatrixUnlocked = true`.
* **Capital Routing:** Routes 10% fee to `tradeWallet`. Distributes 18% to `cumulativeNFTRPS`. Swaps remainder to HMT via PancakeSwap AMM depending on `_isTE` toggle.

### 2.2 Passive Income: The Dual ROI System

* **Base ROI:** Uses `_calculateCompound` with base multiplier `1002 * 1e15` (0.2% per 8 hours). Truncates exactly at `maxBase = u.totalInvestment * 2`.
* **Airdrop ROI:** Linear calculation `(inv * (tE - tS)) / 86400000`. Yield is only credited if `airdropEligible[_user][c]` is true. Capped at 500%.

### 2.3 Elite Income: Matrix & Global Matching Pools

* **Volume Tracking (`_updateUplineVolume`):** Climbs 50 steps mapping `legVolume` and `strongestLegVolume`. Pre-calculates remaining cycle ROI and adds to `cycleFamilyROI`.
* **Matching Pools (`_distributeMatchingIncome`):** Divides 10% of global ROI into 7 pools using `matchingSharesPerTier`. Evaluates `matchingEligible` to strictly enforce cycle-specific payout forfeiture.

### 2.4 Vault Splitting & Withdrawal Cascading (`withdraw`)

* **Vault Logic:** Protocol utilizes four independent user vaults: `levelIncomeVault`, `matrixVault`, `matchingVault`, and `airdropVault`.
* **Cascading Engine:** Requests are deducted sequentially down the array while enforcing the 10% / 1,000 USDT daily cap limit.

### 2.5 Security Modifiers & First ID Architecture

* **Anti-Bot:** Uses `onlyHuman` (where `msg.sender == tx.origin`) to block flash loans on AMM-dependent functions (`takeLoan`, `swapHMTForUSDT`).
* **First ID Shift:** The `liquidtymentainer` wallet serves as the root matrix node, allowing the `tradeWallet` to act strictly as an isolated, restricted treasury collection sink.

---

## 3. Master Timing & Interval Architecture

*A mapping of every hardcoded timestamp, interval, and time-lock.*

### 3.1 Global Timelines (Tied to Contract Deployment)

* **The Global Genesis (`launchTime`):** Absolute zero point for the protocol's timeline.
* **The 28-Day Cycle (`CYCLE_DURATION`):** Calculates Airdrop maturity, Matrix pool groupings, and NFT Staking floors.
* **The 7-Day Weekly Maintenance:** Tracks matrix team volume in absolute rolling 7-day increments.

### 3.2 Rolling 24-Hour Windows (User Interaction Timers)

* **Deposit Cap Window:** Starts on the user's first investment. Caps wallet at 2,500 USDT until 24 hours expire.
* **Withdrawal Cap Window:** Starts on withdrawal request. Caps at 10% / 1,000 USDT.

### 3.3 Yield & Epoch Timers

* **The 8-Hour Compounding Epoch:** Evaluates `(block.timestamp - u.lastBaseClaimTime) / 8 hours`.
* **The Second-by-Second Airdrop Epoch:** Evaluates `(tE - tS) / 86400000`.
* **30-Day Deflationary Months (HMT Staking):** Slashes early unstakes based on 30-day boundaries (`monthsPassed = elapsed / 30 days`).

### 3.4 DeFi Utility Time-Locks

* **45-Day Lottery Lock:** Starts when the first participant enters an empty pool. Resolves strictly after 45 days.
* **84-Day Loan Default:** An HMT-backed loan is liquidatable if left open for `3 * CYCLE_DURATION` (84 days).

---
## 4. Deployed contract addresses
The protocol is live and verified on the BNB Smart Chain Mainnet.

| Contract | Mainnet Address (BSC) |
| :--- | :--- |
| **USDT (BEP-20)** | `0x55d398326f99059fF775485246999027B3197955` |
| **HMT Token** | `0x6b7534cC8A14BD33a6e65c1e3A32e2039E9f2584`(https://bscscan.com/address/0x6b7534cC8A14BD33a6e65c1e3A32e2039E9f2584) |
| **HMT NFT Contract** | `0x474ad202A7a03db9f1d57f9b36804A5879F34356`(https://bscscan.com/address/0x474ad202A7a03db9f1d57f9b36804A5879F34356) |
| **HMT Mining (Core)** | `0x7BA85041ed9F325C0CF1838B40BE9369A57F7A60`(https://bscscan.com/address/0x7BA85041ed9F325C0CF1838B40BE9369A57F7A60) |


## 4. Deployment & Local Development Guide (Foundry)

### ⛓️ BNB Smart Chain (Mainnet) Configuration

```json
{
  "chainId": "0x38",
  "chainName": "BNB Smart Chain",
  "nativeCurrency": { "name": "BNB", "symbol": "BNB", "decimals": 18 },
  "rpcUrls": ["https://bsc-dataseed.binance.org/"],
  "blockExplorerUrls": ["https://bscscan.com"]
}

```

### 💻 Local Testing & Setup

This project is built and optimized entirely using the **Foundry** development framework. Mainnet fork testing is required to properly simulate the PancakeSwap router connections, live reserves, and liquidity behaviors.

**1. Clone the Repository**

```bash
git clone https://github.com/Al-Ayaan-Ansari/HappyManToken-HMT-Protocol.git
cd HappyManToken-HMT-Protocol

```

**2. Install Foundry Dependencies**

```bash
forge install

```

**3. Build and Compile Contracts**

```bash
forge build

```

**4. Run the Test Suite (With Mainnet Forking)**
Ensure your environment variables or terminal includes a valid BSC RPC URL to accurately evaluate external oracle queries (`getHMTForUSDT`, `getUSDTForHMT`).

```bash
# Run regular test execution
forge test --fork-url https://bsc-dataseed.binance.org/ -vv

# Run tests with precise gas logging reports
forge test --fork-url https://bsc-dataseed.binance.org/ --gas-report

```

### 🔐 Security & Auditing Standards

* **Reentrancy Guards:** Applied strictly across all external, state-altering methods.
* **Flash Loan Shields:** Built into liquidity gateways using origin-matching constraints.
* **Gas-Limit Protections:** Hardcoded array parameters (max 50 open stakes/staked assets) protect calculations from failing via standard EVM block boundaries.

---

*Disclaimer: This protocol handles complex economic variables. Users should review the smart contracts independently before interacting.*
