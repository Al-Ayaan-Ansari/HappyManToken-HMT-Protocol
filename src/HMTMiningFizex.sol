// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 { function transfer(address,uint256) external returns(bool); function transferFrom(address,address,uint256) external returns(bool); function balanceOf(address) external view returns(uint256); function approve(address,uint256) external returns(bool); }
interface IERC721 { function ownerOf(uint256) external view returns(address); function transferFrom(address,address,uint256) external; }
interface IHMTToken is IERC20 { function getHMTForUSDT(uint256) external view returns(uint256); function getUSDTForHMT(uint256) external view returns(uint256); }
interface IPancakeFactory { function getPair(address,address) external view returns(address); }
interface IPancakePair { function token0() external view returns(address); function getReserves() external view returns(uint112,uint112,uint32); }
interface IPancakeRouter02 { function factory() external pure returns(address); function swapExactTokensForTokens(uint256,uint256,address[] calldata,address,uint256) external returns(uint256[] memory); function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) external returns(uint256,uint256,uint256); }
interface INFTContract is IERC721 { function mintRewardNFT(address,uint8) external; function getNFTTier(uint256) external view returns(uint8); function getTierPrice(uint8) external view returns(uint256); }

error ZeroAddress();
error AlreadyEntered();
error NoSmartContracts();
error LotteryNotReady();
error PoolResolved();
error PoolEmpty();
error PoolFull();
error NotMature();
error InvalidAmount();
error InsufficientLiquidity();
error NotOwner();
error InvalidTier();
error NotStaked();
error BelowMinLimit();
error ExceedsMaxInvest();
error InvalidSponsor();
error InsufficientVault();
error ExceedsDailyLimit();
error LiquidityPairNotCreated();
error HMTCapacityAboveLimit();
error InsufficientTreasuryHMT();
error InsufficientTreasuryUSDT();
error Liquidatable();
error HealthyCollateral();

contract HMTMining {
    IERC20           public USDT;
    IHMTToken        public HMT;
    IPancakeRouter02 public pancakeRouter;
    INFTContract     public NFT;
    address public companyWallet;
    address public ownerWallet;
    
    uint256 public launchTime;

    uint256 public constant MIN_INVESTMENT           = 2e18;
    uint256 public constant MAX_INVESTMENT           = 2500e18;
    uint256 public constant MAX_CLAIM_CYCLES         = 24;
    uint256 public constant CYCLE_DURATION           = 28 days;
    uint256 public constant WEEKLY_MAINTENANCE       = 1000e18;
    uint256 public constant OWNER_CYCLE_PAYOUT       = 21_000e18;
    uint256 public constant MAX_OWNER_PAYOUTS        = 100;
    uint256 public constant LOTTERY_ENTRY_FEE        = 100e18;
    uint256 public constant LOTTERY_MAX_PARTICIPANTS = 100;
    uint256 public constant LOTTERY_MATURITY_TIME    = 45 days;
    uint256 public constant AUTO_BATCH_SIZE          = 5;
    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    bool    public isPayoutLockedToHMT;
    uint256 public ownerPayoutsClaimed;

    uint256 private _status = 1;
    modifier nonReentrant() { if (_status == 2) revert AlreadyEntered(); _status = 2; _; _status = 1; }
    modifier onlyOwner()    { if (msg.sender != ownerWallet) revert NotOwner(); _; }

    struct User {
        address sponsor;
        bool    isMatrixUnlocked;
        bool    isTierZeroLocked;
        bool    hasWithdrawn;
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

    struct UserMatrix      { uint8 currentMatrixTier; mapping(uint8 => uint256) upgradeCycle; }
    struct WithdrawWindow  { uint256 windowStartTime; uint256 withdrawnAmount; }
    struct InvestmentWindow{ uint256 windowStartTime; uint256 totalInvested; }

    mapping(address => User)             public users;
    mapping(address => UserMatrix)       public userMatrixData;
    mapping(address => mapping(address => uint256)) public legVolume;
    mapping(address => InvestmentWindow) public userInvestmentWindows;
    mapping(address => WithdrawWindow)   public userWithdrawWindows;

    mapping(address => mapping(uint256 => uint256)) public cycleTotalVolume;
    mapping(address => mapping(uint256 => uint256)) public cycleStrongestLegVolume;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public cycleLegVolume;
    mapping(address => mapping(uint256 => uint256)) public weeklyTotalVolume;
    mapping(address => mapping(uint256 => uint256)) public weeklyStrongestLegVolume;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public weeklyLegVolume;

    mapping(address => mapping(uint256 => bool))    public airdropEligible;
    mapping(address => uint256)                     public lastAirdropUpdate;
    mapping(address => mapping(uint256 => uint256)) public cycleAirdropEarned;

    uint256[10] public totalSharesPerTier;
    mapping(uint256 => mapping(uint8 => uint256)) public cycleRPS;

    // 🟢 AUDIT FIX #4 & #5: NFT Unbounded Loops Solved with O(1) Cumulative Logic
    uint256[8] public nftTotalSharesPerTier;
    mapping(uint8 => uint256) public cumulativeNFTRPS; 

    struct StakedNFT  { uint8 tier; uint256 startCycle; uint256 rewardDebt; }
    mapping(address => uint256[])  public userStakedTokenIds;
    mapping(uint256 => StakedNFT) public tokenStakingData;

    struct LotteryPool { uint256 startTime; address[] participants; bool isResolved; }
    uint256 public currentLotteryId      = 1;
    uint256 public lastResolvedLotteryId = 1;
    mapping(uint256 => LotteryPool)              public lotteryPools;
    mapping(uint256 => mapping(address => bool)) public poolHasEntered;

    struct Loan { uint256 collateralHMT; uint256 loanAmountUSDT; uint256 initialCollateralValueUSDT; uint256 loanStartTime; bool isActive; }
    mapping(address => Loan) public userLoans;
    address[] public activeLoanUsers;
    mapping(address => uint256) public activeLoanIndex;
    uint256 public currentLiquidationIndex;
    
    struct TokenStake { uint256 amount; uint256 startTime; }
    mapping(address => TokenStake[]) public userTokenStakes;

    // ── Events ───────────────────────────────────────────────────────────────
    event Invested(address indexed user, uint256 amount, bool isTwentyEightyRatio);
    event FeePaid(address indexed user, uint256 feeAmount);
    event ROIClaimed(address indexed user, uint256 baseAmount, uint256 airdropAmount);
    event LevelIncomeDistributed(address indexed sponsor, address indexed downline, uint256 amount, uint8 level);
    event MatrixUnlocked(address indexed user, bool missedDeadline);
    event MatrixTierUpgraded(address indexed user, uint8 newTier, uint256 eligibleCycle);
    event MatrixRoyaltyClaimed(address indexed user, uint256 cyclePayout, uint256 cycleId, bool passedMaintenance);
    event Withdrawn(address indexed user, uint256 amount, bool paidInHMT);
    event AirdropForfeited(address indexed user);
    event OwnerPayoutProcessed(address indexed ownerWallet, uint256 amount, uint256 totalCyclesClaimed);
    event NFTStaked(address indexed user, uint256 tokenId, uint8 tier);
    event NFTUnstaked(address indexed user, uint256 tokenId);
    event NFTRewardsClaimed(address indexed user, uint256 amount);
    event LotteryEntered(address indexed user, uint256 poolId);
    event LotteryResolved(uint256 indexed poolId);
    event HMTSwappedForUSDT(address indexed user, uint256 hmtIn, uint256 usdtOut);
    event LiquidityAutoBalanced(address indexed triggerer, uint256 hmtAdded, uint256 usdtAdded);
    event TokensStaked(address indexed user, uint256 amount, uint256 stakeIndex);
    event AllTokensUnstaked(address indexed user, uint256 totalPayout, uint256 totalPenalty);
    event LoanTaken(address indexed user, uint256 collateralHMT, uint256 loanUSDT);
    event LoanRepaid(address indexed user, uint256 debtPaidUSDT, uint256 collateralReturnedHMT);
    event LoanLiquidated(address indexed user, uint256 collateralSeizedHMT, uint256 defaultedDebtUSDT);

    constructor(address _usdt, address _hmt, address _router, address _companyWallet, address _ownerWallet, address _nftContract) {
        // FIX: check ALL address params, not just company/owner wallets
        if (_usdt == address(0) || _hmt == address(0) || _router == address(0) || _nftContract == address(0)) revert ZeroAddress();
        if (_companyWallet == address(0) || _ownerWallet == address(0)) revert ZeroAddress();
        USDT = IERC20(_usdt); HMT = IHMTToken(_hmt); pancakeRouter = IPancakeRouter02(_router);
        companyWallet = _companyWallet; ownerWallet = _ownerWallet; NFT = INFTContract(_nftContract);
        launchTime = block.timestamp;
        User storage cw = users[companyWallet];
        cw.totalInvestment  = 10000e18;
        cw.registrationTime = block.timestamp;
        cw.isMatrixUnlocked = true;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        ownerWallet = newOwner;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _tierPct(uint8 i) internal pure returns (uint256) { return uint256(i) + 1; }
    function _nftTierPct(uint8 i) internal pure returns (uint256) {
        if (i == 0) return 0;
        if (i <= 5) return uint256(i);
        return i == 6 ? 15 : 35;
    }

    function _runGlobalCheckpoints(address _user) internal {
        _processOwnerPayout();
        _autoLiquidateChunk();
        
        if (users[_user].totalInvestment > 0) {
            _internalClaimROI(_user);
            _internalClaimMatrixRoyalty(_user);
            _internalClaimNFTRewards(_user);
        }
    }

    function _processOwnerPayout() internal {
        uint256 claimed = ownerPayoutsClaimed;
        if (claimed >= MAX_OWNER_PAYOUTS) return;
        uint256 passed = (block.timestamp - launchTime) / CYCLE_DURATION;
        if (passed <= claimed) return;
        uint256 pending = passed - claimed;
        if (claimed + pending > MAX_OWNER_PAYOUTS) pending = MAX_OWNER_PAYOUTS - claimed;
        uint256 amt = pending * OWNER_CYCLE_PAYOUT;
        if (HMT.balanceOf(address(this)) >= amt) {
            ownerPayoutsClaimed = claimed + pending;
            HMT.transfer(ownerWallet, amt);
            emit OwnerPayoutProcessed(ownerWallet, amt, ownerPayoutsClaimed);
        }
    }

    function autoBalanceLiquidity() external nonReentrant {
        IPancakePair pair = IPancakePair(IPancakeFactory(pancakeRouter.factory()).getPair(address(HMT), address(USDT)));
        if (address(pair) == address(0)) revert LiquidityPairNotCreated();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool hmtIs0  = pair.token0() == address(HMT);
        uint256 hmtRes  = hmtIs0 ? r0 : r1;
        uint256 usdtRes = hmtIs0 ? r1 : r0;
        
        // 🟢 AUDIT FIX #1: Division by zero check
        if (hmtRes == 0 || usdtRes == 0) revert InsufficientLiquidity();
        if (hmtRes >= 600e18) revert HMTCapacityAboveLimit();
        
        uint256 hToAdd = 1000e18;
        uint256 uReq   = (hToAdd * usdtRes) / hmtRes;
        
        if (HMT.balanceOf(address(this))  < hToAdd) revert InsufficientTreasuryHMT();
        if (USDT.balanceOf(address(this)) < uReq)   revert InsufficientTreasuryUSDT();
        
        HMT.approve(address(pancakeRouter), hToAdd);
        USDT.approve(address(pancakeRouter), uReq);
        pancakeRouter.addLiquidity(address(HMT), address(USDT), hToAdd, uReq, 0, 0, DEAD_ADDRESS, block.timestamp + 300);
        emit LiquidityAutoBalanced(msg.sender, hToAdd, uReq);
    }

    function enterLottery() external nonReentrant {
        if (users[msg.sender].totalInvestment == 0) revert InvalidSponsor(); // only registered investors may enter; non-investors could siphon HMT prize pool
        uint256 pid = currentLotteryId;
        if (poolHasEntered[pid][msg.sender]) revert AlreadyEntered();
        USDT.transferFrom(msg.sender, address(this), LOTTERY_ENTRY_FEE);
        LotteryPool storage p = lotteryPools[pid];
        if (p.participants.length == 0) p.startTime = block.timestamp;
        poolHasEntered[pid][msg.sender] = true;
        p.participants.push(msg.sender);
        
        emit LotteryEntered(msg.sender, pid);

        if (p.participants.length == LOTTERY_MAX_PARTICIPANTS) currentLotteryId = pid + 1;
        _autoResolveLottery();
    }

    function _autoResolveLottery() internal returns (bool) {
        uint256 pId = lastResolvedLotteryId;
        LotteryPool storage p = lotteryPools[pId];
        if (p.isResolved || p.participants.length < LOTTERY_MAX_PARTICIPANTS || block.timestamp < p.startTime + LOTTERY_MATURITY_TIME) return false;
        uint256 baseRate = HMT.getHMTForUSDT(1e18);
        // FIX: total payout = baseRate * (5*400 + 5*200 + 40*150 + 50*100) = baseRate * 14000.
        // Add 1% buffer so the balance check doesn't pass with exactly zero headroom,
        // reducing risk of mid-loop failure if HMT balance shifts slightly between check and transfers.
        uint256 totalNeeded = baseRate * 14000;
        uint256 requiredBalance = totalNeeded + totalNeeded / 100; // 101% of needed
        if (HMT.balanceOf(address(this)) < requiredBalance) return false;
        p.isResolved = true;
        address[] memory mem = p.participants;
        
        // 🟢 AUDIT FIX #2: Enhanced Pseudo-Randomness
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
        emit LotteryResolved(pId);
        return true;
    }

    function resolveReadyLottery() external nonReentrant {
        if (msg.sender == tx.origin) revert NoSmartContracts();
        if (!_autoResolveLottery())  revert LotteryNotReady();
    }

    function resolveUnclaimedLottery(uint256 _pId) external nonReentrant {
        LotteryPool storage p = lotteryPools[_pId];
        if (p.isResolved) revert PoolResolved();
        if (p.participants.length == 0) revert PoolEmpty();
        if (p.participants.length >= LOTTERY_MAX_PARTICIPANTS) revert PoolFull();
        if (block.timestamp < p.startTime + LOTTERY_MATURITY_TIME) revert NotMature();
        // FIX: verify treasury can cover all refunds before marking resolved and iterating
        uint256 totalRefund = p.participants.length * LOTTERY_ENTRY_FEE;
        if (USDT.balanceOf(address(this)) < totalRefund) revert InsufficientTreasuryUSDT();
        p.isResolved = true;
        uint256 len = p.participants.length;
        for (uint256 i; i < len; i++) USDT.transfer(p.participants[i], LOTTERY_ENTRY_FEE);
        if (_pId == currentLotteryId)      currentLotteryId++;
        if (_pId == lastResolvedLotteryId) lastResolvedLotteryId++;
        emit LotteryResolved(_pId);
    }

    // ==========================================
    // 🏦 COLLATERALIZED LOANS
    // ==========================================
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

    function getLoanDebt(address _u) public view returns (uint256) {
        Loan memory ln = userLoans[_u];
        if (!ln.isActive) return 0;
        
        // 🟢 AUDIT FIX #3: Strict Simple Interest Logic (10% flat per completed cycle)
        uint256 cyclesPassed = (block.timestamp - ln.loanStartTime) / CYCLE_DURATION;
        return ln.loanAmountUSDT + ((ln.loanAmountUSDT * 10 * cyclesPassed) / 100);
    }

    function isLiquidatable(address _u) public view returns (bool) {
        Loan memory ln = userLoans[_u];
        if (!ln.isActive) return false;
        if (block.timestamp >= ln.loanStartTime + (3 * CYCLE_DURATION)) return true;
        return HMT.getUSDTForHMT(ln.collateralHMT) < (ln.initialCollateralValueUSDT * 75) / 100;
    }

    function _autoLiquidateChunk() internal {
        if (activeLoanUsers.length == 0) return;
        for (uint256 checks; checks < AUTO_BATCH_SIZE && activeLoanUsers.length > 0; checks++) {
            if (currentLiquidationIndex >= activeLoanUsers.length) currentLiquidationIndex = 0;
            address b = activeLoanUsers[currentLiquidationIndex];
            if (isLiquidatable(b)) {
                uint256 col = userLoans[b].collateralHMT;
                uint256 dbt = getLoanDebt(b);
                delete userLoans[b];
                _removeActiveLoanUser(b);
                emit LoanLiquidated(b, col, dbt);
            } else { currentLiquidationIndex++; }
        }
    }

    function takeLoan(uint256 _hAmt) external nonReentrant {
        if (_hAmt == 0 || userLoans[msg.sender].isActive) revert InvalidAmount();
        if (msg.sender == companyWallet) revert InvalidAmount(); // companyWallet has synthetic investment; block to prevent treasury drain edge cases
        _autoLiquidateChunk();
        
        uint256 cVal = HMT.getUSDTForHMT(_hAmt);
        uint256 lAmt = cVal >> 1; // 50% LTV
        
        if (USDT.balanceOf(address(this)) < lAmt) revert InsufficientLiquidity();

        HMT.transferFrom(msg.sender, address(this), _hAmt);
        USDT.transfer(msg.sender, lAmt);
        userLoans[msg.sender] = Loan({
            collateralHMT: _hAmt, loanAmountUSDT: lAmt,
            initialCollateralValueUSDT: cVal, loanStartTime: block.timestamp, isActive: true
        });
        activeLoanIndex[msg.sender] = activeLoanUsers.length;
        activeLoanUsers.push(msg.sender);
        emit LoanTaken(msg.sender, _hAmt, lAmt);
    }

    function repayLoan() external nonReentrant {
        Loan storage ln = userLoans[msg.sender];
        if (!ln.isActive) revert InvalidAmount();
        if (isLiquidatable(msg.sender)) revert Liquidatable();

        uint256 dbt = getLoanDebt(msg.sender);
        uint256 col = ln.collateralHMT;

        // FIX: CEI — pull USDT BEFORE deleting state and returning collateral.
        // Original code deleted the loan and returned HMT before transferFrom,
        // meaning a failed transferFrom would wipe the loan for free.
        USDT.transferFrom(msg.sender, address(this), dbt);

        delete userLoans[msg.sender];
        _removeActiveLoanUser(msg.sender);

        HMT.transfer(msg.sender, col);
        emit LoanRepaid(msg.sender, dbt, col);
    }

    function liquidateLoan(address _b) public nonReentrant {
        Loan storage ln = userLoans[_b];
        if (!ln.isActive) revert InvalidAmount();
        if (!isLiquidatable(_b)) revert HealthyCollateral();

        uint256 col = ln.collateralHMT;
        uint256 dbt = getLoanDebt(_b);
        delete userLoans[_b];
        _removeActiveLoanUser(_b);
        emit LoanLiquidated(_b, col, dbt);
    }

    function batchLiquidate(uint256 lim) external nonReentrant {
        for (uint256 i = activeLoanUsers.length; i > 0 && lim > 0; lim--) {
            i--;
            address b = activeLoanUsers[i];
            if (isLiquidatable(b)) {
                uint256 col = userLoans[b].collateralHMT;
                uint256 dbt = getLoanDebt(b);
                delete userLoans[b];
                _removeActiveLoanUser(b);
                emit LoanLiquidated(b, col, dbt);
            }
        }
    }

    // ==========================================
    // 🟢 AUDIT FIX #4 & #5: O(1) NFT REWARDS
    // ==========================================
    function stakeNFT(uint256 _tId) external nonReentrant {
        if (NFT.ownerOf(_tId) != msg.sender) revert NotOwner();
        uint8 t = NFT.getNFTTier(_tId);
        if (t < 1 || t > 7) revert InvalidTier();
        _internalClaimNFTRewards(msg.sender);
        
        NFT.transferFrom(msg.sender, address(this), _tId);
        
        uint256 ac = (block.timestamp - launchTime) / CYCLE_DURATION;
        tokenStakingData[_tId] = StakedNFT(t, ac + 1, cumulativeNFTRPS[t]);
        userStakedTokenIds[msg.sender].push(_tId);
        nftTotalSharesPerTier[t]++;
        
        emit NFTStaked(msg.sender, _tId, t);
    }

    function unstakeNFT(uint256 _tId) external nonReentrant {
        uint256[] storage ids = userStakedTokenIds[msg.sender];
        uint256 len  = ids.length;
        uint256 tIdx = type(uint256).max;
        for (uint256 i; i < len; i++) { if (ids[i] == _tId) { tIdx = i; break; } }
        if (tIdx == type(uint256).max) revert NotStaked();
        
        _internalClaimNFTRewards(msg.sender);
        
        uint8 t = tokenStakingData[_tId].tier;
        nftTotalSharesPerTier[t]--;
        ids[tIdx] = ids[len - 1];
        ids.pop();
        delete tokenStakingData[_tId];
        
        NFT.transferFrom(address(this), msg.sender, _tId);
        emit NFTUnstaked(msg.sender, _tId);
    }

    function getPendingNFTRewards(address _user) public view returns (uint256 pend) {
        uint256 ac = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256[] memory ids = userStakedTokenIds[_user];
        uint256[8] memory tierPriceCache; // cache per-tier price: NFT.getTierPrice() called at most once per tier (7 tiers max) instead of once per NFT
        for (uint256 i; i < ids.length; i++) {
            StakedNFT memory s = tokenStakingData[ids[i]];
            if (ac > s.startCycle) {
                uint8 tier = s.tier;
                if (tierPriceCache[tier] == 0) tierPriceCache[tier] = NFT.getTierPrice(tier);
                uint256 tp = tierPriceCache[tier];
                uint256 cyclesPassed = ac - s.startCycle;
                uint256 matrixShare = cumulativeNFTRPS[tier] - s.rewardDebt;
                pend += (matrixShare / 1e18) + ((tp * cyclesPassed) / 100);
            }
        }
    }

    function claimNFTRewards() external nonReentrant { _internalClaimNFTRewards(msg.sender); }

    function _internalClaimNFTRewards(address _user) internal {
        uint256 ac = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256 pay;
        uint256[] storage ids = userStakedTokenIds[_user];
        uint256[8] memory tierPriceCache; // cache per-tier price: NFT.getTierPrice() called at most once per tier instead of once per NFT
        for (uint256 i; i < ids.length; i++) {
            StakedNFT storage s = tokenStakingData[ids[i]];
            if (ac > s.startCycle) {
                uint8 tier = s.tier;
                if (tierPriceCache[tier] == 0) tierPriceCache[tier] = NFT.getTierPrice(tier);
                uint256 tp = tierPriceCache[tier];
                uint256 cyclesPassed = ac - s.startCycle;
                uint256 matrixShare = cumulativeNFTRPS[tier] - s.rewardDebt;
                
                pay += (matrixShare / 1e18) + ((tp * cyclesPassed) / 100);
                
                s.startCycle = ac;
                s.rewardDebt = cumulativeNFTRPS[tier];
            }
        }
        if (pay > 0) { 
            users[_user].matrixRoyaltyVault += pay; 
            emit NFTRewardsClaimed(_user, pay);
        }
    }

    function invest(address _sponsor, uint256 _amt, bool _isTE) external nonReentrant {
        if (_amt < MIN_INVESTMENT)  revert BelowMinLimit();
        if (_sponsor == address(0)) revert ZeroAddress();

        InvestmentWindow storage iw = userInvestmentWindows[msg.sender];
        if (block.timestamp >= iw.windowStartTime + 24 hours) { iw.windowStartTime = block.timestamp; iw.totalInvested = 0; }
        if (iw.totalInvested + _amt > MAX_INVESTMENT) revert ExceedsMaxInvest();
        iw.totalInvested += _amt;

        _runGlobalCheckpoints(msg.sender);
        if (users[msg.sender].totalInvestment == 0) lastAirdropUpdate[msg.sender] = block.timestamp;

        address aSponsor = users[msg.sender].sponsor == address(0) ? _sponsor : users[msg.sender].sponsor;
        if (_amt >= 100e18 && aSponsor != address(0) && aSponsor != companyWallet)
            airdropEligible[aSponsor][(block.timestamp - launchTime) / CYCLE_DURATION + 1] = true;
        
        if (users[msg.sender].sponsor == address(0) && msg.sender != companyWallet) {
            if (users[_sponsor].totalInvestment == 0 && _sponsor != companyWallet) revert InvalidSponsor();
            User storage u = users[msg.sender];
            u.sponsor           = _sponsor;
            u.registrationTime  = block.timestamp;
            u.lastBaseClaimTime = block.timestamp;
            uint256 curCycle    = (block.timestamp - launchTime) / CYCLE_DURATION;
            u.lastAirdropCycle  = curCycle;
            u.lastClaimedCycle  = curCycle;

            users[_sponsor].directReferralsCount++;
            if (users[_sponsor].directReferralsCount == 3) {
                address u1 = users[_sponsor].sponsor;
                if (u1 != address(0)) {
                    users[u1].directsWith3Count++;
                    if (users[u1].directsWith3Count == 3) {
                        address u2 = users[u1].sponsor;
                        if (u2 != address(0)) {
                            users[u2].directsWith9Count++;
                            if (users[u2].directsWith9Count == 3 && !users[u2].isMatrixUnlocked) {
                                users[u2].isMatrixUnlocked = true;
                                if (block.timestamp > users[u2].registrationTime + 30 days) users[u2].isTierZeroLocked = true;
                                totalSharesPerTier[0]++;
                                userMatrixData[u2].upgradeCycle[0] = (block.timestamp - launchTime) / CYCLE_DURATION + 1;
                                emit MatrixUnlocked(u2, users[u2].isTierZeroLocked);
                            }
                        }
                    }
                }
            }
        }

        USDT.transferFrom(msg.sender, address(this), _amt);
        uint256 fee = (_amt * 10) / 100; // flat 10% — dead branch (_amt<10e18→1e18) removed; MIN_INVESTMENT=2e18 made it reachable and could leave near-zero for _buyHMT
        USDT.transfer(companyWallet, fee);
        emit FeePaid(msg.sender, fee);

        _buyHMT(((_amt - fee) * (_isTE ? 20 : 80)) / 100);
        users[msg.sender].totalInvestment += _amt;
        if (_amt == MAX_INVESTMENT) { try NFT.mintRewardNFT(msg.sender, 1) {} catch {} }
        _updateUplineVolume(msg.sender, _amt);
        _distributeMatrixRoyalty(_amt);
        
        emit Invested(msg.sender, _amt, _isTE);
    }

    function _buyHMT(uint256 _uAmt) internal {
        USDT.approve(address(pancakeRouter), _uAmt);
        address[] memory path = new address[](2);
        path[0] = address(USDT); path[1] = address(HMT);
        pancakeRouter.swapExactTokensForTokens(_uAmt, (HMT.getHMTForUSDT(_uAmt) * 75) / 100, path, address(this), block.timestamp + 300);
    }

    function _updateUplineVolume(address _inv, uint256 _amt) internal {
        address cB   = _inv;
        address up   = users[cB].sponsor;
        uint256 cCyc = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256 cWk  = (block.timestamp - launchTime) / 7 days;
        for (uint16 d; d < 50; d++) {
            if (up == address(0)) break;
            users[up].totalTeamVolume += _amt;
            legVolume[up][cB] += _amt;
            if (legVolume[up][cB] > users[up].strongestLegVolume) {
                users[up].strongestLegVolume = legVolume[up][cB];
                users[up].strongestLegUser   = cB;
            }
            cycleTotalVolume[up][cCyc]   += _amt;
            cycleLegVolume[up][cB][cCyc] += _amt;
            if (cycleLegVolume[up][cB][cCyc] > cycleStrongestLegVolume[up][cCyc])
                cycleStrongestLegVolume[up][cCyc] = cycleLegVolume[up][cB][cCyc];
            weeklyTotalVolume[up][cWk]   += _amt;
            weeklyLegVolume[up][cB][cWk] += _amt;
            if (weeklyLegVolume[up][cB][cWk] > weeklyStrongestLegVolume[up][cWk])
                weeklyStrongestLegVolume[up][cWk] = weeklyLegVolume[up][cB][cWk];
            cB = up;
            up = users[up].sponsor;
        }
    }

    function _distributeMatrixRoyalty(uint256 _amt) internal {
        uint256 cC   = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256 pool = (_amt * 18) / 100;
        for (uint8 i; i <= 9; i++) {
            if (totalSharesPerTier[i] > 0)
                cycleRPS[cC][i] += (pool * _tierPct(i) * 1e18) / (100 * totalSharesPerTier[i]);
        }
        
        for (uint8 i = 1; i <= 7; i++) {
            if (nftTotalSharesPerTier[i] > 0) {
                cumulativeNFTRPS[i] += (pool * _nftTierPct(i) * 1e18) / (100 * nftTotalSharesPerTier[i]);
            }
        }
    }

    function _checkpointAirdrop(address _user) internal {
        User storage u = users[_user];
        if (u.totalInvestment < 100e18 || u.hasWithdrawn) { lastAirdropUpdate[_user] = block.timestamp; return; }
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

    function isAirdropEligibleThisCycle(address _user) public view returns (bool) {
        return airdropEligible[_user][(block.timestamp - launchTime) / CYCLE_DURATION];
    }
    function isAirdropUnlockedForNextCycle(address _user) public view returns (bool) {
        return airdropEligible[_user][(block.timestamp - launchTime) / CYCLE_DURATION + 1];
    }

    function getPendingROI(address _user) public view returns (uint256 bPend, uint256 aPend) {
        if (_user == companyWallet || users[_user].totalInvestment == 0) return (0, 0);
        User memory u = users[_user];
        uint256 bC = (block.timestamp - u.lastBaseClaimTime) / 8 hours;
        if (bC > 0) {
            uint256 cB = (u.totalInvestment * 2 * bC) / 1000;
            bPend = (u.baseClaimed + cB > u.totalInvestment) ? (u.totalInvestment > u.baseClaimed ? u.totalInvestment - u.baseClaimed : 0) : cB;
        }
        if (u.totalInvestment >= 100e18 && !u.hasWithdrawn) {
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
                if (airdropEligible[_user][c]) aPend += cE;
            }
            uint256 aCap = u.totalInvestment * 5;
            if (u.airdropClaimed + aPend > aCap) aPend = aCap > u.airdropClaimed ? aCap - u.airdropClaimed : 0;
        }
    }

    function claimROI() external nonReentrant { _runGlobalCheckpoints(msg.sender); }

    function _internalClaimROI(address _user) internal {
        _checkpointAirdrop(_user);
        User storage u = users[_user];
        uint256 aC = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256 bC = (block.timestamp - u.lastBaseClaimTime) / 8 hours;
        uint256 bP;
        if (bC > 0) {
            uint256 cB = (u.totalInvestment * 2 * bC) / 1000;
            bP = (u.baseClaimed + cB > u.totalInvestment) ? (u.totalInvestment > u.baseClaimed ? u.totalInvestment - u.baseClaimed : 0) : cB;
            if (bP > 0) {
                u.lastBaseClaimTime += bC * 8 hours;
                u.baseClaimed       += bP;
                u.levelIncomeVault  += bP;
                address cS = u.sponsor;
                if (cS != address(0)) {
                    if (users[cS].directReferralsCount >= 1 && users[cS].totalInvestment >= 100e18) {
                        uint256 r = (bP * 15) / 100;
                        users[cS].levelIncomeVault += r;
                        emit LevelIncomeDistributed(cS, _user, r, 1);
                    }
                    address cS2 = users[cS].sponsor;
                    if (cS2 != address(0)) {
                        if (users[cS2].directReferralsCount >= 2 && users[cS2].totalInvestment >= 100e18) {
                            uint256 r = (bP * 10) / 100;
                            users[cS2].levelIncomeVault += r;
                            emit LevelIncomeDistributed(cS2, _user, r, 2);
                        }
                        address cS3 = users[cS2].sponsor;
                        if (cS3 != address(0) && users[cS3].directReferralsCount >= 3 && users[cS3].totalInvestment >= 100e18) {
                            uint256 r = (bP * 5) / 100;
                            users[cS3].levelIncomeVault += r;
                            emit LevelIncomeDistributed(cS3, _user, r, 3);
                        }
                    }
                }
            }
        }
        uint256 aP;
        if (u.totalInvestment >= 100e18 && !u.hasWithdrawn && aC > u.lastAirdropCycle) {
            for (uint256 c = u.lastAirdropCycle; c < aC; c++) {
                if (airdropEligible[_user][c]) aP += cycleAirdropEarned[_user][c];
            }
            if (aP > 0) {
                uint256 aCap = u.totalInvestment * 5;
                if (u.airdropClaimed + aP > aCap) aP = aCap > u.airdropClaimed ? aCap - u.airdropClaimed : 0;
                u.airdropClaimed += aP;
                u.airdropVault   += aP;
            }
            u.lastAirdropCycle = aC;
        }
        
        if (bP > 0 || aP > 0) {
            emit ROIClaimed(_user, bP, aP);
        }
    }

    function getWeeklyWeakerLegsVolume(address _user, uint256 weekId) public view returns (uint256) {
        uint256 tot = weeklyTotalVolume[_user][weekId];
        uint256 str = weeklyStrongestLegVolume[_user][weekId];
        // FIX: safe-subtract to prevent underflow if data is ever skewed
        return tot > str ? tot - str : 0;
    }

    function getMatrixRoyaltyTier(address _user) public view returns (uint8) {
        User memory u    = users[_user];
        // FIX: safe-subtract — strongestLegVolume should never exceed totalTeamVolume but guard anyway
        uint256 wVol = u.totalTeamVolume > u.strongestLegVolume ? u.totalTeamVolume - u.strongestLegVolume : 0;
        uint256 qVol = wVol < u.strongestLegVolume ? wVol : u.strongestLegVolume;
        uint256 inv  = u.totalInvestment;
        uint256 refs = u.directReferralsCount;
        if (qVol >= 18835000e18 && inv >= 10000e18 && refs >= 9) return 9;
        if (qVol >=  8835000e18 && inv >=  9000e18 && refs >= 8) return 8;
        if (qVol >=  3835000e18 && inv >=  7000e18 && refs >= 7) return 7;
        if (qVol >=  1835000e18 && inv >=  5000e18 && refs >= 6) return 6;
        if (qVol >=   835000e18 && inv >=  2500e18 && refs >= 5) return 5;
        if (qVol >=   335000e18 && inv >=  1000e18 && refs >= 4) return 4;
        if (qVol >=   135000e18 && inv >=   500e18 && refs >= 3) return 3;
        if (qVol >=    35000e18 && inv >=   250e18 && refs >= 2) return 2;
        if (qVol >=    10000e18 && inv >=   100e18 && refs >= 1) return 1;
        return 0;
    }

    function _maintenancePassed(address _u, uint256 c) private view returns (bool) {
        uint256 sW = c * 4;
        for (uint256 w = sW; w < sW + 4; w++) {
            uint256 tot = weeklyTotalVolume[_u][w];
            uint256 str = weeklyStrongestLegVolume[_u][w];
            // FIX: guard underflow — strongest leg should never exceed total, but safe-subtract anyway
            uint256 weaker = tot > str ? tot - str : 0;
            if (weaker < WEEKLY_MAINTENANCE) return false;
        }
        return true;
    }

    function _resolveMatrixCycle(address _u, UserMatrix storage um, uint256 c) private view returns (uint256 cP, bool passed) {
        passed = _maintenancePassed(_u, c);
        if (passed && um.currentMatrixTier > 0) {
            uint8 aT;
            // FIX: uint8 loop with i >= 1 wraps to 255 when i==0; use int16 to prevent infinite loop
            for (int16 i = int16(uint16(um.currentMatrixTier)); i >= 1; i--) {
                uint8 ui = uint8(uint16(i));
                if (um.upgradeCycle[ui] != 0 && c >= um.upgradeCycle[ui]) { aT = ui; break; }
            }
            cP = aT > 0 ? cycleRPS[c][aT] : (c >= um.upgradeCycle[0] ? cycleRPS[c][0] : 0);
        } else if (c >= um.upgradeCycle[0]) {
            cP = cycleRPS[c][0];
        }
    }

    function getPendingMatrixRewards(address _u) public view returns (uint256) {
        if (!users[_u].isMatrixUnlocked) return 0;
        UserMatrix storage um = userMatrixData[_u];
        uint256 last = users[_u].lastClaimedCycle;
        uint256 eC   = (block.timestamp - launchTime) / CYCLE_DURATION;
        if (eC > last + MAX_CLAIM_CYCLES) eC = last + MAX_CLAIM_CYCLES;
        uint256 tP;
        for (uint256 c = last; c < eC; c++) { (uint256 cp,) = _resolveMatrixCycle(_u, um, c); tP += cp; }
        return tP / 1e18;
    }

    function _internalClaimMatrixRoyalty(address _u) internal {
        User storage usr = users[_u];
        if (!usr.isMatrixUnlocked) return;
        uint256 aC = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint8   qT = usr.isTierZeroLocked ? 0 : getMatrixRoyaltyTier(_u);
        UserMatrix storage um = userMatrixData[_u];
        if (aC <= usr.lastClaimedCycle && qT <= um.currentMatrixTier) return;
        if (qT > um.currentMatrixTier) {
            if (um.currentMatrixTier > 0 && totalSharesPerTier[um.currentMatrixTier] > 0)
                totalSharesPerTier[um.currentMatrixTier]--;
            totalSharesPerTier[qT]++;
            for (uint8 i = um.currentMatrixTier + 1; i <= qT; i++) um.upgradeCycle[i] = aC + 1;
            um.currentMatrixTier = qT;
            emit MatrixTierUpgraded(_u, qT, aC + 1);
        }
        uint256 eC = aC > usr.lastClaimedCycle + MAX_CLAIM_CYCLES ? usr.lastClaimedCycle + MAX_CLAIM_CYCLES : aC;
        uint256 tP;
        // FIX: removed per-cycle MatrixRoyaltyClaimed emit inside loop (up to 24 events = ~24k gas wasted).
        // Emit once after loop with total; cycle range readable from lastClaimedCycle → eC.
        for (uint256 c = usr.lastClaimedCycle; c < eC; c++) {
            (uint256 cP,) = _resolveMatrixCycle(_u, um, c);
            tP += cP;
        }
        if (eC > usr.lastClaimedCycle) usr.lastClaimedCycle = eC;
        if (tP > 0) {
            uint256 payout = tP / 1e18;
            usr.matrixRoyaltyVault += payout;
            emit MatrixRoyaltyClaimed(_u, payout, eC, true);
        }
    }

    // ==========================================
    // 🟢 AUDIT FIX #6: O(1) STAKING COMPOUND MATH
    // ==========================================
    function _calculateCompound(uint256 principal, uint256 periods) internal pure returns (uint256) {
        uint256 ratio = 1e18;
        uint256 base = 1002 * 1e15; // 1.002 in 1e18 scale
        while (periods > 0) {
            if (periods % 2 == 1) ratio = (ratio * base) / 1e18;
            base = (base * base) / 1e18;
            periods /= 2;
        }
        return (principal * ratio) / 1e18;
    }

    function stakeHMTTokens(uint256 _amt) external nonReentrant {
        if (_amt == 0) revert InvalidAmount();
        HMT.transferFrom(msg.sender, address(this), _amt);
        userTokenStakes[msg.sender].push(TokenStake({ amount: _amt, startTime: block.timestamp }));
        emit TokensStaked(msg.sender, _amt, userTokenStakes[msg.sender].length - 1);
    }

    function getStakingOverview(address _user) public view returns (uint256 tG, uint256 tP, uint256 nP) {
        TokenStake[] memory stks = userTokenStakes[_user];
        uint8[6] memory pens = [20, 15, 10, 8, 7, 6];
        
        for (uint256 i; i < stks.length; i++) {
            uint256 elapsed = block.timestamp - stks[i].startTime;
            uint256 periods = elapsed / 8 hours;
            
            uint256 amt = _calculateCompound(stks[i].amount, periods);
            tG += amt;
            
            uint256 cyc = elapsed / CYCLE_DURATION;
            uint256 penPct = cyc < 6 ? pens[cyc] : 0;
            tP += (amt * penPct) / 100;
        }
        nP = tG - tP;
    }

    function unstakeAllHMT() external nonReentrant {
        if (userTokenStakes[msg.sender].length == 0) revert InvalidAmount();
        (, uint256 p, uint256 n) = getStakingOverview(msg.sender);
        if (HMT.balanceOf(address(this)) < n) revert InsufficientLiquidity();
        delete userTokenStakes[msg.sender];
        HMT.transfer(msg.sender, n);
        emit AllTokensUnstaked(msg.sender, n, p);
    }

    function getTotalWithdrawable(address _u) external view returns (uint256 rT, uint256 aT) {
        User memory usr = users[_u];
        (uint256 bP, uint256 aP) = (_u != companyWallet && usr.totalInvestment > 0) ? getPendingROI(_u) : (0, 0);
        rT = usr.levelIncomeVault + usr.matrixRoyaltyVault + bP + (usr.isMatrixUnlocked ? getPendingMatrixRewards(_u) : 0) + getPendingNFTRewards(_u);
        aT = usr.airdropVault + aP;
    }

    function getDailyWithdrawLimit(address _u) public view returns (uint256 mD, uint256 rT) {
        uint256 cL = (users[_u].totalInvestment * 10) / 100;
        mD = cL > 1000e18 ? 1000e18 : cL;
        WithdrawWindow memory w = userWithdrawWindows[_u];
        rT = block.timestamp < w.windowStartTime + 24 hours ? (mD > w.withdrawnAmount ? mD - w.withdrawnAmount : 0) : mD;
    }

    function withdraw(uint256 _amt, bool _isAir) external nonReentrant {
        _runGlobalCheckpoints(msg.sender);
        User storage u = users[msg.sender];
        if (_amt == 0 || (_isAir ? u.airdropVault : u.levelIncomeVault + u.matrixRoyaltyVault) < _amt) revert InsufficientVault();
        uint256 dC = (u.totalInvestment * 10) / 100;
        if (dC > 1000e18) dC = 1000e18;

        WithdrawWindow storage w = userWithdrawWindows[msg.sender];
        if (block.timestamp >= w.windowStartTime + 24 hours) { w.windowStartTime = block.timestamp; w.withdrawnAmount = 0; }
        if (w.withdrawnAmount + _amt > dC) revert ExceedsDailyLimit();
        w.withdrawnAmount += _amt;

        if (_isAir) {
            if (!u.hasWithdrawn) { 
                u.hasWithdrawn = true; 
                emit AirdropForfeited(msg.sender);
            }
            u.airdropVault -= _amt;
        } else {
            if (_amt <= u.levelIncomeVault) u.levelIncomeVault -= _amt;
            else {
                uint256 remainder = _amt - u.levelIncomeVault;
                if (u.matrixRoyaltyVault < remainder) revert InsufficientVault(); // explicit guard: combined check above doesn't prevent per-vault underflow
                u.matrixRoyaltyVault -= remainder;
                u.levelIncomeVault = 0;
            }
        }

        uint256 fee = (_amt * 5) / 100;
        USDT.transfer(ownerWallet, fee);

        if (!isPayoutLockedToHMT && HMT.getUSDTForHMT(1e18) >= 5e18) isPayoutLockedToHMT = true;

        if (!isPayoutLockedToHMT) {
            USDT.transfer(msg.sender, _amt - fee);
            emit Withdrawn(msg.sender, _amt, false);
        } else {
            uint256 hmtPay = HMT.getHMTForUSDT(_amt - fee);
            if (HMT.balanceOf(address(this)) < hmtPay) revert InsufficientLiquidity();
            HMT.transfer(msg.sender, hmtPay);
            emit Withdrawn(msg.sender, _amt, true);
        }
    }

    // 🟢 AUDIT FIX (Medium): Added _minUsdtOut to protect against Flashloan Sandwiches
    function swapHMTForUSDT(uint256 _hAmt, uint256 _minUsdtOut) external nonReentrant {
        if (_hAmt == 0) revert InvalidAmount();
        uint256 uPay = HMT.getUSDTForHMT(_hAmt);
        if (uPay < _minUsdtOut) revert InvalidAmount(); 
        if (USDT.balanceOf(address(this)) < uPay) revert InsufficientLiquidity();
        HMT.transferFrom(msg.sender, address(this), _hAmt);
        USDT.transfer(msg.sender, uPay);
        emit HMTSwappedForUSDT(msg.sender, _hAmt, uPay);
    }
}