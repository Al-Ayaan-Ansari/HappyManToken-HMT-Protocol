// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";

// ==========================================
// 🔌 INTERFACES
// ==========================================

interface IHMTToken is IERC20 {
    function getHMTForUSDT(uint256 usdtAmount) external view returns (uint256);
    function getUSDTForHMT(uint256 hmtAmount) external view returns (uint256);
}

interface IPancakeRouter02 {
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory amounts);
}

interface INFTContract is IERC721 {
    function mintRewardNFT(address to, uint8 tier) external;
    function getNFTTier(uint256 tokenId) external view returns (uint8);
    function getTierPrice(uint8 tier) external view returns (uint256);
}

// ==========================================
// 🚨 CUSTOM ERRORS (Bytecode Optimization)
// ==========================================
error ZeroAddress();
error AlreadyEntered();
error NoSmartContracts();
error LotteryNotReady();
error PoolResolved();
error PoolEmpty();
error PoolFull();
error NotMature();
error InvalidAmount();
error LoanActive();
error InsufficientLiquidity();
error NoActiveLoan();
error Liquidatable();
error HealthyCollateral();
error NotOwner();
error InvalidTier();
error NotStaked();
error BelowMinLimit();
error ExceedsMaxInvest();
error InvalidSponsor();
error NoStakes();
error InsufficientVault();
error ExceedsDailyLimit();

// ==========================================
// 🏗️ MAIN MINING CONTRACT
// ==========================================

contract HMTMining is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;
    using SafeERC20 for IHMTToken;
    
    IERC20 public USDT;
    IHMTToken public HMT;
    IPancakeRouter02 public pancakeRouter;
    INFTContract public NFT;

    address public companyWallet;
    address public ownerWallet;
    uint256 public launchTime;
    
    uint256 public constant MIN_INVESTMENT = 2 * 1e18;
    uint256 public constant MAX_INVESTMENT = 2500 * 1e18;
    uint16 public constant MAX_DEPTH = 50;
    uint256 public constant MAX_CLAIM_CYCLES = 24;
    uint256 public constant CYCLE_DURATION = 28 days;
    uint256 public constant WEEKLY_MAINTENANCE = 1000 * 1e18;
    uint256 public constant OWNER_CYCLE_PAYOUT = 21_000 * 1e18; 
    uint256 public constant MAX_OWNER_PAYOUTS = 100;
    
    bool public isPayoutLockedToHMT = false;
    uint256 public ownerPayoutsClaimed;

    struct User {
        address sponsor;
        uint256 registrationTime;
        uint256 totalInvestment;     
        uint256 directReferralsCount;
        uint256 directsWith3Count;
        uint256 directsWith9Count;   
        bool isMatrixUnlocked;       
        bool isTierZeroLocked;       
        uint256 totalTeamVolume;     
        uint256 strongestLegVolume;  
        address strongestLegUser;    
        uint256 lastBaseClaimTime;     
        uint256 baseClaimed;           
        uint256 lastAirdropClaimTime;  
        uint256 airdropClaimed;
        bool hasWithdrawn;             
        uint256 lastClaimedCycle;    
        uint256 levelIncomeVault;    
        uint256 matrixRoyaltyVault;  
        uint256 airdropVault; // 🟢 Isolated Airdrop Vault
    }

    struct UserMatrix {
        uint8 currentMatrixTier;
        mapping(uint8 => uint256) upgradeCycle; 
    }
    
    struct WithdrawWindow {
        uint256 windowStartTime;
        uint256 withdrawnAmount;
        uint256 maxDailyLimit; 
    }

    struct InvestmentWindow {
        uint256 windowStartTime;
        uint256 totalInvested;
    }

    mapping(address => User) public users;
    mapping(address => UserMatrix) public userMatrixData;
    mapping(address => mapping(address => uint256)) public legVolume;
    mapping(address => InvestmentWindow) public userInvestmentWindows;
    mapping(address => WithdrawWindow) public userWithdrawWindows;
    
    mapping(address => mapping(uint256 => uint256)) public cycleTotalVolume;
    mapping(address => mapping(uint256 => uint256)) public cycleStrongestLegVolume;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public cycleLegVolume;
    
    mapping(address => mapping(uint256 => uint256)) public weeklyTotalVolume;
    mapping(address => mapping(uint256 => uint256)) public weeklyStrongestLegVolume;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public weeklyLegVolume;

    uint256[10] public totalSharesPerTier;
    uint256[10] public tierPercentages = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    mapping(uint256 => mapping(uint8 => uint256)) public cycleRPS; 

    uint256[8] public nftTotalSharesPerTier;
    uint256[8] public nftTierPercentages = [0, 1, 2, 3, 4, 5, 15, 35];
    mapping(uint256 => mapping(uint8 => uint256)) public cycleNFTRPS;
    
    struct StakedNFT {
        uint8 tier;
        uint256 startCycle;
    }
    mapping(address => uint256[]) public userStakedTokenIds;
    mapping(uint256 => StakedNFT) public tokenStakingData;

    struct LotteryPool {
        uint256 startTime;
        address[] participants;
        bool isResolved;
    }

    uint256 public currentLotteryId = 1;
    uint256 public lastResolvedLotteryId = 1;
    mapping(uint256 => LotteryPool) public lotteryPools;
    mapping(uint256 => mapping(address => bool)) public poolHasEntered;

    uint256 public constant LOTTERY_ENTRY_FEE = 100 * 1e18; 
    uint256 public constant LOTTERY_MAX_PARTICIPANTS = 100;
    uint256 public constant LOTTERY_MATURITY_TIME = 45 days;

    struct Loan {
        uint256 collateralHMT;
        uint256 loanAmountUSDT;
        uint256 initialCollateralValueUSDT;
        uint256 loanStartTime;
        bool isActive;
    }
    
    mapping(address => Loan) public userLoans;
    address[] public activeLoanUsers;
    mapping(address => uint256) public activeLoanIndex;

    uint256 public currentLiquidationIndex = 0;
    uint256 public constant AUTO_BATCH_SIZE = 5;

    struct TokenStake {
        uint256 amount;
        uint256 startTime;
    }
    mapping(address => TokenStake[]) public userTokenStakes;

    event Invested(address indexed user, uint256 amount, bool isThirtySeventyRatio);
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
    event LoanTaken(address indexed user, uint256 collateralHMT, uint256 loanUSDT);
    event LoanRepaid(address indexed user, uint256 debtPaidUSDT, uint256 collateralReturnedHMT);
    event LoanLiquidated(address indexed user, uint256 collateralSeizedHMT, uint256 defaultedDebtUSDT);
    event HMTSwappedForUSDT(address indexed user, uint256 hmtIn, uint256 usdtOut);
    event TokensStaked(address indexed user, uint256 amount, uint256 stakeIndex);
    event AllTokensUnstaked(address indexed user, uint256 totalPayout, uint256 totalPenalty);

    constructor(
        address _usdt, address _hmt, address _router, address _companyWallet, address _ownerWallet, address _nftContract
    ) Ownable(msg.sender) {
        if (_companyWallet == address(0) || _ownerWallet == address(0)) revert ZeroAddress();
        
        USDT = IERC20(_usdt); HMT = IHMTToken(_hmt); pancakeRouter = IPancakeRouter02(_router);
        companyWallet = _companyWallet; ownerWallet = _ownerWallet; NFT = INFTContract(_nftContract);
        launchTime = block.timestamp;
        
        users[companyWallet].totalInvestment = 10000 * 1e18; 
        users[companyWallet].registrationTime = block.timestamp;
        users[companyWallet].isMatrixUnlocked = true;
        users[companyWallet].lastClaimedCycle = 0;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function _processOwnerPayout() internal {
        if (ownerPayoutsClaimed >= MAX_OWNER_PAYOUTS) return;
        
        uint256 cyclesPassed = (block.timestamp - launchTime) / CYCLE_DURATION;
        
        if (cyclesPassed > ownerPayoutsClaimed) {
            uint256 pendingPayouts = cyclesPassed - ownerPayoutsClaimed;
            
            if (ownerPayoutsClaimed + pendingPayouts > MAX_OWNER_PAYOUTS) {
                pendingPayouts = MAX_OWNER_PAYOUTS - ownerPayoutsClaimed;
            }
            
            if (pendingPayouts > 0) {
                uint256 payoutAmount = pendingPayouts * OWNER_CYCLE_PAYOUT;
                
                if (HMT.balanceOf(address(this)) >= payoutAmount) {
                    ownerPayoutsClaimed += pendingPayouts;
                    HMT.safeTransfer(ownerWallet, payoutAmount);
                    emit OwnerPayoutProcessed(ownerWallet, payoutAmount, ownerPayoutsClaimed);
                }
            }
        }
    }

    // ==========================================
    // 🎲 ISOLATED LOTTERY SYSTEM
    // ==========================================

    function enterLottery() external nonReentrant {
        if (poolHasEntered[currentLotteryId][msg.sender]) revert AlreadyEntered();
        LotteryPool storage currentPool = lotteryPools[currentLotteryId];
        
        USDT.safeTransferFrom(msg.sender, address(this), LOTTERY_ENTRY_FEE);

        if (currentPool.participants.length == 0) {
            currentPool.startTime = block.timestamp;
        }

        poolHasEntered[currentLotteryId][msg.sender] = true;
        currentPool.participants.push(msg.sender);
        
        emit LotteryEntered(msg.sender, currentLotteryId);
        if (currentPool.participants.length == LOTTERY_MAX_PARTICIPANTS) {
            currentLotteryId++;
        }
        _autoResolveLottery();
    }

    function _autoResolveLottery() internal returns (bool) {
        uint256 poolId = lastResolvedLotteryId;
        LotteryPool storage pool = lotteryPools[poolId];
        
        if (pool.isResolved || pool.participants.length < LOTTERY_MAX_PARTICIPANTS || block.timestamp < pool.startTime + LOTTERY_MATURITY_TIME) {
            return false;
        }

        uint256 hmt400 = HMT.getHMTForUSDT(400 * 1e18);
        uint256 hmt200 = HMT.getHMTForUSDT(200 * 1e18);
        uint256 hmt150 = HMT.getHMTForUSDT(150 * 1e18);
        uint256 hmt100 = HMT.getHMTForUSDT(100 * 1e18);

        uint256 totalRequired = (hmt400 * 5) + (hmt200 * 5) + (hmt150 * 40) + (hmt100 * 50);
        if (HMT.balanceOf(address(this)) < totalRequired) {
            return false; 
        }

        pool.isResolved = true;
        address[] memory memParticipants = pool.participants;
        uint256 random = uint256(keccak256(abi.encodePacked(block.timestamp, block.prevrandao, msg.sender, poolId)));

        for (uint256 i = LOTTERY_MAX_PARTICIPANTS - 1; i > 0; i--) {
            random = uint256(keccak256(abi.encodePacked(random))); 
            uint256 j = random % (i + 1);
            
            address temp = memParticipants[i];
            memParticipants[i] = memParticipants[j];
            memParticipants[j] = temp;
        }

        for (uint256 i = 0; i < LOTTERY_MAX_PARTICIPANTS; i++) {
            address winner = memParticipants[i];
            uint256 rewardAmount;

            if (i < 5) rewardAmount = hmt400;             
            else if (i < 10) rewardAmount = hmt200;       
            else if (i < 50) rewardAmount = hmt150;       
            else rewardAmount = hmt100;                   

            HMT.safeTransfer(winner, rewardAmount); 
        }

        lastResolvedLotteryId++;
        emit LotteryResolved(poolId);
        return true;
    }

    function resolveReadyLottery() external nonReentrant {
        if (msg.sender == tx.origin) revert NoSmartContracts();
        if (!_autoResolveLottery()) revert LotteryNotReady();
    }

    function resolveUnclaimedLottery(uint256 _poolId) external nonReentrant {
        LotteryPool storage pool = lotteryPools[_poolId];
        
        if (pool.isResolved) revert PoolResolved();
        if (pool.participants.length == 0) revert PoolEmpty();
        if (pool.participants.length >= LOTTERY_MAX_PARTICIPANTS) revert PoolFull();
        if (block.timestamp < pool.startTime + LOTTERY_MATURITY_TIME) revert NotMature();

        pool.isResolved = true;

        for(uint256 i = 0; i < pool.participants.length; i++) {
            USDT.safeTransfer(pool.participants[i], LOTTERY_ENTRY_FEE);
        }

        if (_poolId == currentLotteryId) {
            currentLotteryId++;
        }
        if (_poolId == lastResolvedLotteryId) {
            lastResolvedLotteryId++;
        }
        
        emit LotteryResolved(_poolId);
    }

    // ==========================================
    // 🏦 HMT COLLATERALIZED LOAN ENGINE
    // ==========================================

    function _removeActiveLoanUser(address _user) internal {
        uint256 index = activeLoanIndex[_user];
        uint256 lastIndex = activeLoanUsers.length - 1;

        if (index != lastIndex) {
            address lastUser = activeLoanUsers[lastIndex];
            activeLoanUsers[index] = lastUser;
            activeLoanIndex[lastUser] = index;
        }

        activeLoanUsers.pop();
        delete activeLoanIndex[_user];
    }

    function getLoanDebt(address _user) public view returns (uint256) {
        Loan memory loan = userLoans[_user];
        if (!loan.isActive) return 0;

        uint256 monthsPassed = (block.timestamp - loan.loanStartTime) / 30 days;
        uint256 interestIntervals = 1 + monthsPassed;
        uint256 interestAmount = (loan.loanAmountUSDT * 10 * interestIntervals) / 100;
        return loan.loanAmountUSDT + interestAmount;
    }

    function isLiquidatable(address _user) public view returns (bool) {
        Loan memory loan = userLoans[_user];
        if (!loan.isActive) return false;

        uint256 currentCollateralValueUSDT = HMT.getUSDTForHMT(loan.collateralHMT);
        uint256 liquidationThreshold = (loan.initialCollateralValueUSDT * 75) / 100;

        return currentCollateralValueUSDT < liquidationThreshold;
    }

    function _autoLiquidateChunk() internal {
        uint256 length = activeLoanUsers.length;
        if (length == 0) return;

        uint256 checks = 0;
        
        while (checks < AUTO_BATCH_SIZE && activeLoanUsers.length > 0) {
            if (currentLiquidationIndex >= activeLoanUsers.length) {
                currentLiquidationIndex = 0;
            }

            address borrower = activeLoanUsers[currentLiquidationIndex];
            if (isLiquidatable(borrower)) {
                Loan storage loan = userLoans[borrower];
                uint256 seizedCollateral = loan.collateralHMT;
                uint256 defaultedDebt = getLoanDebt(borrower);

                delete userLoans[borrower];
                _removeActiveLoanUser(borrower);

                emit LoanLiquidated(borrower, seizedCollateral, defaultedDebt);
            } else {
                currentLiquidationIndex++;
            }
            checks++;
        }
    }

    function takeLoan(uint256 _hmtAmount) external nonReentrant {
        if (_hmtAmount == 0) revert InvalidAmount();
        if (userLoans[msg.sender].isActive) revert LoanActive();

        uint256 collateralValueUSDT = HMT.getUSDTForHMT(_hmtAmount);
        uint256 loanAmountUSDT = (collateralValueUSDT * 50) / 100;
        
        if (USDT.balanceOf(address(this)) < loanAmountUSDT) revert InsufficientLiquidity();

        HMT.safeTransferFrom(msg.sender, address(this), _hmtAmount);
        USDT.safeTransfer(msg.sender, loanAmountUSDT);
        userLoans[msg.sender] = Loan({
            collateralHMT: _hmtAmount,
            loanAmountUSDT: loanAmountUSDT,
            initialCollateralValueUSDT: collateralValueUSDT,
            loanStartTime: block.timestamp,
            isActive: true
        });
        activeLoanIndex[msg.sender] = activeLoanUsers.length;
        activeLoanUsers.push(msg.sender);

        emit LoanTaken(msg.sender, _hmtAmount, loanAmountUSDT);
    }

    function repayLoan() external nonReentrant {
        Loan storage loan = userLoans[msg.sender];
        if (!loan.isActive) revert NoActiveLoan();
        if (isLiquidatable(msg.sender)) revert Liquidatable();

        uint256 totalDebtUSDT = getLoanDebt(msg.sender);
        uint256 collateralToReturn = loan.collateralHMT;
        
        delete userLoans[msg.sender];
        _removeActiveLoanUser(msg.sender); 

        USDT.safeTransferFrom(msg.sender, address(this), totalDebtUSDT);
        HMT.safeTransfer(msg.sender, collateralToReturn);

        emit LoanRepaid(msg.sender, totalDebtUSDT, collateralToReturn);
    }

    function liquidateLoan(address _borrower) public nonReentrant {
        Loan storage loan = userLoans[_borrower];
        if (!loan.isActive) revert NoActiveLoan();
        if (!isLiquidatable(_borrower)) revert HealthyCollateral();

        uint256 seizedCollateral = loan.collateralHMT;
        uint256 defaultedDebt = getLoanDebt(_borrower);
        delete userLoans[_borrower];
        _removeActiveLoanUser(_borrower);

        emit LoanLiquidated(_borrower, seizedCollateral, defaultedDebt);
    }

    function batchLiquidate(uint256 limit) external nonReentrant {
        uint256 length = activeLoanUsers.length;
        uint256 checked = 0;

        for (uint256 i = length; i > 0 && checked < limit; i--) {
            address borrower = activeLoanUsers[i - 1];
            if (isLiquidatable(borrower)) {
                Loan storage loan = userLoans[borrower];
                uint256 seizedCollateral = loan.collateralHMT;
                uint256 defaultedDebt = getLoanDebt(borrower);

                delete userLoans[borrower];
                _removeActiveLoanUser(borrower);

                emit LoanLiquidated(borrower, seizedCollateral, defaultedDebt);
            }
            checked++;
        }
    }

    // ==========================================
    // 🎨 NFT STAKING ENGINE
    // ==========================================

    function stakeNFT(uint256 _tokenId) external nonReentrant {
        if (NFT.ownerOf(_tokenId) != msg.sender) revert NotOwner();
        _internalClaimNFTRewards(msg.sender);

        uint8 tier = NFT.getNFTTier(_tokenId);
        if (tier < 1 || tier > 7) revert InvalidTier();

        NFT.safeTransferFrom(msg.sender, address(this), _tokenId);
        uint256 currentCycle = (block.timestamp - launchTime) / CYCLE_DURATION;
        
        tokenStakingData[_tokenId] = StakedNFT(tier, currentCycle + 1);
        userStakedTokenIds[msg.sender].push(_tokenId);
        nftTotalSharesPerTier[tier]++;

        emit NFTStaked(msg.sender, _tokenId, tier);
    }

    function unstakeNFT(uint256 _tokenId) external nonReentrant {
        bool ownsToken = false;
        uint256 tokenIndex;
        for (uint i = 0; i < userStakedTokenIds[msg.sender].length; i++) {
            if (userStakedTokenIds[msg.sender][i] == _tokenId) {
                ownsToken = true;
                tokenIndex = i;
                break;
            }
        }
        if (!ownsToken) revert NotStaked();
        
        _internalClaimNFTRewards(msg.sender);

        uint8 tier = tokenStakingData[_tokenId].tier;
        nftTotalSharesPerTier[tier]--;

        userStakedTokenIds[msg.sender][tokenIndex] = userStakedTokenIds[msg.sender][userStakedTokenIds[msg.sender].length - 1];
        userStakedTokenIds[msg.sender].pop();
        delete tokenStakingData[_tokenId];

        NFT.safeTransferFrom(address(this), msg.sender, _tokenId);
        emit NFTUnstaked(msg.sender, _tokenId);
    }

    // 🟢 UPDATED: Unlocked 1% daily return to apply to all Tiers
    function getPendingNFTRewards(address _user) public view returns (uint256) {
        uint256 actualCycle = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256 totalPending = 0;

        for (uint i = 0; i < userStakedTokenIds[_user].length; i++) {
            uint256 tokenId = userStakedTokenIds[_user][i];
            StakedNFT memory s = tokenStakingData[tokenId];

            if (actualCycle > s.startCycle) {
                for (uint256 c = s.startCycle; c < actualCycle; c++) {
                    totalPending += (cycleNFTRPS[c][s.tier] / 1e18);
                    // 1% daily return applies to ALL NFTs (Tier 1-7)
                    uint256 nftPrice = NFT.getTierPrice(s.tier);
                    totalPending += (nftPrice * 1) / 100;
                }
            }
        }
        return totalPending;
    }

    function claimNFTRewards() external nonReentrant {
        _internalClaimNFTRewards(msg.sender);
    }

    function _internalClaimNFTRewards(address _user) internal {
        uint256 actualCycle = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256 totalPayout = 0;

        for (uint i = 0; i < userStakedTokenIds[_user].length; i++) {
            uint256 tokenId = userStakedTokenIds[_user][i];
            StakedNFT storage s = tokenStakingData[tokenId];

            if (actualCycle > s.startCycle) {
                for (uint256 c = s.startCycle; c < actualCycle; c++) {
                    totalPayout += (cycleNFTRPS[c][s.tier] / 1e18);
                    // 1% daily return applies to ALL NFTs
                    uint256 nftPrice = NFT.getTierPrice(s.tier);
                    totalPayout += (nftPrice * 1) / 100;
                }
                s.startCycle = actualCycle;
            }
        }

        if (totalPayout > 0) {
            users[_user].matrixRoyaltyVault += totalPayout;
            emit NFTRewardsClaimed(_user, totalPayout);
        }
    }

    // ==========================================
    // 💰 INVEST & BUBBLE-UP
    // ==========================================

    function invest(address _sponsor, uint256 _amount, bool _isThirtySeventy) external nonReentrant {
        if (_amount < MIN_INVESTMENT) revert BelowMinLimit();
        
        InvestmentWindow storage window = userInvestmentWindows[msg.sender];
        if (block.timestamp >= window.windowStartTime + 24 hours) {
            window.windowStartTime = block.timestamp;
            window.totalInvested = 0;
        }
        
        if (window.totalInvested + _amount > MAX_INVESTMENT) revert ExceedsMaxInvest();
        window.totalInvested += _amount;

        if (_sponsor == address(0)) revert ZeroAddress();
        _processOwnerPayout();
        
        _autoLiquidateChunk();
        
        if (users[msg.sender].totalInvestment > 0) {
            _internalClaimROI(msg.sender);
            _internalClaimMatrixRoyalty(msg.sender);
            _internalClaimNFTRewards(msg.sender);
        }

        if (users[msg.sender].sponsor == address(0) && msg.sender != companyWallet) {
            if (users[_sponsor].totalInvestment == 0 && _sponsor != companyWallet) revert InvalidSponsor();
            
            users[msg.sender].sponsor = _sponsor;
            users[msg.sender].registrationTime = block.timestamp;
            users[msg.sender].lastBaseClaimTime = block.timestamp;
            users[msg.sender].lastAirdropClaimTime = block.timestamp;
            users[msg.sender].lastClaimedCycle = (block.timestamp - launchTime) / CYCLE_DURATION;

            users[_sponsor].directReferralsCount++;
            if (users[_sponsor].directReferralsCount == 3) {
                address up1 = users[_sponsor].sponsor;
                if (up1 != address(0)) {
                    users[up1].directsWith3Count++;
                    if (users[up1].directsWith3Count == 3) {
                        address up2 = users[up1].sponsor;
                        if (up2 != address(0)) {
                            users[up2].directsWith9Count++;
                            if (users[up2].directsWith9Count == 3) {
                                if (!users[up2].isMatrixUnlocked) {
                                    users[up2].isMatrixUnlocked = true;
                                    if (block.timestamp > users[up2].registrationTime + 30 days) {
                                        users[up2].isTierZeroLocked = true;
                                    }
                                    
                                    totalSharesPerTier[0]++;
                                    uint256 currentCycle = (block.timestamp - launchTime) / CYCLE_DURATION;
                                    userMatrixData[up2].upgradeCycle[0] = currentCycle + 1; 
                                    emit MatrixUnlocked(up2, users[up2].isTierZeroLocked);
                                }
                            }
                        }
                    }
                }
            
            }
        }

        USDT.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 fee = _amount < 10 * 1e18 ? 1 * 1e18 : (_amount * 10) / 100;
        USDT.safeTransfer(companyWallet, fee);
        emit FeePaid(msg.sender, fee);

        uint256 netAmount = _amount - fee;
        uint256 swapRatio = _isThirtySeventy ? 30 : 70;
        uint256 swapAmount = (netAmount * swapRatio) / 100;
        
        _buyHMT(swapAmount);

        users[msg.sender].totalInvestment += _amount;
        
        if (_amount == MAX_INVESTMENT) { 
            try NFT.mintRewardNFT(msg.sender, 1) {} catch {}
        }

        _updateUplineVolume(msg.sender, _amount);
        _distributeMatrixRoyalty(_amount);

        emit Invested(msg.sender, _amount, _isThirtySeventy);
    }

    function _buyHMT(uint256 usdtAmount) internal {
        USDT.approve(address(pancakeRouter), 0);
        USDT.approve(address(pancakeRouter), usdtAmount);
        uint256 expectedHMT = HMT.getHMTForUSDT(usdtAmount);
        uint256 minOut = (expectedHMT * 75) / 100; 

        address[] memory path = new address[](2);
        path[0] = address(USDT);
        path[1] = address(HMT);

        pancakeRouter.swapExactTokensForTokens(usdtAmount, minOut, path, address(this), block.timestamp + 300);
    }

    function _updateUplineVolume(address _investor, uint256 _amount) internal {
        address currentBranch = _investor;
        address upline = users[currentBranch].sponsor;
        
        uint256 currentCycle = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256 currentWeek = (block.timestamp - launchTime) / 7 days;
        for (uint16 depth = 0; depth < MAX_DEPTH; depth++) {
            if (upline == address(0)) break;
            users[upline].totalTeamVolume += _amount;
            legVolume[upline][currentBranch] += _amount;
            
            if (legVolume[upline][currentBranch] > users[upline].strongestLegVolume) {
                users[upline].strongestLegVolume = legVolume[upline][currentBranch];
                users[upline].strongestLegUser = currentBranch;
            }

            cycleTotalVolume[upline][currentCycle] += _amount;
            cycleLegVolume[upline][currentBranch][currentCycle] += _amount;
            
            if (cycleLegVolume[upline][currentBranch][currentCycle] > cycleStrongestLegVolume[upline][currentCycle]) {
                cycleStrongestLegVolume[upline][currentCycle] = cycleLegVolume[upline][currentBranch][currentCycle];
            }

            weeklyTotalVolume[upline][currentWeek] += _amount;
            weeklyLegVolume[upline][currentBranch][currentWeek] += _amount;

            if (weeklyLegVolume[upline][currentBranch][currentWeek] > weeklyStrongestLegVolume[upline][currentWeek]) {
                weeklyStrongestLegVolume[upline][currentWeek] = weeklyLegVolume[upline][currentBranch][currentWeek];
            }

            currentBranch = upline;
            upline = users[upline].sponsor;
        }
    }

    // ==========================================
    // 📊 PHASE 2: DUAL ROI & LEVEL INCOME
    // ==========================================

    function getPendingROI(address _user) public view returns (uint256 basePending, uint256 airdropPending) {
        if (_user == companyWallet) return (0, 0);
        User memory u = users[_user];
        if (u.totalInvestment == 0) return (0, 0);
        uint256 baseCycles = (block.timestamp - u.lastBaseClaimTime) / 8 hours;
        if (baseCycles > 0) {
            uint256 rewardPerCycle = (u.totalInvestment * 2) / 1000;
            uint256 calculatedBase = rewardPerCycle * baseCycles;
            uint256 baseCap = u.totalInvestment; 
            basePending = (u.baseClaimed + calculatedBase > baseCap) ?
                (baseCap > u.baseClaimed ? baseCap - u.baseClaimed : 0) : calculatedBase;
        }

        if (u.totalInvestment >= 100 * 1e18 && !u.hasWithdrawn) {
            uint256 airdropCycles = (block.timestamp - u.lastAirdropClaimTime) / 1 days;
            if (airdropCycles > 0) {
                uint256 airdropCap = u.totalInvestment * 5;
                uint256 airdropPerDay = (airdropCap * 1) / 1000; 
                uint256 calculatedAirdrop = airdropPerDay * airdropCycles;
                airdropPending = (u.airdropClaimed + calculatedAirdrop > airdropCap) ? 
                    (airdropCap > u.airdropClaimed ? airdropCap - u.airdropClaimed : 0) : calculatedAirdrop;
            }
        }
        return (basePending, airdropPending);
    }

    function claimROI() external nonReentrant {
        _processOwnerPayout();
        _autoLiquidateChunk();

        _internalClaimROI(msg.sender);
        _internalClaimMatrixRoyalty(msg.sender);
        _internalClaimNFTRewards(msg.sender);
    }

    function _internalClaimROI(address _user) internal {
        (uint256 basePending, uint256 airdropPending) = getPendingROI(_user);
        if (basePending == 0 && airdropPending == 0) return;

        User storage u = users[_user];
        if (basePending > 0) {
            uint256 baseCycles = (block.timestamp - u.lastBaseClaimTime) / 8 hours;
            u.lastBaseClaimTime += (baseCycles * 8 hours);
            u.baseClaimed += basePending;
            u.levelIncomeVault += basePending; 
            
            _distributeLevelIncome(_user, basePending);
        }

        if (airdropPending > 0) {
            uint256 airdropCycles = (block.timestamp - u.lastAirdropClaimTime) / 1 days;
            u.lastAirdropClaimTime += (airdropCycles * 1 days);
            u.airdropClaimed += airdropPending;
            
            // Routes to Airdrop Vault
            u.airdropVault += airdropPending; 
        }
        emit ROIClaimed(_user, basePending, airdropPending);
    }

    function _distributeLevelIncome(address _claimer, uint256 _baseROI) internal {
        uint256 minInvestmentRequired = 100 * 1e18;
        address sponsorL1 = users[_claimer].sponsor;
        
        if (sponsorL1 != address(0)) {
            if (users[sponsorL1].directReferralsCount >= 1 && users[sponsorL1].totalInvestment >= minInvestmentRequired) {
                uint256 l1Reward = (_baseROI * 15) / 100;
                users[sponsorL1].levelIncomeVault += l1Reward;
                emit LevelIncomeDistributed(sponsorL1, _claimer, l1Reward, 1);
            }

            address sponsorL2 = users[sponsorL1].sponsor;
            if (sponsorL2 != address(0)) {
                if (users[sponsorL2].directReferralsCount >= 2 && users[sponsorL2].totalInvestment >= minInvestmentRequired) {
                    uint256 l2Reward = (_baseROI * 10) / 100;
                    users[sponsorL2].levelIncomeVault += l2Reward;
                    emit LevelIncomeDistributed(sponsorL2, _claimer, l2Reward, 2);
                }

                address sponsorL3 = users[sponsorL2].sponsor;
                if (sponsorL3 != address(0)) {
                    if (users[sponsorL3].directReferralsCount >= 3 && users[sponsorL3].totalInvestment >= minInvestmentRequired) {
                        uint256 l3Reward = (_baseROI * 5) / 100;
                        users[sponsorL3].levelIncomeVault += l3Reward;
                        emit LevelIncomeDistributed(sponsorL3, _claimer, l3Reward, 3);
                    }
                }
            }
        }
    }

    // ==========================================
    // 👑 PHASE 3: POOL DISTRIBUTIONS
    // ==========================================

    function getLifetimeWeakerLegsVolume(address _user) public view returns (uint256) {
        return users[_user].totalTeamVolume - users[_user].strongestLegVolume;
    }

    function getCycleWeakerLegsVolume(address _user, uint256 cycleId) public view returns (uint256) {
        return cycleTotalVolume[_user][cycleId] - cycleStrongestLegVolume[_user][cycleId];
    }

    function getWeeklyWeakerLegsVolume(address _user, uint256 weekId) public view returns (uint256) {
        return weeklyTotalVolume[_user][weekId] - weeklyStrongestLegVolume[_user][weekId];
    }

    function getMatrixRoyaltyTier(address _user) public view returns (uint8 tier) {
        User memory u = users[_user];
        uint256 weakerVol = getLifetimeWeakerLegsVolume(_user);
        uint256 strongVol = u.strongestLegVolume;

        uint256 qualifyingVol = weakerVol < strongVol ? weakerVol : strongVol;
        if (qualifyingVol >= 18835000 * 1e18 && u.totalInvestment >= 10000 * 1e18 && u.directReferralsCount >= 9) return 9;
        if (qualifyingVol >= 8835000 * 1e18 && u.totalInvestment >= 9000 * 1e18 && u.directReferralsCount >= 8) return 8;
        if (qualifyingVol >= 3835000 * 1e18 && u.totalInvestment >= 7000 * 1e18 && u.directReferralsCount >= 7) return 7;
        if (qualifyingVol >= 1835000 * 1e18 && u.totalInvestment >= 5000 * 1e18 && u.directReferralsCount >= 6) return 6;
        if (qualifyingVol >= 835000 * 1e18 && u.totalInvestment >= 2500 * 1e18 && u.directReferralsCount >= 5) return 5;
        if (qualifyingVol >= 335000 * 1e18 && u.totalInvestment >= 1000 * 1e18 && u.directReferralsCount >= 4) return 4;
        if (qualifyingVol >= 135000 * 1e18 && u.totalInvestment >= 500 * 1e18 && u.directReferralsCount >= 3) return 3;
        if (qualifyingVol >= 35000 * 1e18 && u.totalInvestment >= 250 * 1e18 && u.directReferralsCount >= 2) return 2;
        if (qualifyingVol >= 10000 * 1e18 && u.totalInvestment >= 100 * 1e18 && u.directReferralsCount >= 1) return 1;

        return 0;
    }

    function _distributeMatrixRoyalty(uint256 _investmentAmount) internal {
        uint256 currentCycle = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256 royaltyPool = (_investmentAmount * 18) / 100;
        
        for (uint8 i = 0; i <= 9; i++) {
            if (totalSharesPerTier[i] > 0) {
                uint256 tierCut = (royaltyPool * tierPercentages[i]) / 100;
                cycleRPS[currentCycle][i] += (tierCut * 1e18) / totalSharesPerTier[i];
            }
        }

        for (uint8 i = 1; i <= 7; i++) {
            if (nftTotalSharesPerTier[i] > 0) {
                uint256 tierCut = (royaltyPool * nftTierPercentages[i]) / 100;
                cycleNFTRPS[currentCycle][i] += (tierCut * 1e18) / nftTotalSharesPerTier[i];
            }
        }
    }

    function getPendingMatrixRewards(address _user) public view returns (uint256) {
        User memory u = users[_user];
        if (!u.isMatrixUnlocked) return 0;

        UserMatrix storage um = userMatrixData[_user];
        uint256 actualCycle = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint256 endCycle = actualCycle > u.lastClaimedCycle + MAX_CLAIM_CYCLES ? u.lastClaimedCycle + MAX_CLAIM_CYCLES : actualCycle;

        uint256 totalScaledPayout = 0;
        for (uint256 c = u.lastClaimedCycle; c < endCycle; c++) {
            bool condition3Passed = true;
            uint256 startWeek = c * 4; 
            
            for (uint256 w = startWeek; w < startWeek + 4; w++) {
                if (getWeeklyWeakerLegsVolume(_user, w) < WEEKLY_MAINTENANCE) {
                    condition3Passed = false;
                    break;
                }
            }

            uint256 cycleScaledPayout = 0;
            if (condition3Passed && um.currentMatrixTier > 0) {
                uint8 activeTier = 0;
                for (uint8 i = um.currentMatrixTier; i >= 1; i--) {
                    if (um.upgradeCycle[i] != 0 && c >= um.upgradeCycle[i]) {
                        activeTier = i;
                        break;
                    }
                }
                
                if (activeTier > 0) {
                    cycleScaledPayout = cycleRPS[c][activeTier];
                } else if (c >= um.upgradeCycle[0]) {
                    cycleScaledPayout = cycleRPS[c][0];
                }
            } else {
                if (c >= um.upgradeCycle[0]) {
                    cycleScaledPayout = cycleRPS[c][0];
                }
            }
            totalScaledPayout += cycleScaledPayout;
        }
        return totalScaledPayout / 1e18;
    }

   function _internalClaimMatrixRoyalty(address _user) internal {
        User storage u = users[_user];
        if (!u.isMatrixUnlocked) return;

        uint256 actualCycle = (block.timestamp - launchTime) / CYCLE_DURATION;
        uint8 qualifiedTier = u.isTierZeroLocked ? 0 : getMatrixRoyaltyTier(_user);
        UserMatrix storage um = userMatrixData[_user];

        if (actualCycle <= u.lastClaimedCycle && qualifiedTier <= um.currentMatrixTier) {
            return;
        }

        if (qualifiedTier > um.currentMatrixTier) {
            if (um.currentMatrixTier > 0) {
                if (totalSharesPerTier[um.currentMatrixTier] > 0) {
                    totalSharesPerTier[um.currentMatrixTier]--;
                }
            }
            totalSharesPerTier[qualifiedTier]++;
            for (uint8 i = um.currentMatrixTier + 1; i <= qualifiedTier; i++) {
                um.upgradeCycle[i] = actualCycle + 1;
            }
            um.currentMatrixTier = qualifiedTier;
            emit MatrixTierUpgraded(_user, qualifiedTier, actualCycle + 1);
        }

        uint256 totalScaledPayout = 0;
        uint256 endCycle = actualCycle > u.lastClaimedCycle + MAX_CLAIM_CYCLES ? u.lastClaimedCycle + MAX_CLAIM_CYCLES : actualCycle;
        for (uint256 c = u.lastClaimedCycle; c < endCycle; c++) {
            bool condition3Passed = true;
            uint256 startWeek = c * 4; 
            
            for (uint256 w = startWeek; w < startWeek + 4; w++) {
                if (getWeeklyWeakerLegsVolume(_user, w) < WEEKLY_MAINTENANCE) {
                    condition3Passed = false;
                    break;
                }
            }
            
            uint256 cycleScaledPayout = 0;
            if (condition3Passed && um.currentMatrixTier > 0) {
                uint8 activeTier = 0;
                for (uint8 i = um.currentMatrixTier; i >= 1; i--) {
                    if (um.upgradeCycle[i] != 0 && c >= um.upgradeCycle[i]) {
                        activeTier = i;
                        break;
                    }
                }
                
                if (activeTier > 0) {
                    cycleScaledPayout = cycleRPS[c][activeTier];
                } else if (c >= um.upgradeCycle[0]) {
                    cycleScaledPayout = cycleRPS[c][0];
                }
            } else {
                if (c >= um.upgradeCycle[0]) {
                    cycleScaledPayout = cycleRPS[c][0];
                }
            }
            
            totalScaledPayout += cycleScaledPayout;
            if (cycleScaledPayout > 0) {
                emit MatrixRoyaltyClaimed(_user, cycleScaledPayout / 1e18, c, condition3Passed);
            }
        }

        if (endCycle > u.lastClaimedCycle) {
            u.lastClaimedCycle = endCycle;
        }

        if (totalScaledPayout > 0) {
            uint256 finalPayout = totalScaledPayout / 1e18;
            u.matrixRoyaltyVault += finalPayout;
        }
    }

    // ==========================================
    // 🥩 HMT TOKEN STAKING ENGINE
    // ==========================================
    function stakeHMTTokens(uint256 _amount) external nonReentrant {
        if (_amount == 0) revert InvalidAmount();
        HMT.safeTransferFrom(msg.sender, address(this), _amount);

        userTokenStakes[msg.sender].push(TokenStake({
            amount: _amount,
            startTime: block.timestamp
        }));
        emit TokensStaked(msg.sender, _amount, userTokenStakes[msg.sender].length - 1);
    }

    function _calculateCompoundInterest(uint256 _principal, uint256 _cyclesPassed) internal pure returns (uint256) {
        uint256 amount = _principal;
        for(uint256 i = 0; i < _cyclesPassed; i++) {
            amount = (amount * 1002) / 1000; 
        }
        return amount;
    }

    function getStakingOverview(address _user) public view returns (uint256 totalGrossAmount, uint256 totalPenaltyAmount, uint256 netPayout) {
        TokenStake[] memory stakes = userTokenStakes[_user];
        for (uint256 i = 0; i < stakes.length; i++) {
            uint256 timeStaked = block.timestamp - stakes[i].startTime;
            
            uint256 cyclesPassed = timeStaked / 8 hours;
            uint256 daysPassed = timeStaked / 1 days;

            uint256 grossAmount = _calculateCompoundInterest(stakes[i].amount, cyclesPassed);
            totalGrossAmount += grossAmount;

            uint256 penaltyPercent = 0;
            if (daysPassed < 30) {
                penaltyPercent = 15;
            } else if (daysPassed < 60) {
                penaltyPercent = 10;
            } else if (daysPassed < 90) {
                penaltyPercent = 5;
            } else if (daysPassed < 120) {
                penaltyPercent = 3;
            } else if (daysPassed < 150) {
                penaltyPercent = 2;
            } else if (daysPassed < 180) {
                penaltyPercent = 1;
            } else {
                penaltyPercent = 0;
            }

            totalPenaltyAmount += (grossAmount * penaltyPercent) / 100;
        }

        netPayout = totalGrossAmount - totalPenaltyAmount;
        return (totalGrossAmount, totalPenaltyAmount, netPayout);
    }

    function unstakeAllHMT() external nonReentrant {
        if (userTokenStakes[msg.sender].length == 0) revert NoStakes();

        (, uint256 totalPenalty, uint256 finalNetPayout) = getStakingOverview(msg.sender);

        if (HMT.balanceOf(address(this)) < finalNetPayout) revert InsufficientLiquidity();

        delete userTokenStakes[msg.sender];

        HMT.safeTransfer(msg.sender, finalNetPayout);

        emit AllTokensUnstaked(msg.sender, finalNetPayout, totalPenalty);
    }

    // ==========================================
    // 💸 WITHDRAWAL ENGINE & FRONTEND VIEWS
    // ==========================================

    function getTotalWithdrawable(address _user) external view returns (uint256 regularTotal, uint256 airdropTotal) {
        User memory u = users[_user];
        uint256 vaultedRegular = u.levelIncomeVault + u.matrixRoyaltyVault;
        uint256 vaultedAirdrop = u.airdropVault;
        
        uint256 basePending = 0;
        uint256 airdropPending = 0;
        if (_user != companyWallet && u.totalInvestment > 0) {
            (basePending, airdropPending) = getPendingROI(_user);
        }
        
        uint256 matrixPending = 0;
        if (u.isMatrixUnlocked) matrixPending = getPendingMatrixRewards(_user); 
        
        uint256 nftPending = getPendingNFTRewards(_user);
        
        regularTotal = vaultedRegular + basePending + matrixPending + nftPending;
        airdropTotal = vaultedAirdrop + airdropPending;
    }

    // 🟢 UPDATED: Strictly limits withdrawal to 10% of TOTAL INVESTMENT (Max $1000)
    function getDailyWithdrawLimit(address _user) public view returns (uint256 maxDaily, uint256 remainingToday) {
        uint256 userInvested = users[_user].totalInvestment;
        uint256 calculatedLimit = (userInvested * 10) / 100;
        
        // Hard Cap at 1000 USDT (scaled to 1e18)
        uint256 hardCap = 1000 * 1e18;
        maxDaily = calculatedLimit > hardCap ? hardCap : calculatedLimit;

        WithdrawWindow memory window = userWithdrawWindows[_user];
        
        if (block.timestamp < window.windowStartTime + 24 hours) {
            maxDaily = window.maxDailyLimit; // Respect the 24h snapshot limit
            remainingToday = maxDaily > window.withdrawnAmount ? maxDaily - window.withdrawnAmount : 0;
        } 
        else {
            remainingToday = maxDaily;
        }
    }

    function withdraw(uint256 _amount, bool _isAirdropWithdrawal) external nonReentrant {
        _processOwnerPayout();
        _autoLiquidateChunk();

        _internalClaimROI(msg.sender);
        _internalClaimMatrixRoyalty(msg.sender);
        _internalClaimNFTRewards(msg.sender);
        
        User storage u = users[msg.sender];
        
        uint256 specificVaultAvailable;
        if (_isAirdropWithdrawal) {
            specificVaultAvailable = u.airdropVault;
        } else {
            specificVaultAvailable = u.levelIncomeVault + u.matrixRoyaltyVault;
        }
        
        if (_amount == 0 || specificVaultAvailable < _amount) revert InsufficientVault();

        // 🟢 UPDATED: 10% Total Investment Rule applies to the active withdraw snapshot
        uint256 userInvested = u.totalInvestment;
        uint256 calculatedLimit = (userInvested * 10) / 100;
        uint256 hardCap = 1000 * 1e18;
        uint256 dailyCap = calculatedLimit > hardCap ? hardCap : calculatedLimit;

        WithdrawWindow storage window = userWithdrawWindows[msg.sender];
        
        if (block.timestamp >= window.windowStartTime + 24 hours) {
            window.windowStartTime = block.timestamp;
            window.withdrawnAmount = 0;
            window.maxDailyLimit = dailyCap; 
        }
        
        if (window.withdrawnAmount + _amount > window.maxDailyLimit) revert ExceedsDailyLimit();
        
        window.withdrawnAmount += _amount;

        if (_isAirdropWithdrawal) {
            if (!u.hasWithdrawn) {
                u.hasWithdrawn = true;
                emit AirdropForfeited(msg.sender);
            }
            u.airdropVault -= _amount;
        } else {
            if (_amount <= u.levelIncomeVault) {
                u.levelIncomeVault -= _amount;
            } else {
                uint256 remainder = _amount - u.levelIncomeVault;
                u.levelIncomeVault = 0;
                u.matrixRoyaltyVault -= remainder;
            }
        }

        uint256 fee = (_amount * 5) / 100;
        uint256 netPayoutUSDT = _amount - fee;
        USDT.safeTransfer(ownerWallet, fee);

        uint256 currentHMTPriceInUSDT = HMT.getUSDTForHMT(1e18);
        uint256 targetPrice = 5 * 1e18;
        bool paidInHMT = false;

        if (!isPayoutLockedToHMT && currentHMTPriceInUSDT >= targetPrice) {
            isPayoutLockedToHMT = true;
        }

        if (!isPayoutLockedToHMT) {
            USDT.safeTransfer(msg.sender, netPayoutUSDT);
        } else {
            uint256 hmtToPayout = HMT.getHMTForUSDT(netPayoutUSDT);
            if (HMT.balanceOf(address(this)) < hmtToPayout) revert InsufficientLiquidity();
            HMT.safeTransfer(msg.sender, hmtToPayout);
            paidInHMT = true;
        }

        emit Withdrawn(msg.sender, _amount, paidInHMT);
    }
    
    // ==========================================
    // 💱 OTC SWAP ENGINE (HMT -> USDT)
    // ==========================================

    function swapHMTForUSDT(uint256 _hmtAmount) external nonReentrant {
        if (_hmtAmount == 0) revert InvalidAmount();
        uint256 usdtPayout = HMT.getUSDTForHMT(_hmtAmount);
        if (USDT.balanceOf(address(this)) < usdtPayout) revert InsufficientLiquidity();
        
        HMT.safeTransferFrom(msg.sender, address(this), _hmtAmount);
        USDT.safeTransfer(msg.sender, usdtPayout);
        
        emit HMTSwappedForUSDT(msg.sender, _hmtAmount, usdtPayout);
    }
}