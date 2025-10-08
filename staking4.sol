// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract CozyStakingComplete {
    // Info of each user
    struct UserInfo {
        uint256 amount;           // How many LP tokens the user has provided
        uint256 rewardDebt;       // Reward debt for COZY
        uint256 pendingRewards;   // Pending COZY rewards
        uint256 lastDepositTime;  // Last deposit timestamp
        uint256 lockUntil;        // Lock period end timestamp
        uint256 boostMultiplier;  // Individual boost multiplier
    }

    // Info of each pool
    struct PoolInfo {
        address lpToken;           // Address of LP token contract
        uint256 allocPoint;       // How many allocation points assigned to this pool
        uint256 lastRewardBlock;  // Last block number that COZY distribution occurs
        uint256 accRewardPerShare; // Accumulated COZY per share, times 1e12
        uint256 totalStaked;      // Total LP tokens staked in pool
        bool allowsLock;          // Whether pool allows locking
        uint256 minLockPeriod;    // Minimum lock period in seconds
        uint256 maxLockPeriod;    // Maximum lock period in seconds
        uint256 depositFee;       // Deposit fee in basis points (100 = 1%)
        bool isActive;           // Whether pool is active
    }

    // Lock period options with multipliers
    struct LockOption {
        uint256 period;          // Lock period in seconds
        uint256 multiplier;      // Reward multiplier (100 = 1x)
        bool enabled;           // Whether this option is enabled
    }

    // Vesting system
    struct VestingInfo {
        uint256 totalAmount;
        uint256 claimedAmount;
        uint256 startTime;
        uint256 vestingPeriod;
        uint256 cliffPeriod;     // Cliff period before vesting starts
    }

    // The COZY TOKEN
    address public immutable cozyToken;

    // COZY tokens created per block
    uint256 public rewardPerBlock;

    // Info of each pool
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools
    uint256 public totalAllocPoint = 0;

    // The block number when COZY mining starts
    uint256 public startBlock;

    // The block number when COZY mining ends
    uint256 public endBlock;

    // Address which can update rewardPerBlock
    address public owner;

    // Treasury address for fees
    address public treasury;

    // === ADVANCED FEATURES ===

    // Time lock features
    mapping(uint256 => LockOption[]) public lockOptions;

    // Boosted rewards system
    mapping(address => uint256) public cozyStakedForBoost;
    mapping(address => uint256) public userBoostMultiplier; // ✅ FIXED: Added missing mapping
    uint256 public constant MAX_BOOST_MULTIPLIER = 300; // 3x max boost
    uint256 public constant BASE_MULTIPLIER = 100;
    uint256 public boostRate = 1; // 0.1% boost per 100 COZY

    // Vesting system
    mapping(address => VestingInfo) public vestingInfo;
    uint256 public vestingPeriod = 30 days;
    uint256 public cliffPeriod = 7 days;

    // Governance features
    mapping(address => address) public voteDelegation;
    mapping(address => uint256) public delegatedVotingPower;

    // Reward halving
    uint256 public rewardHalvingPeriod = 100000; // blocks
    uint256 public lastHalvingBlock;
    uint256 public halvingCount = 0;
    uint256 public constant MAX_HALVING_COUNT = 4;

    // Statistics
    uint256 public totalUsers;
    uint256 public totalRewardsDistributed;
    mapping(address => bool) public hasStaked;

    // Events
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, uint256 lockPeriod, uint256 fee);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event ClaimRewards(address indexed user, uint256 indexed pid, uint256 amount);
    event PoolAdded(uint256 indexed pid, address lpToken, uint256 allocPoint);
    event PoolUpdated(uint256 indexed pid, uint256 allocPoint);
    event RewardPerBlockUpdated(uint256 oldReward, uint256 newReward);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event BoostEntered(address indexed user, uint256 amount, uint256 multiplier);
    event BoostExited(address indexed user, uint256 amount);
    event VestedRewardsClaimed(address indexed user, uint256 amount);
    event LockOptionsUpdated(uint256 indexed pid);
    event VoteDelegated(address indexed from, address indexed to);
    event RewardHalving(uint256 newRewardPerBlock, uint256 halvingCount);
    event RewardEmissionStopped(uint256 stoppedAtBlock);
    event RewardEmissionExtended(uint256 newEndBlock);
    event TokensRecovered(address indexed token, uint256 amount);
    event RewardsCompounded(address indexed user, uint256 amount);
    event PoolStatusChanged(uint256 indexed pid, bool isActive);
    event TreasuryUpdated(address indexed newTreasury);
    event DepositFeeUpdated(uint256 indexed pid, uint256 newFee);

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "CozyStaking: NOT_OWNER");
        _;
    }

    modifier validatePool(uint256 _pid) {
        require(_pid < poolInfo.length, "CozyStaking: POOL_NOT_EXIST");
        require(poolInfo[_pid].isActive, "CozyStaking: POOL_INACTIVE");
        _;
    }

    modifier notLocked(uint256 _pid, address _user) {
        require(userInfo[_pid][_user].lockUntil <= block.timestamp, "CozyStaking: STILL_LOCKED");
        _;
    }

    modifier poolExists(uint256 _pid) {
        require(_pid < poolInfo.length, "CozyStaking: POOL_NOT_EXIST");
        _;
    }

    constructor(
        address _cozyToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _endBlock,
        address _treasury
    ) {
        require(_cozyToken != address(0), "CozyStaking: ZERO_ADDRESS");
        require(_rewardPerBlock > 0, "CozyStaking: INVALID_REWARD");
        require(_startBlock >= block.number, "CozyStaking: INVALID_START");
        require(_endBlock > _startBlock, "CozyStaking: INVALID_END");
        require(_treasury != address(0), "CozyStaking: INVALID_TREASURY");

        cozyToken = _cozyToken;
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
        endBlock = _endBlock;
        owner = msg.sender;
        treasury = _treasury;
        lastHalvingBlock = _startBlock;
    }

    // === POOL MANAGEMENT ===

    function addPool(
        address _lpToken,
        uint256 _allocPoint,
        bool _withUpdate,
        bool _allowsLock,
        uint256 _minLockPeriod,
        uint256 _maxLockPeriod,
        uint256 _depositFee
    ) external onlyOwner {
        require(_lpToken != address(0), "CozyStaking: ZERO_ADDRESS");
        require(_allocPoint > 0, "CozyStaking: INVALID_ALLOC");
        require(_depositFee <= 1000, "CozyStaking: FEE_TOO_HIGH"); // Max 10%

        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint += _allocPoint;

        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accRewardPerShare: 0,
            totalStaked: 0,
            allowsLock: _allowsLock,
            minLockPeriod: _minLockPeriod,
            maxLockPeriod: _maxLockPeriod,
            depositFee: _depositFee,
            isActive: true
        }));

        // Add default lock options
        uint256 pid = poolInfo.length - 1;
        if (_allowsLock) {
            lockOptions[pid].push(LockOption(30 days, 120, true));   // 1 month - 1.2x
            lockOptions[pid].push(LockOption(90 days, 150, true));   // 3 months - 1.5x
            lockOptions[pid].push(LockOption(180 days, 200, true));  // 6 months - 2.0x
            lockOptions[pid].push(LockOption(365 days, 300, true));  // 1 year - 3.0x
        }

        emit PoolAdded(pid, _lpToken, _allocPoint);
    }

    function setPoolAllocation(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) external onlyOwner poolExists(_pid) {
        require(_allocPoint > 0, "CozyStaking: INVALID_ALLOC");

        if (_withUpdate) {
            massUpdatePools();
        }

        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;

        emit PoolUpdated(_pid, _allocPoint);
    }

    function setPoolDepositFee(
        uint256 _pid,
        uint256 _depositFee
    ) external onlyOwner poolExists(_pid) {
        require(_depositFee <= 1000, "CozyStaking: FEE_TOO_HIGH");
        poolInfo[_pid].depositFee = _depositFee;
        
        emit DepositFeeUpdated(_pid, _depositFee);
    }

    function setPoolStatus(
        uint256 _pid,
        bool _isActive
    ) external onlyOwner poolExists(_pid) {
        poolInfo[_pid].isActive = _isActive;
        emit PoolStatusChanged(_pid, _isActive);
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            if (poolInfo[pid].isActive) {
                updatePool(pid);
            }
        }
    }

    // === LOCK OPTIONS MANAGEMENT ===

    function setLockOptions(
        uint256 _pid,
        LockOption[] calldata _options
    ) external onlyOwner poolExists(_pid) {
        require(poolInfo[_pid].allowsLock, "CozyStaking: LOCK_NOT_ALLOWED");

        delete lockOptions[_pid];
        for (uint256 i = 0; i < _options.length; i++) {
            lockOptions[_pid].push(_options[i]);
        }

        emit LockOptionsUpdated(_pid);
    }

    function getLockOptions(uint256 _pid) external view poolExists(_pid) returns (LockOption[] memory) {
        return lockOptions[_pid];
    }

    function getLockMultiplier(uint256 _pid, uint256 _lockPeriod) public view returns (uint256) {
        if (!poolInfo[_pid].allowsLock || _lockPeriod == 0) {
            return BASE_MULTIPLIER;
        }

        LockOption[] memory options = lockOptions[_pid];
        for (uint256 i = 0; i < options.length; i++) {
            if (options[i].period == _lockPeriod && options[i].enabled) {
                return options[i].multiplier;
            }
        }
        return BASE_MULTIPLIER;
    }

    // === STAKING FUNCTIONS ===

    function deposit(
        uint256 _pid, 
        uint256 _amount, 
        uint256 _lockPeriod
    ) external validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(_amount > 0, "CozyStaking: INVALID_AMOUNT");

        // Validate lock period
        if (_lockPeriod > 0) {
            require(pool.allowsLock, "CozyStaking: LOCK_NOT_ALLOWED");
            require(_lockPeriod >= pool.minLockPeriod, "CozyStaking: LOCK_TOO_SHORT");
            require(_lockPeriod <= pool.maxLockPeriod, "CozyStaking: LOCK_TOO_LONG");
            require(getLockMultiplier(_pid, _lockPeriod) > BASE_MULTIPLIER, "CozyStaking: INVALID_LOCK_PERIOD");
        }

        updatePool(_pid);

        // Handle pending rewards
        if (user.amount > 0) {
            uint256 pending = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
            if (pending > 0) {
                user.pendingRewards += pending;
            }
        }

        // Calculate deposit fee
        uint256 fee = 0;
        if (pool.depositFee > 0) {
            fee = (_amount * pool.depositFee) / 10000;
        }
        uint256 amountAfterFee = _amount - fee;

        // Transfer LP tokens
        safeTransferFrom(pool.lpToken, msg.sender, address(this), _amount);
        
        // Transfer fee to treasury
        if (fee > 0) {
            safeTransfer(pool.lpToken, treasury, fee);
        }

        // Update user info
        if (!hasStaked[msg.sender]) {
            hasStaked[msg.sender] = true;
            totalUsers++;
        }

        user.amount += amountAfterFee;
        pool.totalStaked += amountAfterFee;

        // Set lock period and multiplier
        if (_lockPeriod > 0) {
            user.lockUntil = block.timestamp + _lockPeriod;
            user.boostMultiplier = getLockMultiplier(_pid, _lockPeriod);
        } else {
            user.boostMultiplier = BASE_MULTIPLIER;
        }
        user.lastDepositTime = block.timestamp;

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
        emit Deposit(msg.sender, _pid, amountAfterFee, _lockPeriod, fee);
    }

    function withdraw(uint256 _pid, uint256 _amount) external validatePool(_pid) notLocked(_pid, msg.sender) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "CozyStaking: INSUFFICIENT_BALANCE");

        updatePool(_pid);

        uint256 pending = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        if (pending > 0) {
            user.pendingRewards += pending;
        }

        if (_amount > 0) {
            user.amount -= _amount;
            pool.totalStaked -= _amount;
            safeTransfer(pool.lpToken, msg.sender, _amount);
        }

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function earlyWithdraw(uint256 _pid, uint256 _amount) external validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "CozyStaking: INSUFFICIENT_BALANCE");
        require(user.lockUntil > block.timestamp, "CozyStaking: NOT_LOCKED");

        // Calculate penalty (50% of rewards)
        updatePool(_pid);
        uint256 pending = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        uint256 penalty = pending / 2;

        if (_amount > 0) {
            user.amount -= _amount;
            pool.totalStaked -= _amount;
            safeTransfer(pool.lpToken, msg.sender, _amount);
        }

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
        user.pendingRewards += (pending - penalty); // Only get half the rewards

        emit Withdraw(msg.sender, _pid, _amount);
    }

    function emergencyWithdraw(uint256 _pid) external poolExists(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount > 0, "CozyStaking: NO_STAKE");

        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.pendingRewards = 0;
        user.lockUntil = 0;
        user.boostMultiplier = BASE_MULTIPLIER;

        pool.totalStaked -= amount;
        safeTransfer(pool.lpToken, msg.sender, amount);

        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function claimRewards(uint256 _pid) external validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        uint256 pending = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        if (pending > 0) {
            user.pendingRewards += pending;
        }

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;

        uint256 totalPending = user.pendingRewards;
        if (totalPending > 0) {
            user.pendingRewards = 0;
            
            // Apply boost multiplier
            uint256 effectiveMultiplier = _calculateEffectiveMultiplier(_pid, msg.sender);
            uint256 boostedRewards = (totalPending * effectiveMultiplier) / BASE_MULTIPLIER;
            
            totalRewardsDistributed += boostedRewards;
            safeCozyTransfer(msg.sender, boostedRewards);
            emit ClaimRewards(msg.sender, _pid, boostedRewards);
        }
    }

    // === BATCH OPERATIONS ===

    function claimMultipleRewards(uint256[] calldata _pids) external {
        for (uint256 i = 0; i < _pids.length; i++) {
            if (_pids[i] < poolInfo.length && poolInfo[_pids[i]].isActive) {
                _claimRewardsInternal(_pids[i]); // ✅ FIXED: Changed to internal function
            }
        }
    }

    // ✅ FIXED: Added internal claim function
    function _claimRewardsInternal(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        uint256 pending = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        if (pending > 0) {
            user.pendingRewards += pending;
        }

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;

        uint256 totalPending = user.pendingRewards;
        if (totalPending > 0) {
            user.pendingRewards = 0;
            
            // Apply boost multiplier
            uint256 effectiveMultiplier = _calculateEffectiveMultiplier(_pid, msg.sender);
            uint256 boostedRewards = (totalPending * effectiveMultiplier) / BASE_MULTIPLIER;
            
            totalRewardsDistributed += boostedRewards;
            safeCozyTransfer(msg.sender, boostedRewards);
            emit ClaimRewards(msg.sender, _pid, boostedRewards);
        }
    }

    function compoundRewards(uint256 _pid) external validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        updatePool(_pid);

        uint256 pending = (user.amount * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        if (pending > 0) {
            user.pendingRewards += pending;
        }

        uint256 totalPending = user.pendingRewards;
        if (totalPending > 0) {
            user.pendingRewards = 0;
            
            // Apply boost multiplier
            uint256 effectiveMultiplier = _calculateEffectiveMultiplier(_pid, msg.sender);
            uint256 boostedRewards = (totalPending * effectiveMultiplier) / BASE_MULTIPLIER;
            
            // Use rewards for boosting instead of transferring
            cozyStakedForBoost[msg.sender] += boostedRewards;
            
            // Update boost multiplier
            _updateBoostMultiplier(msg.sender);
            
            totalRewardsDistributed += boostedRewards;
            emit RewardsCompounded(msg.sender, boostedRewards);
            emit ClaimRewards(msg.sender, _pid, boostedRewards);
        }
        
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
    }

    // === BOOSTED REWARDS ===

    function enterBoosting(uint256 _cozyAmount) external {
        require(_cozyAmount > 0, "CozyStaking: INVALID_AMOUNT");

        safeTransferFrom(cozyToken, msg.sender, address(this), _cozyAmount);
        cozyStakedForBoost[msg.sender] += _cozyAmount;

        _updateBoostMultiplier(msg.sender);

        // ✅ FIXED: Use the correct mapping name
        emit BoostEntered(msg.sender, _cozyAmount, userBoostMultiplier[msg.sender]);
    }

    function exitBoosting() external {
        uint256 amount = cozyStakedForBoost[msg.sender];
        require(amount > 0, "CozyStaking: NO_BOOST");

        cozyStakedForBoost[msg.sender] = 0;
        userBoostMultiplier[msg.sender] = BASE_MULTIPLIER; // ✅ FIXED: Reset the boost multiplier
        
        // Reset boost multiplier for all pools
        for (uint256 i = 0; i < poolInfo.length; i++) {
            if (userInfo[i][msg.sender].boostMultiplier > BASE_MULTIPLIER) {
                // Keep lock boost but remove COZY boost
                userInfo[i][msg.sender].boostMultiplier = BASE_MULTIPLIER;
            }
        }

        safeTransfer(cozyToken, msg.sender, amount);
        emit BoostExited(msg.sender, amount);
    }

    function _updateBoostMultiplier(address _user) internal {
        uint256 additionalBoost = (cozyStakedForBoost[_user] * boostRate) / (100 * 1e18); // 100 COZY = 0.1% boost
        uint256 newBoost = BASE_MULTIPLIER + additionalBoost;
        if (newBoost > MAX_BOOST_MULTIPLIER) newBoost = MAX_BOOST_MULTIPLIER;

        // ✅ FIXED: Store in the correct mapping
        userBoostMultiplier[_user] = newBoost;

        // Update boost multiplier for all active positions
        for (uint256 i = 0; i < poolInfo.length; i++) {
            if (userInfo[i][_user].amount > 0) {
                // Combine lock boost and COZY boost
                uint256 lockBoost = userInfo[i][_user].boostMultiplier;
                uint256 totalBoost = (lockBoost * newBoost) / BASE_MULTIPLIER;
                if (totalBoost > MAX_BOOST_MULTIPLIER) totalBoost = MAX_BOOST_MULTIPLIER;
                userInfo[i][_user].boostMultiplier = totalBoost;
            }
        }
    }

    function setBoostRate(uint256 _boostRate) external onlyOwner {
        require(_boostRate > 0, "CozyStaking: INVALID_BOOST_RATE");
        boostRate = _boostRate;
    }

    // === VESTING SYSTEM ===

    function setVestingPeriod(uint256 _vestingPeriod, uint256 _cliffPeriod) external onlyOwner {
        require(_vestingPeriod > 0, "CozyStaking: INVALID_VESTING");
        require(_cliffPeriod <= _vestingPeriod, "CozyStaking: INVALID_CLIFF");
        vestingPeriod = _vestingPeriod;
        cliffPeriod = _cliffPeriod;
    }

    function claimVestedRewards() external {
        VestingInfo storage vest = vestingInfo[msg.sender];
        require(vest.totalAmount > 0, "CozyStaking: NO_VESTING");

        uint256 claimable = getClaimableVestedAmount(msg.sender);
        require(claimable > 0, "CozyStaking: NOTHING_CLAIMABLE");

        vest.claimedAmount += claimable;
        safeCozyTransfer(msg.sender, claimable);

        emit VestedRewardsClaimed(msg.sender, claimable);
    }

    function getClaimableVestedAmount(address _user) public view returns (uint256) {
        VestingInfo storage vest = vestingInfo[_user];
        if (vest.totalAmount == 0) return 0;
        
        // Check cliff period
        if (block.timestamp < vest.startTime + vest.cliffPeriod) {
            return 0;
        }

        uint256 elapsed = block.timestamp - vest.startTime;
        if (elapsed >= vest.vestingPeriod) {
            return vest.totalAmount - vest.claimedAmount;
        }

        uint256 totalClaimable = (vest.totalAmount * elapsed) / vest.vestingPeriod;
        if (totalClaimable <= vest.claimedAmount) return 0;
        return totalClaimable - vest.claimedAmount;
    }

    function setupVesting(
        address _user,
        uint256 _totalAmount,
        uint256 _vestingPeriod,
        uint256 _cliffPeriod
    ) external onlyOwner {
        require(_user != address(0), "CozyStaking: ZERO_ADDRESS");
        require(_totalAmount > 0, "CozyStaking: INVALID_AMOUNT");
        require(_vestingPeriod > 0, "CozyStaking: INVALID_VESTING_PERIOD");
        require(_cliffPeriod <= _vestingPeriod, "CozyStaking: INVALID_CLIFF");

        vestingInfo[_user] = VestingInfo({
            totalAmount: _totalAmount,
            claimedAmount: 0,
            startTime: block.timestamp,
            vestingPeriod: _vestingPeriod,
            cliffPeriod: _cliffPeriod
        });
    }

    // === GOVERNANCE FEATURES ===

    function delegateVotingPower(address _to) external {
        require(_to != address(0), "CozyStaking: ZERO_ADDRESS");
        require(_to != msg.sender, "CozyStaking: SELF_DELEGATION");

        // Remove previous delegation
        address currentDelegate = voteDelegation[msg.sender];
        if (currentDelegate != address(0)) {
            delegatedVotingPower[currentDelegate] -= getVotingPower(msg.sender);
        }

        voteDelegation[msg.sender] = _to;
        delegatedVotingPower[_to] += getVotingPower(msg.sender);

        emit VoteDelegated(msg.sender, _to);
    }

    function undelegateVotingPower() external {
        address currentDelegate = voteDelegation[msg.sender];
        require(currentDelegate != address(0), "CozyStaking: NOT_DELEGATED");

        uint256 power = getVotingPower(msg.sender);
        delegatedVotingPower[currentDelegate] -= power;
        voteDelegation[msg.sender] = address(0);

        emit VoteDelegated(msg.sender, address(0));
    }

    function getVotingPower(address _user) public view returns (uint256 power) {
        // Count LP tokens across all pools
        for (uint256 i = 0; i < poolInfo.length; i++) {
            power += userInfo[i][_user].amount;
        }
        // Count COZY tokens staked for boost
        power += cozyStakedForBoost[_user];
        return power;
    }

    function getTotalVotingPower(address _user) external view returns (uint256) {
        uint256 ownPower = getVotingPower(_user);
        uint256 delegatedPower = delegatedVotingPower[_user];
        return ownPower + delegatedPower;
    }

    // === REWARD HALVING ===

    function setRewardHalvingPeriod(uint256 _halvingPeriod) external onlyOwner {
        rewardHalvingPeriod = _halvingPeriod;
    }

    function checkAndApplyHalving() public {
        if (block.number >= lastHalvingBlock + rewardHalvingPeriod && halvingCount < MAX_HALVING_COUNT) {
            rewardPerBlock = rewardPerBlock / 2;
            lastHalvingBlock = block.number;
            halvingCount++;

            emit RewardHalving(rewardPerBlock, halvingCount);
        }
    }

    // === REWARD MANAGEMENT ===

    function setRewardPerBlock(uint256 _rewardPerBlock, bool _withUpdate) external onlyOwner {
        require(_rewardPerBlock > 0, "CozyStaking: INVALID_REWARD");

        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 oldReward = rewardPerBlock;
        rewardPerBlock = _rewardPerBlock;

        emit RewardPerBlockUpdated(oldReward, _rewardPerBlock);
    }

    function stopRewardEmission() external onlyOwner {
        require(endBlock > block.number, "CozyStaking: ALREADY_ENDED");
        endBlock = block.number;
        emit RewardEmissionStopped(block.number);
    }

    function extendRewardEmission(uint256 _newEndBlock) external onlyOwner {
        require(_newEndBlock > block.number, "CozyStaking: INVALID_END_BLOCK");
        require(_newEndBlock > endBlock, "CozyStaking: MUST_EXTEND");
        endBlock = _newEndBlock;
        emit RewardEmissionExtended(_newEndBlock);
    }

    // === EMERGENCY FUNCTIONS ===

    function recoverERC20(address _token, uint256 _amount) external onlyOwner {
        require(_token != cozyToken, "CozyStaking: CANNOT_RECOVER_COZY");
        
        // Check if token is one of the LP tokens in pools
        for (uint256 i = 0; i < poolInfo.length; i++) {
            require(_token != poolInfo[i].lpToken, "CozyStaking: CANNOT_RECOVER_STAKED_TOKEN");
        }
        
        IERC20(_token).transfer(msg.sender, _amount);
        emit TokensRecovered(_token, _amount);
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "CozyStaking: ZERO_ADDRESS");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    // === VIEW FUNCTIONS ===

    function pendingRewards(uint256 _pid, address _user) 
        public 
        view 
        validatePool(_pid) 
        returns (uint256) 
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 lpSupply = pool.totalStaked;

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getRewardMultiplier(pool.lastRewardBlock, block.number);
            uint256 reward = (multiplier * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
            accRewardPerShare += (reward * 1e12) / lpSupply;
        }

        uint256 baseRewards = user.pendingRewards + ((user.amount * accRewardPerShare) / 1e12 - user.rewardDebt);

        // Apply effective multiplier
        uint256 effectiveMultiplier = _calculateEffectiveMultiplier(_pid, _user);
        return (baseRewards * effectiveMultiplier) / BASE_MULTIPLIER;
    }

    function getRewardMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= startBlock || _from >= endBlock) {
            return 0;
        }

        uint256 from = _from < startBlock ? startBlock : _from;
        uint256 to = _to > endBlock ? endBlock : _to;

        if (from > to) return 0;
        return to - from;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function getPoolStats(uint256 _pid) external view poolExists(_pid) returns (
        uint256 totalStakers,
        uint256 apyEstimate,
        uint256 utilizationRate
    ) {
        PoolInfo storage pool = poolInfo[_pid];
        
        // Simplified APY calculation
        if (pool.totalStaked > 0 && rewardPerBlock > 0) {
            uint256 annualRewards = rewardPerBlock * 2336000; // ~blocks per year
            uint256 poolAnnualRewards = (annualRewards * pool.allocPoint) / totalAllocPoint;
            apyEstimate = (poolAnnualRewards * 1e18) / pool.totalStaked;
        }

        return (0, apyEstimate, 0);
    }

    function getUserInfo(address _user) external view returns (
        uint256 totalStaked,
        uint256 totalPendingRewards,
        uint256 totalVotingPower,
        uint256 currentBoost
    ) {
        for (uint256 i = 0; i < poolInfo.length; i++) {
            if (poolInfo[i].isActive) {
                UserInfo storage user = userInfo[i][_user];
                totalStaked += user.amount;
                totalPendingRewards += pendingRewards(i, _user);
            }
        }
        
        totalVotingPower = getVotingPower(_user);
        currentBoost = userBoostMultiplier[_user]; // ✅ FIXED: Use correct mapping
    }

    function hasLockedPositions(address _user) external view returns (bool) {
        for (uint256 i = 0; i < poolInfo.length; i++) {
            if (userInfo[i][_user].lockUntil > block.timestamp) {
                return true;
            }
        }
        return false;
    }

    function getTotalTVL() external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < poolInfo.length; i++) {
            if (poolInfo[i].isActive) {
                total += poolInfo[i].totalStaked;
            }
        }
        return total;
    }

    // === INTERNAL FUNCTIONS ===

    function updatePool(uint256 _pid) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];

        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        uint256 lpSupply = pool.totalStaked;
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = getRewardMultiplier(pool.lastRewardBlock, block.number);
        if (multiplier == 0) return;

        uint256 reward = (multiplier * rewardPerBlock * pool.allocPoint) / totalAllocPoint;

        pool.accRewardPerShare += (reward * 1e12) / lpSupply;
        pool.lastRewardBlock = block.number;

        // Check for reward halving
        checkAndApplyHalving();
    }

    function _calculateEffectiveMultiplier(uint256 _pid, address _user) internal view returns (uint256) {
        UserInfo storage user = userInfo[_pid][_user];
        return user.boostMultiplier;
    }

    function safeCozyTransfer(address _to, uint256 _amount) internal {
        uint256 cozyBal = IERC20(cozyToken).balanceOf(address(this));
        if (_amount > cozyBal) {
            IERC20(cozyToken).transfer(_to, cozyBal);
        } else {
            IERC20(cozyToken).transfer(_to, _amount);
        }
    }

    function safeTransfer(address _token, address _to, uint256 _amount) internal {
        IERC20(_token).transfer(_to, _amount);
    }

    function safeTransferFrom(address _token, address _from, address _to, uint256 _amount) internal {
        IERC20(_token).transferFrom(_from, _to, _amount);
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "CozyStaking: ZERO_ADDRESS");
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }
}

// Minimal ERC20 Interface
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}