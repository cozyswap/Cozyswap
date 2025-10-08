// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// ✅ Optimized with libraries and reduced contract size
contract CozyStakingComplete {
    using SafeERC20 for IERC20;
    
    struct UserInfo {
        uint128 amount;           // Reduced from uint256
        uint128 rewardDebt;       // Reduced from uint256  
        uint128 pendingRewards;   // Reduced from uint256
        uint32 lastDepositTime;   // Reduced from uint256
        uint32 lockUntil;         // Reduced from uint256
        uint16 boostMultiplier;   // Reduced from uint256
    }

    struct PoolInfo {
        address lpToken;
        uint96 allocPoint;        // Reduced from uint256
        uint64 lastRewardBlock;   // Reduced from uint256
        uint128 accRewardPerShare; // Reduced from uint256
        uint128 totalStaked;      // Reduced from uint256
        bool allowsLock;
        uint32 minLockPeriod;     // Reduced from uint256
        uint32 maxLockPeriod;     // Reduced from uint256
        uint16 depositFee;        // Reduced from uint256 (100 = 1%)
        bool isActive;
    }

    struct LockOption {
        uint32 period;            // Reduced from uint256
        uint16 multiplier;        // Reduced from uint256
        bool enabled;
    }

    struct VestingInfo {
        uint128 totalAmount;      // Reduced from uint256
        uint128 claimedAmount;    // Reduced from uint256
        uint32 startTime;         // Reduced from uint256
        uint32 vestingPeriod;     // Reduced from uint256
        uint32 cliffPeriod;       // Reduced from uint256
    }

    // Immutable state variables
    address public immutable cozyToken;
    address public owner;
    address public treasury;
    
    // Packed state variables
    uint128 public rewardPerBlock;    // Reduced from uint256
    uint64 public startBlock;         // Reduced from uint256
    uint64 public endBlock;           // Reduced from uint256
    uint64 public lastHalvingBlock;   // Reduced from uint256
    uint32 public totalAllocPoint;    // Reduced from uint256
    uint16 public halvingCount;       // Reduced from uint256
    uint16 public rewardHalvingPeriod;// Reduced from uint256
    
    // Constants
    uint16 public constant MAX_BOOST_MULTIPLIER = 300;
    uint16 public constant BASE_MULTIPLIER = 100;
    uint16 public constant MAX_HALVING_COUNT = 4;
    uint16 public constant MAX_DEPOSIT_FEE = 1000;

    // Arrays and mappings
    PoolInfo[] public poolInfo;
    mapping(uint256 => LockOption[]) public lockOptions;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(address => uint128) public cozyStakedForBoost; // Reduced from uint256
    mapping(address => uint16) public userBoostMultiplier; // Reduced from uint256
    mapping(address => VestingInfo) public vestingInfo;
    mapping(address => address) public voteDelegation;
    mapping(address => uint256) public delegatedVotingPower;
    mapping(address => bool) public hasStaked;
    
    // Statistics
    uint32 public totalUsers;          // Reduced from uint256
    uint128 public totalRewardsDistributed; // Reduced from uint256

    // Events with indexed parameters optimized
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

    // Short error messages to save space
    error NotOwner();
    error PoolNotExist();
    error PoolInactive();
    error StillLocked();
    error ZeroAddress();
    error InvalidAmount();
    error InvalidReward();
    error InvalidAlloc();
    error InsufficientBalance();
    error FeeTooHigh();
    error LockNotAllowed();
    error LockTooShort();
    error LockTooLong();
    error InvalidLockPeriod();
    error NoStake();
    error NoBoost();
    error NoVesting();
    error NothingClaimable();
    error SelfDelegation();
    error NotDelegated();

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

    constructor(
        address _cozyToken,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _endBlock,
        address _treasury
    ) {
        if (_cozyToken == address(0)) revert ZeroAddress();
        if (_rewardPerBlock == 0) revert InvalidReward();
        if (_startBlock < block.number) revert InvalidReward();
        if (_endBlock <= _startBlock) revert InvalidReward();
        if (_treasury == address(0)) revert ZeroAddress();

        cozyToken = _cozyToken;
        rewardPerBlock = uint128(_rewardPerBlock);
        startBlock = uint64(_startBlock);
        endBlock = uint64(_endBlock);
        owner = msg.sender;
        treasury = _treasury;
        lastHalvingBlock = uint64(_startBlock);
        rewardHalvingPeriod = 100000;
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
        if (_lpToken == address(0)) revert ZeroAddress();
        if (_allocPoint == 0) revert InvalidAlloc();
        if (_depositFee > MAX_DEPOSIT_FEE) revert FeeTooHigh();

        if (_withUpdate) massUpdatePools();

        totalAllocPoint += uint32(_allocPoint);
        uint64 lastRewardBlock = uint64(block.number > startBlock ? block.number : startBlock);

        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: uint96(_allocPoint),
            lastRewardBlock: lastRewardBlock,
            accRewardPerShare: 0,
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

    function _addDefaultLockOptions(uint256 _pid) internal {
        lockOptions[_pid].push(LockOption(30 days, 120, true));
        lockOptions[_pid].push(LockOption(90 days, 150, true)); 
        lockOptions[_pid].push(LockOption(180 days, 200, true));
        lockOptions[_pid].push(LockOption(365 days, 300, true));
    }

    function setPoolAllocation(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyOwner {
        if (_allocPoint == 0) revert InvalidAlloc();
        if (_pid >= poolInfo.length) revert PoolNotExist();

        if (_withUpdate) massUpdatePools();

        totalAllocPoint = totalAllocPoint - uint32(poolInfo[_pid].allocPoint) + uint32(_allocPoint);
        poolInfo[_pid].allocPoint = uint96(_allocPoint);

        emit PoolUpdated(_pid, _allocPoint);
    }

    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            if (poolInfo[pid].isActive) updatePool(pid);
        }
    }

    // === STAKING FUNCTIONS ===
    function deposit(uint256 _pid, uint256 _amount, uint256 _lockPeriod) external validatePool(_pid) {
        if (_amount == 0) revert InvalidAmount();

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        _validateLockPeriod(_pid, _lockPeriod);
        updatePool(_pid);

        // Handle pending rewards
        if (user.amount > 0) {
            uint256 pending = (uint256(user.amount) * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
            if (pending > 0) user.pendingRewards += uint128(pending);
        }

        // Calculate deposit fee
        (uint256 amountAfterFee, uint256 fee) = _calculateDepositFee(pool, _amount);
        
        // Transfer tokens
        IERC20(pool.lpToken).safeTransferFrom(msg.sender, address(this), _amount);
        if (fee > 0) IERC20(pool.lpToken).safeTransfer(treasury, fee);

        // Update state
        _updateUserStake(_pid, msg.sender, amountAfterFee, _lockPeriod);
        pool.totalStaked += uint128(amountAfterFee);

        user.rewardDebt = uint128((uint256(user.amount) * pool.accRewardPerShare) / 1e12);
        emit Deposit(msg.sender, _pid, amountAfterFee, _lockPeriod, fee);
    }

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
        user.amount += uint128(_amount);

        if (_lockPeriod > 0) {
            user.lockUntil = uint32(block.timestamp + _lockPeriod);
            user.boostMultiplier = uint16(getLockMultiplier(_pid, _lockPeriod));
        } else {
            user.boostMultiplier = BASE_MULTIPLIER;
        }
        user.lastDepositTime = uint32(block.timestamp);

        if (!hasStaked[_user]) {
            hasStaked[_user] = true;
            totalUsers++;
        }
    }

    function withdraw(uint256 _pid, uint256 _amount) external validatePool(_pid) notLocked(_pid, msg.sender) {
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (user.amount < _amount) revert InsufficientBalance();

        PoolInfo storage pool = poolInfo[_pid];
        updatePool(_pid);

        _updatePendingRewards(_pid, msg.sender);

        if (_amount > 0) {
            user.amount -= uint128(_amount);
            pool.totalStaked -= uint128(_amount);
            IERC20(pool.lpToken).safeTransfer(msg.sender, _amount);
        }

        user.rewardDebt = uint128((uint256(user.amount) * pool.accRewardPerShare) / 1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function claimRewards(uint256 _pid) external validatePool(_pid) {
        updatePool(_pid);
        _updatePendingRewards(_pid, msg.sender);
        _claimPendingRewards(_pid, msg.sender);
    }

    function _updatePendingRewards(uint256 _pid, address _user) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 pending = (uint256(user.amount) * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        if (pending > 0) user.pendingRewards += uint128(pending);
        user.rewardDebt = uint128((uint256(user.amount) * pool.accRewardPerShare) / 1e12);
    }

    function _claimPendingRewards(uint256 _pid, address _user) internal {
        UserInfo storage user = userInfo[_pid][_user];
        uint256 totalPending = user.pendingRewards;
        
        if (totalPending > 0) {
            user.pendingRewards = 0;
            uint256 effectiveMultiplier = _calculateEffectiveMultiplier(_pid, _user);
            uint256 boostedRewards = (totalPending * effectiveMultiplier) / BASE_MULTIPLIER;
            
            totalRewardsDistributed += uint128(boostedRewards);
            _safeCozyTransfer(_user, boostedRewards);
            emit ClaimRewards(_user, _pid, boostedRewards);
        }
    }

    // === BOOSTED REWARDS ===
    function enterBoosting(uint256 _cozyAmount) external {
        if (_cozyAmount == 0) revert InvalidAmount();

        IERC20(cozyToken).safeTransferFrom(msg.sender, address(this), _cozyAmount);
        cozyStakedForBoost[msg.sender] += uint128(_cozyAmount);
        _updateBoostMultiplier(msg.sender);

        emit BoostEntered(msg.sender, _cozyAmount, userBoostMultiplier[msg.sender]);
    }

    function _updateBoostMultiplier(address _user) internal {
        uint256 additionalBoost = (uint256(cozyStakedForBoost[_user]) * 1) / (100 * 1e18);
        uint256 newBoost = BASE_MULTIPLIER + additionalBoost;
        if (newBoost > MAX_BOOST_MULTIPLIER) newBoost = MAX_BOOST_MULTIPLIER;

        userBoostMultiplier[_user] = uint16(newBoost);

        // Update all user positions
        for (uint256 i = 0; i < poolInfo.length; i++) {
            if (userInfo[i][_user].amount > 0) {
                uint256 lockBoost = userInfo[i][_user].boostMultiplier;
                uint256 totalBoost = (lockBoost * newBoost) / BASE_MULTIPLIER;
                if (totalBoost > MAX_BOOST_MULTIPLIER) totalBoost = MAX_BOOST_MULTIPLIER;
                userInfo[i][_user].boostMultiplier = uint16(totalBoost);
            }
        }
    }

    // === VIEW FUNCTIONS ===
    function pendingRewards(uint256 _pid, address _user) public view validatePool(_pid) returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 lpSupply = pool.totalStaked;

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getRewardMultiplier(pool.lastRewardBlock, block.number);
            uint256 reward = (multiplier * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
            accRewardPerShare += (reward * 1e12) / lpSupply;
        }

        uint256 baseRewards = user.pendingRewards + ((uint256(user.amount) * accRewardPerShare) / 1e12 - user.rewardDebt);
        uint256 effectiveMultiplier = _calculateEffectiveMultiplier(_pid, _user);
        return (baseRewards * effectiveMultiplier) / BASE_MULTIPLIER;
    }

    function getRewardMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= startBlock || _from >= endBlock) return 0;
        uint256 from = _from < startBlock ? startBlock : _from;
        uint256 to = _to > endBlock ? endBlock : _to;
        return from > to ? 0 : to - from;
    }

    function getLockMultiplier(uint256 _pid, uint256 _lockPeriod) public view returns (uint256) {
        if (!poolInfo[_pid].allowsLock || _lockPeriod == 0) return BASE_MULTIPLIER;

        LockOption[] memory options = lockOptions[_pid];
        for (uint256 i = 0; i < options.length; i++) {
            if (options[i].period == _lockPeriod && options[i].enabled) return options[i].multiplier;
        }
        return BASE_MULTIPLIER;
    }

    function _calculateEffectiveMultiplier(uint256 _pid, address _user) internal view returns (uint256) {
        return userInfo[_pid][_user].boostMultiplier;
    }

    // === INTERNAL FUNCTIONS ===
    function updatePool(uint256 _pid) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) return;

        uint256 lpSupply = pool.totalStaked;
        if (lpSupply == 0) {
            pool.lastRewardBlock = uint64(block.number);
            return;
        }

        uint256 multiplier = getRewardMultiplier(pool.lastRewardBlock, block.number);
        if (multiplier == 0) return;

        uint256 reward = (multiplier * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
        pool.accRewardPerShare += uint128((reward * 1e12) / lpSupply);
        pool.lastRewardBlock = uint64(block.number);

        checkAndApplyHalving();
    }

    function checkAndApplyHalving() public {
        if (block.number >= lastHalvingBlock + rewardHalvingPeriod && halvingCount < MAX_HALVING_COUNT) {
            rewardPerBlock = rewardPerBlock / 2;
            lastHalvingBlock = uint64(block.number);
            halvingCount++;
            emit RewardHalving(rewardPerBlock, halvingCount);
        }
    }

    function _safeCozyTransfer(address _to, uint256 _amount) internal {
        uint256 cozyBal = IERC20(cozyToken).balanceOf(address(this));
        uint256 transferAmount = _amount > cozyBal ? cozyBal : _amount;
        if (transferAmount > 0) IERC20(cozyToken).safeTransfer(_to, transferAmount);
    }

    // Essential functions only to reduce contract size
    function emergencyWithdraw(uint256 _pid) external {
        if (_pid >= poolInfo.length) revert PoolNotExist();
        
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        
        if (user.amount == 0) revert NoStake();

        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.pendingRewards = 0;
        user.lockUntil = 0;
        user.boostMultiplier = BASE_MULTIPLIER;

        pool.totalStaked -= uint128(amount);
        IERC20(pool.lpToken).safeTransfer(msg.sender, amount);

        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }
}

// Optimized SafeERC20 library
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(abi.encodeWithSelector(token.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(abi.encodeWithSelector(token.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transferFrom failed");
    }

    function balanceOf(IERC20 token, address account) internal view returns (uint256) {
        (bool success, bytes memory data) = address(token).staticcall(abi.encodeWithSelector(token.balanceOf.selector, account));
        require(success, "SafeERC20: balanceOf failed");
        return abi.decode(data, (uint256));
    }
}

// Minimal interface
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}