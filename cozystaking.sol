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
    }

    // Lock period options with multipliers
    struct LockOption {
        uint256 period;          // Lock period in seconds
        uint256 multiplier;      // Reward multiplier (100 = 1x)
        bool enabled;           // Whether this option is enabled
    }

    // Additional reward token info
    struct RewardTokenInfo {
        uint256 rewardPerBlock;  // Reward tokens per block
        uint256 accRewardPerShare; // Accumulated rewards per share
        uint256 lastRewardBlock; // Last reward distribution block
        uint256 totalAllocPoint; // Total allocation for this token
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

    // === ADVANCED FEATURES ===
    
    // Time lock features
    mapping(uint256 => LockOption[]) public lockOptions;
    mapping(uint256 => mapping(uint256 => uint256)) public lockMultipliers; // pool -> period -> multiplier
    
    // Boosted rewards system
    mapping(address => uint256) public cozyStakedForBoost;
    mapping(address => uint256) public boostMultiplier;
    uint256 public constant MAX_BOOST_MULTIPLIER = 300; // 3x max boost
    uint256 public constant BASE_MULTIPLIER = 100;
    uint256 public constant BOOST_DIVISOR = 1000e18; // 1000 COZY for 1% boost
    
    // Vesting system
    struct VestingInfo {
        uint256 totalAmount;
        uint256 claimedAmount;
        uint256 startTime;
        uint256 vestingPeriod;
    }
    mapping(address => VestingInfo) public vestingInfo;
    uint256 public vestingPeriod = 30 days;
    
    // Multi-reward tokens system
    address[] public rewardTokens;
    mapping(address => RewardTokenInfo) public rewardTokenInfo;
    mapping(address => bool) public isRewardToken;
    mapping(uint256 => mapping(address => mapping(address => uint256))) public userRewardDebt; // pid -> user -> rewardToken -> debt
    mapping(uint256 => mapping(address => mapping(address => uint256))) public userPendingRewards; // pid -> user -> rewardToken -> pending
    
    // Governance features
    mapping(address => address) public voteDelegation;
    mapping(address => uint256) public delegatedVotingPower;
    
    // Reward halving
    uint256 public rewardHalvingPeriod = 100000; // blocks
    uint256 public lastHalvingBlock;
    uint256 public halvingCount = 0;

    // Events
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, uint256 lockPeriod);
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
    event RewardTokenAdded(address indexed token, uint256 rewardPerBlock);
    event LockOptionsUpdated(uint256 indexed pid);
    event VoteDelegated(address indexed from, address indexed to);
    event RewardHalving(uint256 newRewardPerBlock, uint256 halvingCount);

    // Modifiers
    modifier onlyOwner() {
        require(msg.sender == owner, "CozyStaking: NOT_OWNER");
        _;
    }

    modifier validatePool(uint256 _pid) {
        require(_pid < poolInfo.length, "CozyStaking: POOL_NOT_EXIST");
        _;
    }

    modifier notLocked(uint256 _pid, address _user) {
        require(userInfo[_pid][_user].lockUntil <= block.timestamp, "CozyStaking: STILL_LOCKED");
        _;
    }

    constructor(
        address _cozyToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _endBlock
    ) {
        require(_cozyToken != address(0), "CozyStaking: ZERO_ADDRESS");
        require(_rewardPerBlock > 0, "CozyStaking: INVALID_REWARD");
        require(_startBlock >= block.number, "CozyStaking: INVALID_START");
        require(_endBlock > _startBlock, "CozyStaking: INVALID_END");

        cozyToken = _cozyToken;
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
        endBlock = _endBlock;
        owner = msg.sender;
        lastHalvingBlock = _startBlock;
    }

    // === POOL MANAGEMENT ===

    function addPool(
        address _lpToken,
        uint256 _allocPoint,
        bool _withUpdate,
        bool _allowsLock,
        uint256 _minLockPeriod,
        uint256 _maxLockPeriod
    ) external onlyOwner {
        require(_lpToken != address(0), "CozyStaking: ZERO_ADDRESS");
        require(_allocPoint > 0, "CozyStaking: INVALID_ALLOC");

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
            maxLockPeriod: _maxLockPeriod
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
    ) external onlyOwner validatePool(_pid) {
        require(_allocPoint > 0, "CozyStaking: INVALID_ALLOC");

        if (_withUpdate) {
            massUpdatePools();
        }

        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;

        emit PoolUpdated(_pid, _allocPoint);
    }

    // === LOCK OPTIONS MANAGEMENT ===

    function setLockOptions(
        uint256 _pid,
        LockOption[] calldata _options
    ) external onlyOwner validatePool(_pid) {
        require(poolInfo[_pid].allowsLock, "CozyStaking: LOCK_NOT_ALLOWED");
        
        delete lockOptions[_pid];
        for (uint256 i = 0; i < _options.length; i++) {
            lockOptions[_pid].push(_options[i]);
        }
        
        emit LockOptionsUpdated(_pid);
    }

    function getLockOptions(uint256 _pid) external view validatePool(_pid) returns (LockOption[] memory) {
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

        // Transfer LP tokens
        safeTransferFrom(pool.lpToken, msg.sender, address(this), _amount);
        user.amount += _amount;
        pool.totalStaked += _amount;
        
        // Set lock period
        if (_lockPeriod > 0) {
            user.lockUntil = block.timestamp + _lockPeriod;
        }
        user.lastDepositTime = block.timestamp;

        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e12;
        emit Deposit(msg.sender, _pid, _amount, _lockPeriod);
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

    // Early withdraw with penalty
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

    // === BOOSTED REWARDS ===

    function enterBoosting(uint256 _cozyAmount) external {
        require(_cozyAmount > 0, "CozyStaking: INVALID_AMOUNT");
        
        safeTransferFrom(cozyToken, msg.sender, address(this), _cozyAmount);
        cozyStakedForBoost[msg.sender] += _cozyAmount;
        
        // Calculate boost multiplier (0.1% boost per 100 COZY staked, max 3x)
        uint256 additionalBoost = (_cozyAmount * 1) / (100 * 1e18); // 100 COZY = 0.1% boost
        uint256 newBoost = BASE_MULTIPLIER + additionalBoost;
        if (newBoost > MAX_BOOST_MULTIPLIER) newBoost = MAX_BOOST_MULTIPLIER;
        
        boostMultiplier[msg.sender] = newBoost;
        
        emit BoostEntered(msg.sender, _cozyAmount, newBoost);
    }

    function exitBoosting() external {
        uint256 amount = cozyStakedForBoost[msg.sender];
        require(amount > 0, "CozyStaking: NO_BOOST");
        
        cozyStakedForBoost[msg.sender] = 0;
        boostMultiplier[msg.sender] = BASE_MULTIPLIER;
        
        safeTransfer(cozyToken, msg.sender, amount);
        emit BoostExited(msg.sender, amount);
    }

    // === VESTING SYSTEM ===

    function setVestingPeriod(uint256 _vestingPeriod) external onlyOwner {
        require(_vestingPeriod > 0, "CozyStaking: INVALID_VESTING");
        vestingPeriod = _vestingPeriod;
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
        if (block.timestamp <= vest.startTime) return 0;
        
        uint256 elapsed = block.timestamp - vest.startTime;
        if (elapsed >= vest.vestingPeriod) {
            return vest.totalAmount - vest.claimedAmount;
        }
        
        uint256 totalClaimable = (vest.totalAmount * elapsed) / vest.vestingPeriod;
        if (totalClaimable <= vest.claimedAmount) return 0;
        return totalClaimable - vest.claimedAmount;
    }

    // === MULTI-REWARD TOKENS ===

    function addRewardToken(address _rewardToken, uint256 _rewardPerBlock) external onlyOwner {
        require(_rewardToken != address(0), "CozyStaking: ZERO_ADDRESS");
        require(_rewardToken != cozyToken, "CozyStaking: CANNOT_ADD_COZY");
        require(!isRewardToken[_rewardToken], "CozyStaking: ALREADY_ADDED");
        
        rewardTokens.push(_rewardToken);
        isRewardToken[_rewardToken] = true;
        rewardTokenInfo[_rewardToken] = RewardTokenInfo({
            rewardPerBlock: _rewardPerBlock,
            accRewardPerShare: 0,
            lastRewardBlock: block.number > startBlock ? block.number : startBlock,
            totalAllocPoint: totalAllocPoint
        });
        
        emit RewardTokenAdded(_rewardToken, _rewardPerBlock);
    }

    // === GOVERNANCE FEATURES ===

    function delegateVotingPower(address _to) external {
        require(_to != address(0), "CozyStaking: ZERO_ADDRESS");
        require(_to != msg.sender, "CozyStaking: SELF_DELEGATION");
        
        voteDelegation[msg.sender] = _to;
        delegatedVotingPower[_to] += getVotingPower(msg.sender);
        
        emit VoteDelegated(msg.sender, _to);
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
        if (block.number >= lastHalvingBlock + rewardHalvingPeriod && halvingCount < 4) {
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
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 reward = (multiplier * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
            accRewardPerShare += (reward * 1e12) / lpSupply;
        }

        uint256 baseRewards = user.pendingRewards + ((user.amount * accRewardPerShare) / 1e12 - user.rewardDebt);
        
        // Apply boost multiplier
        uint256 multiplier = boostMultiplier[_user];
        return (baseRewards * multiplier) / BASE_MULTIPLIER;
    }

    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= startBlock || _from >= endBlock) {
            return 0;
        }
        
        uint256 from = _from < startBlock ? startBlock : _from;
        uint256 to = _to > endBlock ? endBlock : _to;
        
        if (from > to) return 0;
        return to - from;
    }

    // ... (other existing functions like emergencyWithdraw, massUpdatePools, etc.)

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

        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        if (multiplier == 0) return;

        uint256 reward = (multiplier * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
        
        pool.accRewardPerShare += (reward * 1e12) / lpSupply;
        pool.lastRewardBlock = block.number;
        
        // Check for reward halving
        checkAndApplyHalving();
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
}

// Minimal ERC20 Interface
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}