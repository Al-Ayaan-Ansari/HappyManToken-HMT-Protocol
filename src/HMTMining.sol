// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 { function transfer(address,uint256) external returns(bool); function transferFrom(address,address,uint256) external returns(bool); function balanceOf(address) external view returns(uint256); function approve(address,uint256) external returns(bool); }
interface IERC721 { function ownerOf(uint256) external view returns(address); function transferFrom(address,address,uint256) external; }
interface IHMTToken is IERC20 { function getHMTForUSDT(uint256) external view returns(uint256); function getUSDTForHMT(uint256) external view returns(uint256); }
interface IPancakeFactory { function getPair(address,address) external view returns(address); }
interface IPancakePair { function token0() external view returns(address); function getReserves() external view returns(uint112,uint112,uint32); }
interface IPancakeRouter02 { function factory() external pure returns(address); function swapExactTokensForTokens(uint256,uint256,address[] calldata,address,uint256) external returns(uint256[] memory); function addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256) external returns(uint256,uint256,uint256); }
interface INFTContract is IERC721 { function mintRewardNFT(address,uint8) external; function getNFTTier(uint256) external view returns(uint8); function getTierPrice(uint8) external view returns(uint256); }

// ── Errors ───────────────────────────────────────────────────────────────────
error InvalidAmount();
error InsufficientLiquidity();
error InsufficientVault();
error ExceedsDailyLimit();
error ZeroAddress();
error AlreadyEntered();
error NotOwner();
error InvalidTier();
error NotStaked();
error InvalidSponsor();
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

    // Bools packed with address sponsor (same 32-byte slot); uint96 fills the rest
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
    struct InvestmentWindow{ uint256 windowStartTime; uint256 totalInvested;   }

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

    uint256[8] public nftTotalSharesPerTier;
    mapping(uint256 => mapping(uint8 => uint256)) public cycleNFTRPS;

    struct StakedNFT  { uint8 tier; uint256 startCycle; }
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
    event Invested(address indexed user, uint256 amount);
    event MatrixUnlocked(address indexed user);
    event MatrixRoyaltySettled(address indexed user, uint256 totalPayout);
    event Withdrawn(address indexed user, uint256 amount, bool paidInHMT);
    event LotteryEntered(address indexed user, uint256 poolId);
    event LotteryResolved(uint256 indexed poolId);
    event LoanTaken(address indexed user, uint256 collateralHMT, uint256 loanUSDT);
    event LoanRepaid(address indexed user, uint256 debt, uint256 collateral);
    event LoanLiquidated(address indexed user, uint256 collateral);

    // ── Constructor ──────────────────────────────────────────────────────────
    constructor(address _usdt, address _hmt, address _router, address _companyWallet, address _ownerWallet, address _nftContract) {
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

    // ── Pure tier helpers (replaces storage arrays — zero SLOAD) ─────────────
    function _tierPct(uint8 i) internal pure returns (uint256) { return uint256(i) + 1; }
    function _nftTierPct(uint8 i) internal pure returns (uint256) {
        if (i == 0) return 0;
        if (i <= 5) return uint256(i);
        return i == 6 ? 15 : 35;
    }

    // ── Global checkpoint orchestrator ───────────────────────────────────────
    function _runGlobalCheckpoints(address _user) internal {
        _processOwnerPayout();
        _autoLiquidateChunk();
        if (users[_user].totalInvestment > 0) {
            _internalClaimROI(_user);
            _internalClaimMatrixRoyalty(_user);
            _internalClaimNFTRewards(_user);
        }
    }

    // ── Owner payout ─────────────────────────────────────────────────────────
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
        }
    }

    // ── Liquidity ─────────────────────────────────────────────────────────────
    function autoBalanceLiquidity() external nonReentrant {
        IPancakePair pair = IPancakePair(IPancakeFactory(pancakeRouter.factory()).getPair(address(HMT), address(USDT)));
        if (address(pair) == address(0)) revert InsufficientLiquidity();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool hmtIs0  = pair.token0() == address(HMT);
        uint256 hmtRes  = hmtIs0 ? r0 : r1;
        uint256 usdtRes = hmtIs0 ? r1 : r0;
        if (hmtRes >= 600e18) revert InsufficientLiquidity();
        uint256 hToAdd = 1000e18;
        uint256 uReq   = (hToAdd * usdtRes) / hmtRes;
        if (HMT.balanceOf(address(this))  < hToAdd) revert InsufficientLiquidity();
        if (USDT.balanceOf(address(this)) < uReq)   revert InsufficientLiquidity();
        HMT.approve(address(pancakeRouter), hToAdd);
        USDT.approve(address(pancakeRouter), uReq);
        pancakeRouter.addLiquidity(address(HMT), address(USDT), hToAdd, uReq, 0, 0, DEAD_ADDRESS, block.timestamp + 300);
    }

    // ── Lottery ───────────────────────────────────────────────────────────────
    function enterLottery() external nonReentrant {
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
        if (HMT.balanceOf(address(this)) < baseRate * 14000) return false;
        p.isResolved = true;
        address[] memory mem = p.participants;
        uint256 rand = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender, pId)));
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

    function resolveUnclaimedLottery(uint256 _pId) external nonReentrant {
        LotteryPool storage p = lotteryPools[_pId];
        if (p.isResolved || p.participants.length == 0)                    revert InvalidAmount();
        if (p.participants.length >= LOTTERY_MAX_PARTICIPANTS)              revert InvalidAmount();
        if (block.timestamp < p.startTime + LOTTERY_MATURITY_TIME)         revert InvalidAmount();
        p.isResolved = true;
        uint256 len = p.participants.length;
        for (uint256 i; i < len; i++) USDT.transfer(p.participants[i], LOTTERY_ENTRY_FEE);
        if (_pId == currentLotteryId)      currentLotteryId++;
        if (_pId == lastResolvedLotteryId) lastResolvedLotteryId++;
        emit LotteryResolved(_pId);
    }

    // ── Loans ─────────────────────────────────────────────────────────────────
    function _removeActiveLoanUser(address _user) internal {
        uint256 idx  = activeLoanIndex[_user];
        uint256 last = activeLoanUsers.length - 1;
        if (idx != last) {
            address lastUsr = activeLoanUsers[last];
            activeLoanUsers[idx] = lastUsr;
            activeLoanIndex[lastUsr] = idx;
        }
        activeLoanUsers.pop();
        delete activeLoanIndex[_user];
    }

    function getLoanDebt(address _u) public view returns (uint256) {
        Loan memory ln = userLoans[_u];
        if (!ln.isActive) return 0;
        return ln.loanAmountUSDT + ((ln.initialCollateralValueUSDT * 10 * (1 + ((block.timestamp - ln.loanStartTime) / CYCLE_DURATION))) / 100);
    }

    function isLiquidatable(address _u) public view returns (bool) {
        Loan memory ln = userLoans[_u];
        if (!ln.isActive) return false;
        if (block.timestamp >= ln.loanStartTime + 3 * CYCLE_DURATION) return true;
        return HMT.getUSDTForHMT(ln.collateralHMT) < (ln.initialCollateralValueUSDT * 75) / 100;
    }

    function _autoLiquidateChunk() internal {
        if (activeLoanUsers.length == 0) return;
        for (uint256 checks; checks < AUTO_BATCH_SIZE && activeLoanUsers.length > 0; checks++) {
            if (currentLiquidationIndex >= activeLoanUsers.length) currentLiquidationIndex = 0;
            address b = activeLoanUsers[currentLiquidationIndex];
            if (isLiquidatable(b)) {
                uint256 col = userLoans[b].collateralHMT;
                delete userLoans[b];
                _removeActiveLoanUser(b);
                emit LoanLiquidated(b, col);
            } else { currentLiquidationIndex++; }
        }
    }

    function takeLoan(uint256 _hAmt) external nonReentrant {
        if (_hAmt == 0 || userLoans[msg.sender].isActive) revert InvalidAmount();
        uint256 cVal = HMT.getUSDTForHMT(_hAmt);
        uint256 lAmt = cVal >> 1;
        if (USDT.balanceOf(address(this)) < lAmt) revert InsufficientLiquidity();
        HMT.transferFrom(msg.sender, address(this), _hAmt);
        USDT.transfer(msg.sender, lAmt);
        userLoans[msg.sender] = Loan({ collateralHMT: _hAmt, loanAmountUSDT: lAmt, initialCollateralValueUSDT: cVal, loanStartTime: block.timestamp, isActive: true });
        activeLoanIndex[msg.sender] = activeLoanUsers.length;
        activeLoanUsers.push(msg.sender);
        emit LoanTaken(msg.sender, _hAmt, lAmt);
    }

    function repayLoan() external nonReentrant {
        Loan storage ln = userLoans[msg.sender];
        if (!ln.isActive)               revert InvalidAmount();
        if (isLiquidatable(msg.sender)) revert Liquidatable();
        uint256 dbt = getLoanDebt(msg.sender);
        uint256 col = ln.collateralHMT;
        delete userLoans[msg.sender];
        _removeActiveLoanUser(msg.sender);
        USDT.transferFrom(msg.sender, address(this), dbt);
        HMT.transfer(msg.sender, col);
        emit LoanRepaid(msg.sender, dbt, col);
    }

    function liquidateLoan(address _b) public nonReentrant {
        if (!userLoans[_b].isActive) revert InvalidAmount();
        if (!isLiquidatable(_b))     revert HealthyCollateral();
        uint256 col = userLoans[_b].collateralHMT;
        delete userLoans[_b];
        _removeActiveLoanUser(_b);
        emit LoanLiquidated(_b, col);
    }

    function batchLiquidate(uint256 lim) external nonReentrant {
        for (uint256 i = activeLoanUsers.length; i > 0 && lim > 0; lim--) {
            i--;
            address b = activeLoanUsers[i];
            if (isLiquidatable(b)) {
                uint256 col = userLoans[b].collateralHMT;
                delete userLoans[b];
                _removeActiveLoanUser(b);
                emit LoanLiquidated(b, col);
            }
        }
    }

    // ── NFT Staking ───────────────────────────────────────────────────────────
    function stakeNFT(uint256 _tId) external nonReentrant {
        if (NFT.ownerOf(_tId) != msg.sender) revert NotOwner();
        uint8 t = NFT.getNFTTier(_tId);
        if (t < 1 || t > 7) revert InvalidTier();
        _internalClaimNFTRewards(msg.sender);
        NFT.transferFrom(msg.sender, address(this), _tId);
        tokenStakingData[_tId] = StakedNFT(t, (block.timestamp - launchTime) / CYCLE_DURATION + 1);
        userStakedTokenIds[msg.sender].push(_tId);
        nftTotalSharesPerTier[t]++;
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
    }

    function getPendingNFTRewards(address _user) public view returns (uint256 pend) {
        uint256 ac  = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256[] memory ids = userStakedTokenIds[_user];
        for (uint256 i; i < ids.length; i++) {
            StakedNFT memory s = tokenStakingData[ids[i]];
            uint256 tp = NFT.getTierPrice(s.tier);
            for (uint256 c = s.startCycle; c < ac; c++) pend += cycleNFTRPS[c][s.tier] / 1e18 + tp / 100;
        }
    }

    function claimNFTRewards() external nonReentrant { _internalClaimNFTRewards(msg.sender); }

    function _internalClaimNFTRewards(address _user) internal {
        uint256 ac  = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256 pay;
        uint256[] storage ids = userStakedTokenIds[_user];
        uint256 len = ids.length;
        for (uint256 i; i < len; i++) {
            StakedNFT storage s = tokenStakingData[ids[i]];
            if (ac > s.startCycle) {
                uint256 tp = NFT.getTierPrice(s.tier);
                for (uint256 c = s.startCycle; c < ac; c++) pay += cycleNFTRPS[c][s.tier] / 1e18 + tp / 100;
                s.startCycle = ac;
            }
        }
        if (pay > 0) { users[_user].matrixRoyaltyVault += pay; }
    }

    // ── Invest ────────────────────────────────────────────────────────────────
    function invest(address _sponsor, uint256 _amt, bool _isTE) external nonReentrant {
        if (_amt < MIN_INVESTMENT)  revert InvalidAmount();
        if (_sponsor == address(0)) revert ZeroAddress();

        InvestmentWindow storage iw = userInvestmentWindows[msg.sender];
        if (block.timestamp >= iw.windowStartTime + 24 hours) { iw.windowStartTime = block.timestamp; iw.totalInvested = 0; }
        if (iw.totalInvested + _amt > MAX_INVESTMENT) revert InvalidAmount();
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
                                emit MatrixUnlocked(u2);
                            }
                        }
                    }
                }
            }
        }

        USDT.transferFrom(msg.sender, address(this), _amt);
        uint256 fee = _amt < 10e18 ? 1e18 : (_amt * 10) / 100;
        USDT.transfer(companyWallet, fee);
        _buyHMT(((_amt - fee) * (_isTE ? 20 : 80)) / 100);
        users[msg.sender].totalInvestment += _amt;
        if (_amt == MAX_INVESTMENT) { try NFT.mintRewardNFT(msg.sender, 1) {} catch {} }
        _updateUplineVolume(msg.sender, _amt);
        _distributeMatrixRoyalty(_amt);
        emit Invested(msg.sender, _amt);
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
            if (nftTotalSharesPerTier[i] > 0)
                cycleNFTRPS[cC][i] += (pool * _nftTierPct(i) * 1e18) / (100 * nftTotalSharesPerTier[i]);
        }
    }

    // ── Airdrop ───────────────────────────────────────────────────────────────
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

    // ── ROI ───────────────────────────────────────────────────────────────────
    function getPendingROI(address _user) public view returns (uint256 bPend, uint256 aPend) {
        if (_user == companyWallet || users[_user].totalInvestment == 0) return (0, 0);
        User memory u = users[_user];
        uint256 bC = (block.timestamp - u.lastBaseClaimTime) / 8 hours;
        if (bC > 0) {
            uint256 cB = (u.totalInvestment * 2 * bC) / 1000;
            bPend = (u.baseClaimed + cB > u.totalInvestment)
                ? (u.totalInvestment > u.baseClaimed ? u.totalInvestment - u.baseClaimed : 0) : cB;
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
            bP = (u.baseClaimed + cB > u.totalInvestment)
                ? (u.totalInvestment > u.baseClaimed ? u.totalInvestment - u.baseClaimed : 0) : cB;
            if (bP > 0) {
                u.lastBaseClaimTime += bC * 8 hours;
                u.baseClaimed       += bP;
                u.levelIncomeVault  += bP;
                address cS = u.sponsor;
                if (cS != address(0)) {
                    if (users[cS].directReferralsCount >= 1 && users[cS].totalInvestment >= 100e18)
                        users[cS].levelIncomeVault += (bP * 15) / 100;
                    address cS2 = users[cS].sponsor;
                    if (cS2 != address(0)) {
                        if (users[cS2].directReferralsCount >= 2 && users[cS2].totalInvestment >= 100e18)
                            users[cS2].levelIncomeVault += (bP * 10) / 100;
                        address cS3 = users[cS2].sponsor;
                        if (cS3 != address(0) && users[cS3].directReferralsCount >= 3 && users[cS3].totalInvestment >= 100e18)
                            users[cS3].levelIncomeVault += (bP * 5) / 100;
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
        // vault credited above
    }

    // ── Matrix royalty ────────────────────────────────────────────────────────
    function getMatrixRoyaltyTier(address _user) public view returns (uint8) {
        User memory u    = users[_user];
        uint256 wVol = u.totalTeamVolume - u.strongestLegVolume;
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
            if (weeklyTotalVolume[_u][w] - weeklyStrongestLegVolume[_u][w] < WEEKLY_MAINTENANCE) return false;
        }
        return true;
    }

    function _resolveMatrixCycle(address _u, UserMatrix storage um, uint256 c) private view returns (uint256 cP, bool passed) {
        passed = _maintenancePassed(_u, c);
        if (passed && um.currentMatrixTier > 0) {
            uint8 aT;
            for (uint8 i = um.currentMatrixTier; i >= 1; i--) {
                if (um.upgradeCycle[i] != 0 && c >= um.upgradeCycle[i]) { aT = i; break; }
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
        }
        uint256 eC = aC > usr.lastClaimedCycle + MAX_CLAIM_CYCLES ? usr.lastClaimedCycle + MAX_CLAIM_CYCLES : aC;
        uint256 tP;
        for (uint256 c = usr.lastClaimedCycle; c < eC; c++) {
            (uint256 cP,) = _resolveMatrixCycle(_u, um, c);
            tP += cP;
        }
        if (eC > usr.lastClaimedCycle) usr.lastClaimedCycle = eC;
        if (tP > 0) {
            uint256 payout = tP / 1e18;
            usr.matrixRoyaltyVault += payout;
            emit MatrixRoyaltySettled(_u, payout);
        }
    }

    // ── HMT Token Staking ─────────────────────────────────────────────────────
    function stakeHMTTokens(uint256 _amt) external nonReentrant {
        if (_amt == 0) revert InvalidAmount();
        HMT.transferFrom(msg.sender, address(this), _amt);
        userTokenStakes[msg.sender].push(TokenStake({ amount: _amt, startTime: block.timestamp }));
    }

    function getStakingOverview(address _user) public view returns (uint256 tG, uint256 tP, uint256 nP) {
        TokenStake[] memory stks = userTokenStakes[_user];
        for (uint256 i; i < stks.length; i++) {
            uint256 elapsed = block.timestamp - stks[i].startTime;
            uint256 amt     = stks[i].amount;
            uint256 periods = elapsed / 8 hours;
            for (uint256 j; j < periods; j++) amt = (amt * 1002) / 1000;
            tG += amt;
            uint256 cyc    = elapsed / CYCLE_DURATION;
            uint256 penPct = cyc == 0 ? 20 : cyc == 1 ? 15 : cyc == 2 ? 10 : cyc == 3 ? 8 : cyc == 4 ? 7 : cyc == 5 ? 6 : 0;
            tP += (amt * penPct) / 100;
        }
        nP = tG - tP;
    }

    function unstakeAllHMT() external nonReentrant {
        if (userTokenStakes[msg.sender].length == 0) revert InvalidAmount();
        (,, uint256 n) = getStakingOverview(msg.sender);
        if (HMT.balanceOf(address(this)) < n) revert InsufficientLiquidity();
        delete userTokenStakes[msg.sender];
        HMT.transfer(msg.sender, n);
    }

    // ── View helpers ──────────────────────────────────────────────────────────
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
        rT = block.timestamp < w.windowStartTime + 24 hours
            ? (mD > w.withdrawnAmount ? mD - w.withdrawnAmount : 0) : mD;
    }

    // ── Withdraw ──────────────────────────────────────────────────────────────
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
            if (!u.hasWithdrawn) u.hasWithdrawn = true;
            u.airdropVault -= _amt;
        } else {
            if (_amt <= u.levelIncomeVault) u.levelIncomeVault -= _amt;
            else { u.matrixRoyaltyVault -= (_amt - u.levelIncomeVault); u.levelIncomeVault = 0; }
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

    // ── Swap ──────────────────────────────────────────────────────────────────
    function swapHMTForUSDT(uint256 _hAmt) external nonReentrant {
        if (_hAmt == 0) revert InvalidAmount();
        uint256 uPay = HMT.getUSDTForHMT(_hAmt);
        if (USDT.balanceOf(address(this)) < uPay) revert InsufficientLiquidity();
        HMT.transferFrom(msg.sender, address(this), _hAmt);
        USDT.transfer(msg.sender, uPay);
    }
}
