// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 { function transfer(address,uint256) external returns(bool); function transferFrom(address,address,uint256) external returns(bool); function balanceOf(address) external view returns(uint256); function approve(address,uint256) external returns(bool); }
interface IERC721 { function ownerOf(uint256) external view returns(address); function transferFrom(address,address,uint256) external; }
interface IHMTToken is IERC20 { function getHMTForUSDT(uint256) external view returns(uint256); function getUSDTForHMT(uint256) external view returns(uint256); }
interface IPancakeFactory { function getPair(address,address) external view returns(address); }
interface IPancakePair { function token0() external view returns(address); function getReserves() external view returns(uint112,uint112,uint32); }
interface IPancakeRouter02 { function factory() external pure returns(address); function swapExactTokensForTokens(uint256,uint256,address[] calldata,address,uint256) external returns(uint256[] memory); function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) external returns(uint256,uint256,uint256); }
interface INFTContract { function mintRewardNFT(address,uint8) external; function buyNFT(address,uint8) external; function getNFTTier(uint256) external view returns(uint8); function getTierPrice(uint8) external view returns(uint256); function ownerWallet() external view returns(address); function ownerOf(uint256) external view returns(address); function transferFrom(address,address,uint256) external; }

error E();

contract HMTMining {
    IERC20           public USDT;
    IHMTToken        public HMT;
    IPancakeRouter02 public pancakeRouter;
    INFTContract     public NFT;
    
    address public insuranceWallet;
    address public liquiditymentainerWallet;
    address public owner;
    
    uint256 private lastDailyRewardClaimTime;
    uint256 private lastHmtReserve;
    uint256 public launchTime;

    uint256 public constant MIN_INVESTMENT           = 2e18;
    uint256 public constant MAX_INVESTMENT           = 2500e18;
    uint256 public constant MAX_CLAIM_CYCLES         = 24;
    uint256 public constant CYCLE_DURATION           = 28 days;
    uint256 public constant WEEKLY_MAINTENANCE       = 1000e18;
    uint256 public constant LOTTERY_ENTRY_FEE        = 100e18;
    uint256 public constant LOTTERY_MAX_PARTICIPANTS = 100;
    uint256 public constant LOTTERY_MATURITY_TIME    = 45 days;
    uint256 public constant AUTO_BATCH_SIZE          = 5;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // 🟢 2.1M HMT NFT Staking Reserve & Killswitch
    uint256 public constant MAX_NFT_STAKING_REWARDS  = 2_100_000 * 1e18;
    uint256 public totalNFTRewardsDistributed;
    bool    public isNFTStakingDisabled;

    bool public isPayoutLockedToHMT;
    uint256 private _status = 1;
    modifier nonReentrant() { if (_status == 2) revert E(); _status = 2; _; _status = 1; }
    modifier onlyOwner()    { if (msg.sender != owner) revert E(); _; }

    struct User {
        address sponsor;
        bool    isMatrixUnlocked;
        uint256 matrixUnlockTime;
        uint96  directReferralsCount;
        uint256 registrationTime;
        uint256 totalInvestment;
        uint256 directsWith3Count;
        uint256 directsWith9Count;
        uint256 totalTeamVolume;
        uint256 strongestLegVolume;
        address strongestLegUser;
        uint256 lastBaseClaimTime;
        uint256 baseClaimed;
        uint256 lastAirdropCycle;
        uint256 airdropClaimed;
        uint256 lastClaimedCycle;
        uint256 levelIncomeVault;
        uint256 matrixRoyaltyVault;
        uint256 airdropVault;
    }

    struct UserMatrix { uint8 currentMatrixTier; mapping(uint8 => uint256) upgradeCycle; }
    struct WithdrawWindow { uint256 windowStartTime; uint256 withdrawnAmount; }
    struct InvestmentWindow{ uint256 windowStartTime; uint256 totalInvested; }

    mapping(address => User) public users;
    mapping(address => UserMatrix) public userMatrixData;
    mapping(address => mapping(uint256 => bool)) public cycleEligible; // Used for Airdrop & Matching Income
    mapping(address => uint256[]) public userStakedTokenIds;
    mapping(uint256 => mapping(address => bool)) public poolHasEntered;
    
    mapping(address => mapping(address => uint256)) private legVolume;
    mapping(address => InvestmentWindow) private userInvestmentWindows;
    mapping(address => WithdrawWindow) private userWithdrawWindows;
    
    mapping(address => mapping(uint256 => uint256)) private weeklyTotalVolume;
    mapping(address => mapping(uint256 => uint256)) private weeklyStrongestLegVolume;
    mapping(address => mapping(address => mapping(uint256 => uint256))) private weeklyLegVolume;
    
    // 🟢 3x3 Family ROI Tracker
    mapping(address => mapping(uint256 => uint256)) public cycleFamilyROI;
    
    // 🟢 7-Tier Matching Income Trackers
    uint256[8] public matchingSharesPerTier;
    mapping(uint256 => mapping(uint8 => uint256)) public cycleMatchingRPS;
    
    mapping(address => uint256) private lastAirdropUpdate;
    mapping(address => mapping(uint256 => uint256)) private cycleAirdropEarned;
    
    struct StakedNFT  { uint8 tier; uint256 startCycle; }
    mapping(uint256 => StakedNFT) private tokenStakingData;

    struct LotteryPool { uint256 startTime; address[] participants; bool isResolved; }
    uint256 public currentLotteryId = 1;
    uint256 private lastResolvedLotteryId = 1;
    mapping(uint256 => LotteryPool) private lotteryPools;

    struct Loan { uint256 collateralHMT; uint256 loanAmountUSDT; uint256 initialCollateralValueUSDT; uint256 loanStartTime; bool isActive; }
    mapping(address => Loan) public userLoans;
    address[] private activeLoanUsers;
    mapping(address => uint256) private activeLoanIndex;
    uint256 private currentLiquidationIndex;
    
    struct TokenStake { uint256 amount; uint256 startTime; }
    mapping(address => TokenStake[]) private userTokenStakes;

    constructor(address _usdt, address _hmt, address _router, address _insuranceWallet, address _liquiditymentainerWallet, address _nftContract) {
        USDT = IERC20(_usdt); HMT = IHMTToken(_hmt); pancakeRouter = IPancakeRouter02(_router);
        insuranceWallet = _insuranceWallet; liquiditymentainerWallet = _liquiditymentainerWallet; NFT = INFTContract(_nftContract); owner = msg.sender;
        launchTime = block.timestamp; lastDailyRewardClaimTime = block.timestamp; lastHmtReserve = 1000e18;
        User storage cw = users[insuranceWallet]; cw.totalInvestment = 10000e18; cw.registrationTime = block.timestamp; cw.isMatrixUnlocked = true;
    }

    function _runGlobalCheckpoints(address _user) internal {
        _autoLiquidateChunk();
        if (users[_user].totalInvestment > 0) {
            _internalClaimROI(_user);
            _internalClaimCycleRewards(_user);
            _internalClaimNFTRewards(_user);
        }
    }

    // =====================================
    // 🟢 COMPOUNDING MATH CORE
    // =====================================
    function _calculateCompound(uint256 principal, uint256 periods) internal pure returns (uint256) {
        uint256 ratio = 1e18;
        uint256 base = 1002 * 1e15; // 0.2% every 8 hours = 0.6% daily
        while (periods > 0) {
            if (periods % 2 == 1) ratio = (ratio * base) / 1e18;
            base = (base * base) / 1e18;
            periods /= 2;
        }
        return (principal * ratio) / 1e18;
    }

    // =====================================
    // 🟢 NFT BUYING & STAKING REWARDS
    // =====================================
    
    function buyNFT(uint8 _tier) external nonReentrant {
        address sponsor = users[msg.sender].sponsor;
        require(sponsor != address(0), "Register first by investing");
        
        uint256 price = NFT.getTierPrice(_tier);
        USDT.transferFrom(msg.sender, address(this), price);
        
        uint256 sponsorBonus = (price * 5) / 100;
        
        // 5% directly to sponsor wallet
        USDT.transfer(sponsor, sponsorBonus);
        // 95% to NFT Owner Wallet
        USDT.transfer(NFT.ownerWallet(), price - sponsorBonus);
        
        NFT.buyNFT(msg.sender, _tier);
    }

    function stakeNFT(uint256 _tId) external nonReentrant {
        require(!isNFTStakingDisabled, "NFT Staking limit reached (2.1M HMT)");
        if (NFT.ownerOf(_tId) != msg.sender) revert E();
        uint8 t = NFT.getNFTTier(_tId);
        if (t < 1 || t > 7) revert E();
        _internalClaimNFTRewards(msg.sender);
        
        NFT.transferFrom(msg.sender, address(this), _tId);
        uint256 ac = (block.timestamp - launchTime) / CYCLE_DURATION;
        tokenStakingData[_tId] = StakedNFT(t, ac + 1);
        userStakedTokenIds[msg.sender].push(_tId);
    }

    function unstakeNFT(uint256 _tId) external nonReentrant {
        uint256[] storage ids = userStakedTokenIds[msg.sender];
        uint256 len  = ids.length;
        uint256 tIdx = type(uint256).max;
        for (uint256 i; i < len; i++) { if (ids[i] == _tId) { tIdx = i; break; } }
        if (tIdx == type(uint256).max) revert E();
        
        _internalClaimNFTRewards(msg.sender);
        
        ids[tIdx] = ids[len - 1];
        ids.pop();
        delete tokenStakingData[_tId];
        NFT.transferFrom(address(this), msg.sender, _tId);
    }

    function getPendingNFTRewards(address _user) public view returns (uint256 pendUsdt, uint256 pendHmt) {
        if (isNFTStakingDisabled) return (0, 0);
        uint256 ac = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256[] memory ids = userStakedTokenIds[_user];
        
        for (uint256 i; i < ids.length; i++) {
            StakedNFT memory s = tokenStakingData[ids[i]];
            if (ac > s.startCycle) {
                uint8 tier = s.tier;
                uint256 tp = NFT.getTierPrice(tier);
                uint256 cyclesPassed = ac - s.startCycle;
                
                // Pure 1% Reward per cycle
                pendUsdt += (tp * cyclesPassed) / 100;
            }
        }
        if (pendUsdt > 0) {
            pendHmt = HMT.getHMTForUSDT(pendUsdt);
        }
    }

    function _internalClaimNFTRewards(address _user) internal {
        if (isNFTStakingDisabled) return;
        
        uint256 ac = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256 payUsdt;
        uint256[] storage ids = userStakedTokenIds[_user];
        
        for (uint256 i; i < ids.length; i++) {
            StakedNFT storage s = tokenStakingData[ids[i]];
            if (ac > s.startCycle) {
                uint8 tier = s.tier;
                uint256 tp = NFT.getTierPrice(tier);
                uint256 cyclesPassed = ac - s.startCycle;
                
                payUsdt += (tp * cyclesPassed) / 100;
                s.startCycle = ac;
            }
        }
        
        if (payUsdt > 0) { 
            uint256 hmtReward = HMT.getHMTForUSDT(payUsdt);
            uint256 sponsorBonus = (hmtReward * 15) / 100;
            uint256 totalNeeded = hmtReward + sponsorBonus;
            
            if (totalNFTRewardsDistributed + totalNeeded >= MAX_NFT_STAKING_REWARDS) {
                uint256 remaining = MAX_NFT_STAKING_REWARDS - totalNFTRewardsDistributed;
                hmtReward = (remaining * 100) / 115;
                sponsorBonus = remaining - hmtReward;
                isNFTStakingDisabled = true; 
            }
            
            totalNFTRewardsDistributed += (hmtReward + sponsorBonus);
            
            if (HMT.balanceOf(address(this)) >= hmtReward) {
                HMT.transfer(_user, hmtReward);
            }
            
            address sponsor = users[_user].sponsor;
            if (sponsor != address(0) && sponsorBonus > 0 && HMT.balanceOf(address(this)) >= sponsorBonus) {
                HMT.transfer(sponsor, sponsorBonus);
            }
        }
    }

    // =====================================
    // 🟢 BASE & AIRDROP ROI (COMPOUNDING)
    // =====================================
    
    function getPendingROI(address _user) public view returns (uint256 bPend, uint256 aPend) {
        if (_user == insuranceWallet || users[_user].totalInvestment == 0) return (0, 0);
        User memory u = users[_user];
        
        uint256 bC = (block.timestamp - u.lastBaseClaimTime) / 8 hours;
        if (bC > 0) {
            uint256 compounded = _calculateCompound(u.totalInvestment, bC);
            uint256 cB = compounded - u.totalInvestment; 
            bPend = (u.baseClaimed + cB > u.totalInvestment) ? (u.totalInvestment > u.baseClaimed ? u.totalInvestment - u.baseClaimed : 0) : cB;
        }
        
        if (u.totalInvestment >= 100e18) {
            uint256 cC  = (block.timestamp - launchTime) / CYCLE_DURATION;
            uint256 lT  = lastAirdropUpdate[_user] == 0 ? u.registrationTime : lastAirdropUpdate[_user];
            uint256 sC  = (lT - launchTime) / CYCLE_DURATION;
            for (uint256 c = u.lastAirdropCycle; c < cC; c++) {
                uint256 cE = cycleAirdropEarned[_user][c];
                if (c >= sC && lT < launchTime + (c + 1) * CYCLE_DURATION) {
                    uint256 cST = launchTime + c * CYCLE_DURATION;
                    uint256 tS  = lT > cST ? lT : cST;
                    uint256 tE  = block.timestamp < cST + CYCLE_DURATION ? block.timestamp : cST + CYCLE_DURATION;
                    if (tE > tS) cE += (u.totalInvestment * (tE - tS)) / 86400000;
                }
                if (cycleEligible[_user][c]) aPend += cE;
            }
            uint256 aCap = u.totalInvestment * 5;
            if (u.airdropClaimed + aPend > aCap) aPend = aCap > u.airdropClaimed ? aCap - u.airdropClaimed : 0;
        }
    }

    function _internalClaimROI(address _user) internal {
        _checkpointAirdrop(_user);
        User storage u = users[_user];
        uint256 aC = (block.timestamp - launchTime) / CYCLE_DURATION;
        
        uint256 bC = (block.timestamp - u.lastBaseClaimTime) / 8 hours;
        if (bC > 0) {
            uint256 compounded = _calculateCompound(u.totalInvestment, bC);
            uint256 cB = compounded - u.totalInvestment;
            uint256 bP = (u.baseClaimed + cB > u.totalInvestment) ? (u.totalInvestment > u.baseClaimed ? u.totalInvestment - u.baseClaimed : 0) : cB;
            
            if (bP > 0) {
                u.lastBaseClaimTime += bC * 8 hours;
                u.baseClaimed       += bP;
                u.levelIncomeVault  += bP;
                address cS = u.sponsor;
                if (cS != address(0)) {
                    if (users[cS].directReferralsCount >= 1 && users[cS].totalInvestment >= 100e18) {
                        users[cS].levelIncomeVault += (bP * 15) / 100;
                    }
                    address cS2 = users[cS].sponsor;
                    if (cS2 != address(0)) {
                        if (users[cS2].directReferralsCount >= 2 && users[cS2].totalInvestment >= 100e18) {
                            users[cS2].levelIncomeVault += (bP * 10) / 100;
                        }
                        address cS3 = users[cS2].sponsor;
                        if (cS3 != address(0) && users[cS3].directReferralsCount >= 3 && users[cS3].totalInvestment >= 100e18) {
                            users[cS3].levelIncomeVault += (bP * 5) / 100;
                        }
                    }
                }
            } else if (u.baseClaimed >= u.totalInvestment) {
                u.lastBaseClaimTime += bC * 8 hours;
            }
        }
        
        uint256 aP;
        if (u.totalInvestment >= 100e18 && aC > u.lastAirdropCycle) {
            for (uint256 c = u.lastAirdropCycle; c < aC; c++) {
                if (cycleEligible[_user][c]) aP += cycleAirdropEarned[_user][c];
            }
            if (aP > 0) {
                uint256 aCap = u.totalInvestment * 5;
                if (u.airdropClaimed + aP > aCap) aP = aCap > u.airdropClaimed ? aCap - u.airdropClaimed : 0;
                u.airdropClaimed += aP;
                u.airdropVault   += aP;
            }
            u.lastAirdropCycle = aC;
        }
    }

    function _checkpointAirdrop(address _user) internal {
        User storage u = users[_user];
        if (u.totalInvestment < 100e18) { lastAirdropUpdate[_user] = block.timestamp; return; }
        uint256 lT = lastAirdropUpdate[_user] == 0 ? block.timestamp : lastAirdropUpdate[_user];
        if (lT == block.timestamp) return;
        uint256 sC  = (lT - launchTime) / CYCLE_DURATION;
        uint256 eC  = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256 inv = u.totalInvestment;
        for (uint256 c = sC; c <= eC; c++) {
            uint256 cST = launchTime + c * CYCLE_DURATION;
            uint256 tS  = lT > cST ? lT : cST;
            uint256 tE  = block.timestamp < cST + CYCLE_DURATION ? block.timestamp : cST + CYCLE_DURATION;
            if (tE > tS) cycleAirdropEarned[_user][c] += (inv * (tE - tS)) / 86400000;
        }
        lastAirdropUpdate[_user] = block.timestamp;
    }

    // =====================================
    // 🟢 3X3 MATRIX & MATCHING INCOME
    // =====================================
    
    function getMatchingTier(address _u) public view returns (uint8) {
        User memory u = users[_u];
        uint256 weak = u.totalTeamVolume > u.strongestLegVolume ? u.totalTeamVolume - u.strongestLegVolume : 0;
        uint256 strong = u.strongestLegVolume;
        
        if (strong >= 16635000e18 && weak >= 16635000e18) return 7;
        if (strong >= 6635000e18 && weak >= 6635000e18) return 6;
        if (strong >= 1635000e18 && weak >= 1635000e18) return 5;
        if (strong >= 635000e18 && weak >= 635000e18) return 4;
        if (strong >= 135000e18 && weak >= 135000e18) return 3;
        if (strong >= 35000e18 && weak >= 35000e18) return 2;
        if (strong >= 10000e18 && weak >= 10000e18) return 1;
        return 0;
    }

    function invest(address _sponsor, uint256 _amt, bool _isTE) external nonReentrant {
        if (_amt < MIN_INVESTMENT || _sponsor == address(0)) revert E();

        InvestmentWindow storage iw = userInvestmentWindows[msg.sender];
        if (block.timestamp >= iw.windowStartTime + 24 hours) { iw.windowStartTime = block.timestamp; iw.totalInvested = 0; }
        if (iw.totalInvested + _amt > MAX_INVESTMENT) revert E();
        iw.totalInvested += _amt;

        _runGlobalCheckpoints(msg.sender);
        if (users[msg.sender].totalInvestment == 0) lastAirdropUpdate[msg.sender] = block.timestamp;

        address aSponsor = users[msg.sender].sponsor == address(0) ? _sponsor : users[msg.sender].sponsor;
        
        // 🟢 Sets Cycle Maintenance for Matching Income & Airdrop
        if (_amt >= 100e18 && aSponsor != address(0) && aSponsor != insuranceWallet)
            cycleEligible[aSponsor][(block.timestamp - launchTime) / CYCLE_DURATION] = true; 
        
        if (users[msg.sender].sponsor == address(0) && msg.sender != insuranceWallet) {
            if (users[_sponsor].totalInvestment == 0 && _sponsor != insuranceWallet) revert E(); 
            User storage u = users[msg.sender];
            u.sponsor = _sponsor; u.registrationTime = block.timestamp; u.lastBaseClaimTime = block.timestamp;
            uint256 curCycle = (block.timestamp - launchTime) / CYCLE_DURATION;
            u.lastAirdropCycle = curCycle; u.lastClaimedCycle = curCycle;

            users[_sponsor].directReferralsCount++;
            
            // 🟢 3x3 Fast-Start Tracking Check
            if (users[_sponsor].directReferralsCount == 3) {
                address u1 = users[_sponsor].sponsor;
                if (u1 != address(0)) {
                    users[u1].directsWith3Count++;
                    if (users[u1].directsWith3Count == 3 && !users[u1].isMatrixUnlocked) {
                        users[u1].isMatrixUnlocked = true;
                        users[u1].matrixUnlockTime = block.timestamp;
                    }
                }
            }
        }

        USDT.transferFrom(msg.sender, address(this), _amt);
        uint256 fee = _amt < 10e18 ? 1e18 : (_amt * 10) / 100;
        USDT.transfer(insuranceWallet, fee);

        _buyHMT(((_amt - fee) * (_isTE ? 20 : 80)) / 100);
        users[msg.sender].totalInvestment += _amt;
        
        _updateUplineVolume(msg.sender, _amt);
        _distributeMatchingIncome(_amt);
    }

    function _updateUplineVolume(address _inv, uint256 _amt) internal {
        address cB = _inv;
        address up = users[cB].sponsor;
        uint256 cCyc = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256 cWk = (block.timestamp - launchTime) / 7 days;
        uint256 cEnd = launchTime + (cCyc + 1) * CYCLE_DURATION;
        uint256 secRem = cEnd > block.timestamp ? cEnd - block.timestamp : 0;
        
        // 🟢 Time-weighted daily ROI pushed directly to upline 3x3 Family
        uint256 generatedROI = (_amt * 6 * secRem) / (1000 * 86400);

        for (uint16 d; d < 50; d++) {
            if (up == address(0)) break;
            users[up].totalTeamVolume += _amt;
            legVolume[up][cB] += _amt;
            
            if (legVolume[up][cB] > users[up].strongestLegVolume) {
                users[up].strongestLegVolume = legVolume[up][cB];
                users[up].strongestLegUser = cB;
            }
            
            weeklyTotalVolume[up][cWk] += _amt;
            weeklyLegVolume[up][cB][cWk] += _amt;
            if (weeklyLegVolume[up][cB][cWk] > weeklyStrongestLegVolume[up][cWk])
                weeklyStrongestLegVolume[up][cWk] = weeklyLegVolume[up][cB][cWk];
            
            cycleFamilyROI[up][cCyc] += generatedROI;
            
            cB = up;
            up = users[up].sponsor;
        }
    }

    function _distributeMatchingIncome(uint256 _amt) internal {
        uint256 cC = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256 cEnd = launchTime + (cC + 1) * CYCLE_DURATION;
        uint256 secRem = cEnd > block.timestamp ? cEnd - block.timestamp : 0;
        
        // 🟢 O(1) Time-Weighted Global ROI calculation for Matching Income
        uint256 totalCycleROI = (_amt * 6 * secRem) / (1000 * 86400); 
        
        uint256 pool_2_pct = (totalCycleROI * 2) / 100;
        uint256 pool_1_5_pct = (totalCycleROI * 15) / 1000;
        uint256 pool_1_pct = (totalCycleROI * 1) / 100;

        if (matchingSharesPerTier[1] > 0) cycleMatchingRPS[cC][1] += (pool_2_pct * 1e18) / matchingSharesPerTier[1];
        if (matchingSharesPerTier[2] > 0) cycleMatchingRPS[cC][2] += (pool_2_pct * 1e18) / matchingSharesPerTier[2];
        if (matchingSharesPerTier[3] > 0) cycleMatchingRPS[cC][3] += (pool_1_5_pct * 1e18) / matchingSharesPerTier[3];
        if (matchingSharesPerTier[4] > 0) cycleMatchingRPS[cC][4] += (pool_1_5_pct * 1e18) / matchingSharesPerTier[4];
        if (matchingSharesPerTier[5] > 0) cycleMatchingRPS[cC][5] += (pool_1_pct * 1e18) / matchingSharesPerTier[5];
        if (matchingSharesPerTier[6] > 0) cycleMatchingRPS[cC][6] += (pool_1_pct * 1e18) / matchingSharesPerTier[6];
        if (matchingSharesPerTier[7] > 0) cycleMatchingRPS[cC][7] += (pool_1_pct * 1e18) / matchingSharesPerTier[7];
    }

    function _maintenancePassed(address _u, uint256 c) private view returns (bool) {
        uint256 sW = c * 4;
        for (uint256 w = sW; w < sW + 4; w++) {
            uint256 tot = weeklyTotalVolume[_u][w];
            uint256 str = weeklyStrongestLegVolume[_u][w];
            uint256 weaker = tot > str ? tot - str : 0;
            if (weaker < WEEKLY_MAINTENANCE) return false;
        }
        return true;
    }

    function _internalClaimCycleRewards(address _u) internal {
        User storage usr = users[_u];
        uint256 aC = (block.timestamp - launchTime) / CYCLE_DURATION;
        
        uint8 qT = getMatchingTier(_u);
        UserMatrix storage um = userMatrixData[_u];
        
        if (qT > um.currentMatrixTier) {
            if (um.currentMatrixTier > 0 && matchingSharesPerTier[um.currentMatrixTier] > 0)
                matchingSharesPerTier[um.currentMatrixTier]--;
            matchingSharesPerTier[qT]++;
            for (uint8 i = um.currentMatrixTier + 1; i <= qT; i++) um.upgradeCycle[i] = aC + 1;
            um.currentMatrixTier = qT;
        }

        uint256 eC = aC > usr.lastClaimedCycle + MAX_CLAIM_CYCLES ? usr.lastClaimedCycle + MAX_CLAIM_CYCLES : aC;
        uint256 totalPayout;

        for (uint256 c = usr.lastClaimedCycle; c < eC; c++) {
            
            // 🟢 Tier Matching Pool Claim
            if (cycleEligible[_u][c] && um.currentMatrixTier > 0) {
                uint8 aT;
                for (int16 i = int16(uint16(um.currentMatrixTier)); i >= 1; i--) {
                    uint8 ui = uint8(uint16(i));
                    if (um.upgradeCycle[ui] != 0 && c >= um.upgradeCycle[ui]) { aT = ui; break; }
                }
                if (aT > 0) totalPayout += cycleMatchingRPS[c][aT];
            }

            // 🟢 3x3 Family ROI Claim
            if (usr.isMatrixUnlocked && _maintenancePassed(_u, c)) {
                uint256 rate = (usr.matrixUnlockTime - usr.registrationTime <= 28 days) ? 2 : 1;
                uint256 famROI = cycleFamilyROI[_u][c];
                totalPayout += (famROI * rate * 1e18) / 100;
            }
        }
        
        if (eC > usr.lastClaimedCycle) usr.lastClaimedCycle = eC;
        if (totalPayout > 0) usr.matrixRoyaltyVault += (totalPayout / 1e18);
    }

    // =====================================
    // 🟢 DEFI HUB & WITHDRAWALS
    // =====================================
    function claimROI() external nonReentrant { _runGlobalCheckpoints(msg.sender); }

    function withdraw(uint256 _amt, bool _isAir) external nonReentrant {
        _runGlobalCheckpoints(msg.sender);
        User storage u = users[msg.sender];
        if (_amt == 0 || (_isAir ? u.airdropVault : u.levelIncomeVault + u.matrixRoyaltyVault) < _amt) revert E();
        uint256 dC = (u.totalInvestment * 10) / 100;
        if (dC > 1000e18) dC = 1000e18;

        WithdrawWindow storage w = userWithdrawWindows[msg.sender];
        if (block.timestamp >= w.windowStartTime + 24 hours) { w.windowStartTime = block.timestamp; w.withdrawnAmount = 0; }
        if (w.withdrawnAmount + _amt > dC) revert E();
        w.withdrawnAmount += _amt;

        if (_isAir) {
            u.airdropVault -= _amt;
        } else {
            if (_amt <= u.levelIncomeVault) u.levelIncomeVault -= _amt;
            else {
                uint256 remainder = _amt - u.levelIncomeVault;
                if (u.matrixRoyaltyVault < remainder) revert E(); 
                u.matrixRoyaltyVault -= remainder;
                u.levelIncomeVault = 0;
            }
        }

        uint256 fee = (_amt * 5) / 100;
        if (!isPayoutLockedToHMT && HMT.getUSDTForHMT(1e18) >= 5e18) isPayoutLockedToHMT = true;

        if (!isPayoutLockedToHMT) {
            USDT.transfer(msg.sender, _amt - fee);
        } else {
            uint256 hmtPay = HMT.getHMTForUSDT(_amt - fee);
            if (HMT.balanceOf(address(this)) < hmtPay) revert E();
            HMT.transfer(msg.sender, hmtPay);
        }
    }

    function _buyHMT(uint256 _uAmt) internal {
        USDT.approve(address(pancakeRouter), _uAmt);
        address[] memory path = new address[](2);
        path[0] = address(USDT); path[1] = address(HMT);
        pancakeRouter.swapExactTokensForTokens(_uAmt, (HMT.getHMTForUSDT(_uAmt) * 75) / 100, path, address(this), block.timestamp + 300);
    }
    
    function autoBalanceLiquidity() external nonReentrant {
        IPancakePair pair = IPancakePair(IPancakeFactory(pancakeRouter.factory()).getPair(address(HMT), address(USDT)));
        if (address(pair) == address(0)) revert E();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool hmtIs0  = pair.token0() == address(HMT);
        uint256 hmtRes  = hmtIs0 ? r0 : r1;
        uint256 usdtRes = hmtIs0 ? r1 : r0;
        
        if (hmtRes == 0 || usdtRes == 0) revert E();
        if (lastHmtReserve > 0 && hmtRes > (lastHmtReserve / 2)) revert E();
        
        uint256 hToAdd = hmtRes * 2;
        uint256 uReq   = (hToAdd * usdtRes) / hmtRes;
        if (HMT.balanceOf(address(this)) < hToAdd || USDT.balanceOf(address(this)) < uReq) revert E();
        
        HMT.approve(address(pancakeRouter), hToAdd);
        USDT.approve(address(pancakeRouter), uReq);
        pancakeRouter.addLiquidity(address(HMT), address(USDT), hToAdd, uReq, 0, 0, DEAD_ADDRESS, block.timestamp + 300);
        lastHmtReserve = hmtRes + hToAdd;
    }

    function claimDailyReward() external nonReentrant {
        uint256 daysPassed = (block.timestamp - lastDailyRewardClaimTime) / 1 days;
        if (daysPassed > 0) {
            uint256 payout = daysPassed * 1e18; 
            if (USDT.balanceOf(address(this)) < payout || HMT.balanceOf(address(this)) < payout) revert E();
            lastDailyRewardClaimTime += daysPassed * 1 days;
            USDT.transfer(liquiditymentainerWallet, payout);
            HMT.transfer(liquiditymentainerWallet, payout);
        }
    }

    function enterLottery() external nonReentrant {
        uint256 pid = currentLotteryId;
        if (poolHasEntered[pid][msg.sender]) revert E();
        USDT.transferFrom(msg.sender, address(this), LOTTERY_ENTRY_FEE);
        LotteryPool storage p = lotteryPools[pid];
        if (p.participants.length == 0) p.startTime = block.timestamp;
        poolHasEntered[pid][msg.sender] = true;
        p.participants.push(msg.sender);
        if (p.participants.length == LOTTERY_MAX_PARTICIPANTS) currentLotteryId = pid + 1;
        _autoResolveLottery();
    }

    function _autoResolveLottery() internal returns (bool) {
        uint256 pId = lastResolvedLotteryId;
        LotteryPool storage p = lotteryPools[pId];
        if (p.isResolved || p.participants.length < LOTTERY_MAX_PARTICIPANTS || block.timestamp < p.startTime + LOTTERY_MATURITY_TIME) return false;
        
        uint256 baseRate = HMT.getHMTForUSDT(1e18);
        uint256 totalNeeded = baseRate * 14000;
        uint256 requiredBalance = totalNeeded + totalNeeded / 100;
        if (HMT.balanceOf(address(this)) < requiredBalance) return false;
        
        p.isResolved = true;
        address[] memory mem = p.participants;
        uint256 rand = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, blockhash(block.number - 1), msg.sender, pId)));
        
        for (uint256 i = LOTTERY_MAX_PARTICIPANTS - 1; i > 0; i--) {
            rand = uint256(keccak256(abi.encodePacked(rand)));
            uint256 j = rand % (i + 1);
            address tmp = mem[i]; mem[i] = mem[j]; mem[j] = tmp;
        }
        for (uint256 i; i < LOTTERY_MAX_PARTICIPANTS; i++) {
            uint256 mult = i < 5 ? 400 : (i < 10 ? 200 : (i < 50 ? 150 : 100));
            HMT.transfer(mem[i], baseRate * mult);
        }
        lastResolvedLotteryId = pId + 1;
        return true;
    }

    function resolveReadyLottery() external nonReentrant { if (msg.sender == tx.origin) revert E(); if (!_autoResolveLottery()) revert E(); }

    function resolveUnclaimedLottery(uint256 _pId) external nonReentrant {
        LotteryPool storage p = lotteryPools[_pId];
        if (p.isResolved || p.participants.length == 0 || p.participants.length >= LOTTERY_MAX_PARTICIPANTS || block.timestamp < p.startTime + LOTTERY_MATURITY_TIME) revert E();
        uint256 totalRefund = p.participants.length * LOTTERY_ENTRY_FEE;
        if (USDT.balanceOf(address(this)) < totalRefund) revert E();
        p.isResolved = true;
        for (uint256 i; i < p.participants.length; i++) USDT.transfer(p.participants[i], LOTTERY_ENTRY_FEE);
        if (_pId == currentLotteryId) currentLotteryId++;
        if (_pId == lastResolvedLotteryId) lastResolvedLotteryId++;
    }

    function _autoLiquidateChunk() internal {
        if (activeLoanUsers.length == 0) return;
        for (uint256 checks; checks < AUTO_BATCH_SIZE && activeLoanUsers.length > 0; checks++) {
            if (currentLiquidationIndex >= activeLoanUsers.length) currentLiquidationIndex = 0;
            address b = activeLoanUsers[currentLiquidationIndex];
            if (isLiquidatable(b)) {
                delete userLoans[b];
                _removeActiveLoanUser(b);
            } else { currentLiquidationIndex++; }
        }
    }

    function isLiquidatable(address _u) public view returns (bool) {
        Loan memory ln = userLoans[_u];
        if (!ln.isActive) return false;
        if (block.timestamp >= ln.loanStartTime + (3 * CYCLE_DURATION)) return true;
        return HMT.getUSDTForHMT(ln.collateralHMT) < (ln.initialCollateralValueUSDT * 75) / 100;
    }

    function _removeActiveLoanUser(address _user) internal {
        uint256 idx = activeLoanIndex[_user];
        uint256 last = activeLoanUsers.length - 1;
        if (idx != last) {
            address lastUsr = activeLoanUsers[last];
            activeLoanUsers[idx] = lastUsr;
            activeLoanIndex[lastUsr] = idx;
        }
        activeLoanUsers.pop(); delete activeLoanIndex[_user];
    }

    function takeLoan(uint256 _hAmt) external nonReentrant {
        if (_hAmt == 0 || userLoans[msg.sender].isActive) revert E();
        _autoLiquidateChunk();
        uint256 cVal = HMT.getUSDTForHMT(_hAmt);
        uint256 lAmt = cVal >> 1; 
        if (USDT.balanceOf(address(this)) < lAmt) revert E();
        HMT.transferFrom(msg.sender, address(this), _hAmt);
        USDT.transfer(msg.sender, lAmt);
        userLoans[msg.sender] = Loan({ collateralHMT: _hAmt, loanAmountUSDT: lAmt, initialCollateralValueUSDT: cVal, loanStartTime: block.timestamp, isActive: true });
        activeLoanIndex[msg.sender] = activeLoanUsers.length;
        activeLoanUsers.push(msg.sender);
    }

    function repayLoan() external nonReentrant {
        Loan storage ln = userLoans[msg.sender];
        if (!ln.isActive || isLiquidatable(msg.sender)) revert E();
        uint256 cyclesPassed = (block.timestamp - ln.loanStartTime) / CYCLE_DURATION;
        uint256 dbt = ln.loanAmountUSDT + ((ln.loanAmountUSDT * 10 * cyclesPassed) / 100);
        uint256 col = ln.collateralHMT;
        USDT.transferFrom(msg.sender, address(this), dbt);
        delete userLoans[msg.sender];
        _removeActiveLoanUser(msg.sender); 
        HMT.transfer(msg.sender, col);
    }

    function swapHMTForUSDT(uint256 _hAmt) external nonReentrant {
        if (_hAmt == 0) revert E();
        uint256 uPay = HMT.getUSDTForHMT(_hAmt);
        if (USDT.balanceOf(address(this)) < uPay) revert E();
        HMT.transferFrom(msg.sender, address(this), _hAmt);
        USDT.transfer(msg.sender, uPay);
    }

    function stakeHMTTokens(uint256 _amt) external nonReentrant {
        if (_amt == 0) revert E();
        HMT.transferFrom(msg.sender, address(this), _amt);
        userTokenStakes[msg.sender].push(TokenStake({ amount: _amt, startTime: block.timestamp }));
    }

    function unstakeAllHMT() external nonReentrant {
        if (userTokenStakes[msg.sender].length == 0) revert E();
        uint256 tG; uint256 tP;
        uint8[6] memory pens = [20, 15, 10, 8, 7, 6];
        for (uint256 i; i < userTokenStakes[msg.sender].length; i++) {
            uint256 elapsed = block.timestamp - userTokenStakes[msg.sender][i].startTime;
            uint256 amt = _calculateCompound(userTokenStakes[msg.sender][i].amount, elapsed / 8 hours);
            tG += amt;
            uint256 cyc = elapsed / CYCLE_DURATION;
            tP += (amt * (cyc < 6 ? pens[cyc] : 0)) / 100;
        }
        uint256 n = tG - tP;
        if (HMT.balanceOf(address(this)) < n) revert E();
        delete userTokenStakes[msg.sender];
        HMT.transfer(msg.sender, n);
    }
}