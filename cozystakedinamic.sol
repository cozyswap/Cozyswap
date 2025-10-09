// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract CozyStakingDynamic {
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint128 amount;
        uint128 accumulatedRewards;
        uint32 lastStakeTime;
        uint32 lockUntil;
        uint16 boostMultiplier;
        uint32 rewardStartTime;
    }

    struct PoolInfo {
        address lpToken;
        uint96 allocPoint;
        uint128 totalStaked;
        bool allowsLock;
        uint32 minLockPeriod;
        uint32 maxLockPeriod;
        uint16 depositFee;
        bool isActive;
    }

    struct LockOption {
        uint32 period;
        uint16 multiplier;
        bool enabled;
    }

    // Hardcoded addresses
    address public constant cozyToken = 0x06e2ef46662834f4e42dbf9ff9222b077c57df5c;
    address public constant treasury = 0x876E77168cfa68e3bCC994B5F8425E18d9903dF4;
    address public owner;

    // Constants
    uint16 public constant MAX_BOOST_MULTIPLIER = 300;
    uint16 public constant BASE_MULTIPLIER = 100;
    uint16 public constant MAX_DEPOSIT_FEE = 1000;
    
    // Dynamic Reward Parameters
    uint128 public constant INITIAL_REWARD_RATE = 57870370370370; // 0.05 COZY per second initial
    uint128 public constant REWARD_SUPPLY = 36_000_000 * 1e18; // 30% of 120M
    uint128 public constant HALVING_PERIOD = 30 days;
    uint128 public constant TVL_TARGET_1 = 1_000_000 * 1e18; // 1M COZY TVL
    uint128 public constant TVL_TARGET_2 = 5_000_000 * 1e18; // 5M COZY TVL
    uint128 public constant TVL_TARGET_3 = 10_000_000 * 1e18; // 10M COZY TVL

    // State Variables
    uint128 public totalRewardsDistributed;
    uint128 public currentRewardRate;
    uint32 public lastHalvingTime;
    uint32 public launchTime;
    uint32 public halvingCount;

    // Arrays and mappings
    PoolInfo[] public poolInfo;
    mapping(uint256 => LockOption[]) public lockOptions;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(address => uint128) public cozyStakedForBoost;
    mapping(address => uint16) public userBoostMultiplier;
    mapping(address => bool) public hasStaked;

    // Statistics
    uint32 public totalUsers;

    // Events
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, uint256 lockPeriod, uint256 fee);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event ClaimRewards(address indexed user, uint256 indexed pid, uint256 amount);
    event PoolAdded(uint256 indexed pid, address lpToken, uint256 allocPoint);
    event PoolUpdated(uint256 indexed pid, uint256 allocPoint);
    event RewardRateUpdated(uint128 newRate, uint128 totalDistributed);
    event HalvingApplied(uint128 newRate, uint32 halvingCount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event BoostEntered(address indexed user, uint256 amount, uint256 multiplier);
    event BoostExited(address indexed user, uint256 amount);

    // Error messages
    error NotOwner();
    error PoolNotExist();
    error PoolInactive();
    error StillLocked();
    error ZeroAddress();
    error InvalidAmount();
    error InvalidAlloc();
    error InsufficientBalance();
    error FeeTooHigh();
    error LockNotAllowed();
    error LockTooShort();
    error LockTooLong();
    error InvalidLockPeriod();
    error NoStake();
    error NoBoost();
    error InsufficientRewardSupply();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier validatePool(uint256 _pid) {
        if (_pid >= poolInfo.length) revert PoolNotExist();
        if (!poolInfo[_pid].isActive) revert PoolInactive();
        _;
    }

    modifier notLocked(uint256 _pid, address _user) {
        if (userInfo[_pid][_user].lockUntil > block.timestamp) revert StillLocked();
        _;
    }

    constructor() {
        owner = msg.sender;
        launchTime = uint32(block.timestamp);
        lastHalvingTime = uint32(block.timestamp);
        currentRewardRate = INITIAL_REWARD_RATE;
    }

    // === CORE FUNCTIONS ===
    function deposit(uint256 _pid, uint256 _amount, uint256 _lockPeriod) external validatePool(_pid) {
        if (_amount == 0) revert InvalidAmount();

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        _validateLockPeriod(_pid, _lockPeriod);
        
        // Update rewards and apply dynamic adjustments
        _updateRewardRate();
        
        // Calculate pending rewards before updating stake
        if (user.amount > 0) {
            uint256 pending = _calculatePendingRewards(_pid, msg.sender);
            if (pending > 0) {
                user.accumulatedRewards += uint128(pending);
            }
        }

        (uint256 amountAfterFee, uint256 fee) = _calculateDepositFee(pool, _amount);

        IERC20(pool.lpToken).safeTransferFrom(msg.sender, address(this), _amount);
        if (fee > 0) IERC20(pool.lpToken).safeTransfer(treasury, fee);

        // Update user stake
        _updateUserStake(_pid, msg.sender, amountAfterFee, _lockPeriod);
        pool.totalStaked += uint128(amountAfterFee);

        emit Deposit(msg.sender, _pid, amountAfterFee, _lockPeriod, fee);
    }

    function withdraw(uint256 _pid, uint256 _amount) external validatePool(_pid) notLocked(_pid, msg.sender) {
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (uint256(user.amount) < _amount) revert InsufficientBalance();

        PoolInfo storage pool = poolInfo[_pid];
        
        // Update rewards before withdrawal
        _updateRewardRate();
        
        // Calculate and accumulate rewards before withdrawal
        uint256 pending = _calculatePendingRewards(_pid, msg.sender);
        if (pending > 0) {
            user.accumulatedRewards += uint128(pending);
        }

        if (_amount > 0) {
            user.amount -= uint128(_amount);
            pool.totalStaked -= uint128(_amount);
            IERC20(pool.lpToken).safeTransfer(msg.sender, _amount);
            
            // Reset reward timing if fully withdrawn
            if (user.amount == 0) {
                user.rewardStartTime = 0;
            }
        }

        emit Withdraw(msg.sender, _pid, _amount);
    }

    function claimRewards(uint256 _pid) external validatePool(_pid) {
        _updateRewardRate();
        
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 pending = _calculatePendingRewards(_pid, msg.sender);
        
        if (pending > 0 || user.accumulatedRewards > 0) {
            uint256 totalRewards = pending + user.accumulatedRewards;
            
            // Check reward supply
            if (totalRewardsDistributed + totalRewards > REWARD_SUPPLY) {
                totalRewards = REWARD_SUPPLY - totalRewardsDistributed;
            }
            
            if (totalRewards > 0) {
                user.accumulatedRewards = 0;
                user.rewardStartTime = uint32(block.timestamp); // Reset reward timer
                
                totalRewardsDistributed += uint128(totalRewards);
                _safeCozyTransfer(msg.sender, totalRewards);
                emit ClaimRewards(msg.sender, _pid, totalRewards);
            }
        }
    }

    function emergencyWithdraw(uint256 _pid) external {
        if (_pid >= poolInfo.length) revert PoolNotExist();
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        
        if (user.amount == 0) revert NoStake();

        uint256 amount = user.amount;
        
        // Reset all user data
        user.amount = 0;
        user.accumulatedRewards = 0;
        user.lockUntil = 0;
        user.boostMultiplier = BASE_MULTIPLIER;
        user.rewardStartTime = 0;

        pool.totalStaked -= uint128(amount);
        IERC20(pool.lpToken).safeTransfer(msg.sender, amount);

        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // === DYNAMIC REWARD SYSTEM ===
    function _updateRewardRate() internal {
        // Apply halving based on time
        _applyHalving();
        
        // Adjust based on TVL
        _adjustRewardByTVL();
        
        // Check if reward supply is running low
        _checkRewardSupply();
    }

    function _applyHalving() internal {
        if (block.timestamp >= lastHalvingTime + HALVING_PERIOD) {
            currentRewardRate = currentRewardRate / 2;
            lastHalvingTime = uint32(block.timestamp);
            halvingCount++;
            emit HalvingApplied(currentRewardRate, halvingCount);
        }
    }

    function _adjustRewardByTVL() internal {
        uint256 totalTVL = getTotalTVL();
        
        // Reduce rewards as TVL increases (inverse relationship)
        if (totalTVL >= TVL_TARGET_3) {
            currentRewardRate = INITIAL_REWARD_RATE / 8; // 87.5% reduction
        } else if (totalTVL >= TVL_TARGET_2) {
            currentRewardRate = INITIAL_REWARD_RATE / 4; // 75% reduction
        } else if (totalTVL >= TVL_TARGET_1) {
            currentRewardRate = INITIAL_REWARD_RATE / 2; // 50% reduction
        }
    }

    function _checkRewardSupply() internal {
        uint256 remainingRewards = REWARD_SUPPLY - totalRewardsDistributed;
        
        // If less than 10% supply remains, reduce rewards drastically
        if (remainingRewards < REWARD_SUPPLY / 10) {
            currentRewardRate = currentRewardRate / 4;
        }
        
        // If less than 1% supply remains, stop rewards
        if (remainingRewards < REWARD_SUPPLY / 100) {
            currentRewardRate = 0;
        }
    }

    function _calculatePendingRewards(uint256 _pid, address _user) internal view returns (uint256) {
        UserInfo storage user = userInfo[_pid][_user];
        
        if (user.amount == 0 || user.rewardStartTime == 0 || currentRewardRate == 0) {
            return 0;
        }

        uint256 timeStaked = block.timestamp - user.rewardStartTime;
        uint256 baseRewards = (timeStaked * currentRewardRate * user.amount) / 1e18;
        
        // Apply boost multiplier
        uint256 boostedRewards = (baseRewards * user.boostMultiplier) / BASE_MULTIPLIER;
        
        // Cap at remaining reward supply
        uint256 remaining = REWARD_SUPPLY - totalRewardsDistributed;
        return boostedRewards > remaining ? remaining : boostedRewards;
    }

    // === BOOSTED REWARDS ===
    function enterBoosting(uint256 _cozyAmount) external {
        if (_cozyAmount == 0) revert InvalidAmount();

        IERC20(cozyToken).safeTransferFrom(msg.sender, address(this), _cozyAmount);
        cozyStakedForBoost[msg.sender] += uint128(_cozyAmount);
        _updateBoostMultiplier(msg.sender);

        emit BoostEntered(msg.sender, _cozyAmount, userBoostMultiplier[msg.sender]);
    }

    function exitBoosting() external {
        uint256 amount = cozyStakedForBoost[msg.sender];
        if (amount == 0) revert NoBoost();

        cozyStakedForBoost[msg.sender] = 0;
        userBoostMultiplier[msg.sender] = BASE_MULTIPLIER;
        
        for (uint256 i = 0; i < poolInfo.length; i++) {
            if (userInfo[i][msg.sender].amount > 0) {
                userInfo[i][msg.sender].boostMultiplier = BASE_MULTIPLIER;
            }
        }

        IERC20(cozyToken).safeTransfer(msg.sender, amount);
        emit BoostExited(msg.sender, amount);
    }

    function _updateBoostMultiplier(address _user) internal {
        uint256 additionalBoost = (uint256(cozyStakedForBoost[_user]) * 1) / (100 * 1e18);
        uint256 newBoost = BASE_MULTIPLIER + additionalBoost;
        if (newBoost > MAX_BOOST_MULTIPLIER) newBoost = MAX_BOOST_MULTIPLIER;

        userBoostMultiplier[_user] = uint16(newBoost);

        for (uint256 i = 0; i < poolInfo.length; i++) {
            if (userInfo[i][_user].amount > 0) {
                uint256 lockBoost = userInfo[i][_user].boostMultiplier;
                uint256 totalBoost = (lockBoost * newBoost) / BASE_MULTIPLIER;
                if (totalBoost > MAX_BOOST_MULTIPLIER) totalBoost = MAX_BOOST_MULTIPLIER;
                userInfo[i][_user].boostMultiplier = uint16(totalBoost);
            }
        }
    }

    // === POOL MANAGEMENT ===
    function addPool(
        address _lpToken,
        uint256 _allocPoint,
        bool _allowsLock,
        uint256 _minLockPeriod,
        uint256 _maxLockPeriod,
        uint256 _depositFee
    ) external onlyOwner {
        if (_lpToken == address(0)) revert ZeroAddress();
        if (_allocPoint == 0) revert InvalidAlloc();
        if (_depositFee > MAX_DEPOSIT_FEE) revert FeeTooHigh();

        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: uint96(_allocPoint),
            totalStaked: 0,
            allowsLock: _allowsLock,
            minLockPeriod: uint32(_minLockPeriod),
            maxLockPeriod: uint32(_maxLockPeriod),
            depositFee: uint16(_depositFee),
            isActive: true
        }));

        uint256 pid = poolInfo.length - 1;
        if (_allowsLock) {
            _addDefaultLockOptions(pid);
        }

        emit PoolAdded(pid, _lpToken, _allocPoint);
    }

    function setPoolAllocation(uint256 _pid, uint256 _allocPoint) external onlyOwner {
        if (_allocPoint == 0) revert InvalidAlloc();
        if (_pid >= poolInfo.length) revert PoolNotExist();

        poolInfo[_pid].allocPoint = uint96(_allocPoint);
        emit PoolUpdated(_pid, _allocPoint);
    }

    function setPoolDepositFee(uint256 _pid, uint256 _depositFee) external onlyOwner {
        if (_pid >= poolInfo.length) revert PoolNotExist();
        if (_depositFee > MAX_DEPOSIT_FEE) revert FeeTooHigh();
        poolInfo[_pid].depositFee = uint16(_depositFee);
    }

    function setPoolStatus(uint256 _pid, bool _isActive) external onlyOwner {
        if (_pid >= poolInfo.length) revert PoolNotExist();
        poolInfo[_pid].isActive = _isActive;
    }

    function earlyWithdraw(uint256 _pid, uint256 _amount) external validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (uint256(user.amount) < _amount) revert InsufficientBalance();
        if (user.lockUntil <= block.timestamp) revert StillLocked();

        _updateRewardRate();

        // Calculate rewards with penalty
        uint256 pending = _calculatePendingRewards(_pid, msg.sender);
        uint256 penalty = pending / 2;

        if (_amount > 0) {
            user.amount -= uint128(_amount);
            pool.totalStaked -= uint128(_amount);
            IERC20(pool.lpToken).safeTransfer(msg.sender, _amount);
        }

        user.accumulatedRewards += uint128(pending - penalty);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // === VIEW FUNCTIONS ===
    function pendingRewards(uint256 _pid, address _user) public view validatePool(_pid) returns (uint256) {
        UserInfo storage user = userInfo[_pid][_user];
        uint256 pending = _calculatePendingRewards(_pid, _user);
        return pending + user.accumulatedRewards;
    }

    function getRewardInfo() public view returns (
        uint128 currentRate,
        uint128 totalDistributed,
        uint128 remainingSupply,
        uint32 nextHalving,
        uint256 currentTVL,
        uint32 currentHalvingCount
    ) {
        return (
            currentRewardRate,
            totalRewardsDistributed,
            uint128(REWARD_SUPPLY - totalRewardsDistributed),
            lastHalvingTime + HALVING_PERIOD,
            getTotalTVL(),
            halvingCount
        );
    }

    function getTotalTVL() public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < poolInfo.length; i++) {
            if (poolInfo[i].isActive) {
                total += poolInfo[i].totalStaked;
            }
        }
        return total;
    }

    function getLockMultiplier(uint256 _pid, uint256 _lockPeriod) public view returns (uint256) {
        if (!poolInfo[_pid].allowsLock || _lockPeriod == 0) return BASE_MULTIPLIER;

        LockOption[] memory options = lockOptions[_pid];
        for (uint256 i = 0; i < options.length; i++) {
            if (options[i].period == _lockPeriod && options[i].enabled) return options[i].multiplier;
        }
        return BASE_MULTIPLIER;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function getUserStake(uint256 _pid, address _user) external view returns (
        uint256 amount, 
        uint256 lockUntil, 
        uint256 boostMultiplier,
        uint256 pending
    ) {
        UserInfo memory user = userInfo[_pid][_user];
        pending = pendingRewards(_pid, _user);
        return (user.amount, user.lockUntil, user.boostMultiplier, pending);
    }

    // === INTERNAL FUNCTIONS ===
    function _validateLockPeriod(uint256 _pid, uint256 _lockPeriod) internal view {
        if (_lockPeriod > 0) {
            PoolInfo storage pool = poolInfo[_pid];
            if (!pool.allowsLock) revert LockNotAllowed();
            if (_lockPeriod < pool.minLockPeriod) revert LockTooShort();
            if (_lockPeriod > pool.maxLockPeriod) revert LockTooLong();
            if (getLockMultiplier(_pid, _lockPeriod) <= BASE_MULTIPLIER) revert InvalidLockPeriod();
        }
    }

    function _calculateDepositFee(PoolInfo storage pool, uint256 _amount) internal view returns (uint256, uint256) {
        if (pool.depositFee == 0) return (_amount, 0);
        uint256 fee = (_amount * pool.depositFee) / 10000;
        return (_amount - fee, fee);
    }

    function _updateUserStake(uint256 _pid, address _user, uint256 _amount, uint256 _lockPeriod) internal {
        UserInfo storage user = userInfo[_pid][_user];
        
        // Set reward timing
        if (user.rewardStartTime == 0) {
            user.rewardStartTime = uint32(block.timestamp);
        }

        user.amount += uint128(_amount);

        if (_lockPeriod > 0) {
            user.lockUntil = uint32(block.timestamp + _lockPeriod);
            user.boostMultiplier = uint16(getLockMultiplier(_pid, _lockPeriod));
        } else {
            user.boostMultiplier = BASE_MULTIPLIER;
        }
        user.lastStakeTime = uint32(block.timestamp);

        if (!hasStaked[_user]) {
            hasStaked[_user] = true;
            totalUsers++;
        }
    }

    function _safeCozyTransfer(address _to, uint256 _amount) internal {
        uint256 cozyBal = IERC20(cozyToken).balanceOf(address(this));
        uint256 transferAmount = _amount > cozyBal ? cozyBal : _amount;
        if (transferAmount > 0) IERC20(cozyToken).safeTransfer(_to, transferAmount);
    }

    function _addDefaultLockOptions(uint256 _pid) internal {
        lockOptions[_pid].push(LockOption(uint32(30 days), 120, true));
        lockOptions[_pid].push(LockOption(uint32(90 days), 150, true)); 
        lockOptions[_pid].push(LockOption(uint32(180 days), 200, true));
        lockOptions[_pid].push(LockOption(uint32(365 days), 300, true));
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }
}

// Library
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: TRANSFER_FAILED");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: TRANSFER_FROM_FAILED");
    }

    function balanceOf(IERC20 token, address account) internal view returns (uint256) {
        (bool success, bytes memory data) = address(token).staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, account));
        require(success, "SafeERC20: BALANCE_FAILED");
        return abi.decode(data, (uint256));
    }
}

interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}