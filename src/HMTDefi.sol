// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 { 
    function transfer(address,uint256) external returns(bool); 
    function transferFrom(address,address,uint256) external returns(bool); 
    function balanceOf(address) external view returns(uint256); 
    function approve(address,uint256) external returns(bool); 
}
interface IHMTToken is IERC20 { 
    function getUSDTForHMT(uint256) external view returns(uint256); 
}

error InvalidAmount(); error InsufficientLiquidity(); error NoActiveLoan();
error Liquidatable(); error HealthyCollateral(); error NoStakes(); error AlreadyEntered();

contract HMTDeFi {
    IERC20 public USDT;
    IHMTToken public HMT;

    uint256 public constant CYCLE_DURATION = 28 days;
    uint256 public constant AUTO_BATCH_SIZE = 5;

    uint256 private _status = 1;
    modifier nonReentrant() { if (_status == 2) revert AlreadyEntered(); _status = 2; _; _status = 1; }

    // ── Loans ──
    struct Loan { uint256 collateralHMT; uint256 loanAmountUSDT; uint256 initialCollateralValueUSDT; uint256 loanStartTime; bool isActive; }
    mapping(address => Loan) public userLoans;
    address[] public activeLoanUsers;
    mapping(address => uint256) public activeLoanIndex;
    uint256 public currentLiquidationIndex;

    // ── Staking ──
    struct TokenStake { uint256 amount; uint256 startTime; }
    mapping(address => TokenStake[]) public userTokenStakes;

    // ── Events ──
    event TokensStaked(address indexed user, uint256 amount, uint256 stakeIndex);
    event AllTokensUnstaked(address indexed user, uint256 totalPayout, uint256 totalPenalty);
    event LoanTaken(address indexed user, uint256 collateralHMT, uint256 loanUSDT);
    event LoanRepaid(address indexed user, uint256 debtPaidUSDT, uint256 collateralReturnedHMT);
    event LoanLiquidated(address indexed user, uint256 collateralSeizedHMT, uint256 defaultedDebtUSDT);

    constructor(address _usdt, address _hmt) {
        USDT = IERC20(_usdt);
        HMT = IHMTToken(_hmt);
    }

    // ==========================================
    // 🥩 HMT TOKEN STAKING
    // ==========================================
    function stakeHMTTokens(uint256 _amt) external nonReentrant {
        if (_amt == 0) revert InvalidAmount();
        _autoLiquidateChunk(); // Crank liquidations
        HMT.transferFrom(msg.sender, address(this), _amt);
        userTokenStakes[msg.sender].push(TokenStake({ amount: _amt, startTime: block.timestamp }));
        emit TokensStaked(msg.sender, _amt, userTokenStakes[msg.sender].length - 1);
    }

    function getStakingOverview(address _user) public view returns (uint256 tG, uint256 tP, uint256 nP) {
        TokenStake[] memory stks = userTokenStakes[_user];
        uint8[6] memory pens = [20, 15, 10, 8, 7, 6]; 
        for (uint256 i; i < stks.length; i++) {
            uint256 elapsed = block.timestamp - stks[i].startTime;
            uint256 amt = stks[i].amount;
            uint256 periods = elapsed / 8 hours;
            for(uint256 j = 0; j < periods; j++) amt = (amt * 1002) / 1000; 
            tG += amt;
            uint256 cyc = elapsed / CYCLE_DURATION;
            tP += (amt * (cyc < 6 ? pens[cyc] : 0)) / 100;
        }
        return (tG, tP, tG - tP);
    }

    function unstakeAllHMT() external nonReentrant {
        if (userTokenStakes[msg.sender].length == 0) revert NoStakes();
        _autoLiquidateChunk(); // Crank liquidations
        (,, uint256 n) = getStakingOverview(msg.sender);
        if (HMT.balanceOf(address(this)) < n) revert InsufficientLiquidity();
        delete userTokenStakes[msg.sender];
        HMT.transfer(msg.sender, n);
        emit AllTokensUnstaked(msg.sender, n, 0); // Penalty tracked in overview
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
        return ln.loanAmountUSDT + ((ln.initialCollateralValueUSDT * 10 * (1 + ((block.timestamp - ln.loanStartTime) / CYCLE_DURATION))) / 100);
    }

    function isLiquidatable(address _u) public view returns (bool) {
        Loan memory ln = userLoans[_u];
        if (!ln.isActive) return false;
        if (block.timestamp >= ln.loanStartTime + (3 * CYCLE_DURATION)) return true;
        return HMT.getUSDTForHMT(ln.collateralHMT) < (ln.initialCollateralValueUSDT * 75) / 100;
    }

    function _autoLiquidateChunk() internal {
        uint256 len = activeLoanUsers.length;
        if (len == 0) return;
        uint256 checks = 0;
        while (checks < AUTO_BATCH_SIZE && activeLoanUsers.length > 0) {
            if (currentLiquidationIndex >= activeLoanUsers.length) currentLiquidationIndex = 0;
            address b = activeLoanUsers[currentLiquidationIndex];
            if (isLiquidatable(b)) {
                uint256 col = userLoans[b].collateralHMT;
                uint256 dbt = getLoanDebt(b);
                delete userLoans[b]; _removeActiveLoanUser(b);
                emit LoanLiquidated(b, col, dbt);
            } else { currentLiquidationIndex++; }
            checks++;
        }
    }

    // Allows bots or owners to manually push the liquidation queue
    function crankLiquidations() external nonReentrant { _autoLiquidateChunk(); }

    function takeLoan(uint256 _hAmt) external nonReentrant {
        if (_hAmt == 0 || userLoans[msg.sender].isActive) revert InvalidAmount();
        _autoLiquidateChunk();
        
        uint256 cVal = HMT.getUSDTForHMT(_hAmt);
        uint256 lAmt = (cVal * 50) / 100;
        
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
        if (!ln.isActive) revert NoActiveLoan();
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
        Loan storage ln = userLoans[_b];
        if (!ln.isActive) revert NoActiveLoan();
        if (!isLiquidatable(_b)) revert HealthyCollateral();

        uint256 col = ln.collateralHMT;
        uint256 dbt = getLoanDebt(_b);
        delete userLoans[_b];
        _removeActiveLoanUser(_b);
        emit LoanLiquidated(_b, col, dbt);
    }

    function batchLiquidate(uint256 limit) external nonReentrant {
        uint256 chk = 0;
        for (uint256 i = activeLoanUsers.length; i > 0 && chk < limit; i--) {
            address b = activeLoanUsers[i - 1];
            if (isLiquidatable(b)) {
                uint256 col = userLoans[b].collateralHMT;
                uint256 dbt = getLoanDebt(b);
                delete userLoans[b];
                _removeActiveLoanUser(b);
                emit LoanLiquidated(b, col, dbt);
            }
            chk++;
        }
    }
}