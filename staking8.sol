// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

contract CozyStakingComplete {
    using SafeERC20 for IERC20;
    
    struct UserInfo {
        uint128 amount;
        uint128 rewardDebt;  
        uint128 pendingRewards;
        uint32 lastDepositTime;
        uint32 lockUntil;
        uint16 boostMultiplier;
    }

    struct PoolInfo {
        address lpToken;
        uint96 allocPoint;
        uint64 lastRewardBlock;
        uint128 accRewardPerShare;
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

    // Immutable state variables
    address public immutable cozyToken;
    address public owner;
    address public treasury;
    
    // Packed state variables
    uint128 public rewardPerBlock;
    uint64 public startBlock;
    uint64 public endBlock;
    uint64 public lastHalvingBlock;
    uint32 public totalAllocPoint;
    uint16 public halvingCount;
    uint32 public rewardHalvingPeriod;

    // Constants
    uint16 public constant MAX_BOOST_MULTIPLIER = 300;
    uint16 public constant BASE_MULTIPLIER = 100;
    uint16 public constant MAX_HALVING_COUNT = 4;
    uint16 public constant MAX_DEPOSIT_FEE = 1000;

    // Arrays and mappings
    PoolInfo[] public poolInfo;
    mapping(uint256 => LockOption[]) public lockOptions;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(address => uint128) public cozyStakedForBoost;
    mapping(address => uint16) public userBoostMultiplier;
    mapping(address => bool) public hasStaked;
    
    // Statistics
    uint32 public totalUsers;
    uint128 public totalRewardsDistributed;

    // ✅ FIXED: Added missing RewardHalving event
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
    event RewardHalving(uint256 newRewardPerBlock, uint256 halvingCount); // ✅ ADDED THIS LINE

    // Error messages
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

    // === CORE FUNCTIONS ===
    function deposit(uint256 _pid, uint256 _amount, uint256 _lockPeriod) external validatePool(_pid) {
        if (_amount == 0) revert InvalidAmount();

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        _validateLockPeriod(_pid, _lockPeriod);
        updatePool(_pid);

        if (user.amount > 0) {
            uint256 pending = (uint256(user.amount) * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
            if (pending > 0) user.pendingRewards += uint128(pending);
        }

        (uint256 amountAfterFee, uint256 fee) = _calculateDepositFee(pool, _amount);
        
        IERC20(pool.lpToken).safeTransferFrom(msg.sender, address(this), _amount);
        if (fee > 0) IERC20(pool.lpToken).safeTransfer(treasury, fee);

        _updateUserStake(_pid, msg.sender, amountAfterFee, _lockPeriod);
        pool.totalStaked += uint128(amountAfterFee);

        user.rewardDebt = uint128((uint256(user.amount) * pool.accRewardPerShare) / 1e12);
        emit Deposit(msg.sender, _pid, amountAfterFee, _lockPeriod, fee);
    }

    function withdraw(uint256 _pid, uint256 _amount) external validatePool(_pid) notLocked(_pid, msg.sender) {
        UserInfo storage user = userInfo[_pid][msg.sender];
        if (uint256(user.amount) < _amount) revert InsufficientBalance();

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

    function setPoolAllocation(uint256 _pid, uint256 _allocPoint, bool _withUpdate) external onlyOwner {
        if (_allocPoint == 0) revert InvalidAlloc();
        if (_pid >= poolInfo.length) revert PoolNotExist();

        if (_withUpdate) massUpdatePools();

        totalAllocPoint = totalAllocPoint - uint32(poolInfo[_pid].allocPoint) + uint32(_allocPoint);
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

    function setRewardPerBlock(uint256 _rewardPerBlock, bool _withUpdate) external onlyOwner {
        if (_rewardPerBlock == 0) revert InvalidReward();
        if (_withUpdate) massUpdatePools();
        
        uint256 oldReward = rewardPerBlock;
        rewardPerBlock = uint128(_rewardPerBlock);
        emit RewardPerBlockUpdated(oldReward, _rewardPerBlock);
    }

    function earlyWithdraw(uint256 _pid, uint256 _amount) external validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (uint256(user.amount) < _amount) revert InsufficientBalance();
        if (user.lockUntil <= block.timestamp) revert StillLocked();

        updatePool(_pid);
        uint256 pending = (uint256(user.amount) * pool.accRewardPerShare) / 1e12 - user.rewardDebt;
        uint256 penalty = pending / 2;

        if (_amount > 0) {
            user.amount -= uint128(_amount);
            pool.totalStaked -= uint128(_amount);
            IERC20(pool.lpToken).safeTransfer(msg.sender, _amount);
        }

        user.rewardDebt = uint128((uint256(user.amount) * pool.accRewardPerShare) / 1e12);
        user.pendingRewards += uint128(pending - penalty);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // === VIEW FUNCTIONS ===
    function pendingRewards(uint256 _pid, address _user) public view validatePool(_pid) returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];

        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 lpSupply = pool.totalStaked;

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getRewardMultiplier(uint256(pool.lastRewardBlock), block.number);
            uint256 reward = (multiplier * rewardPerBlock * pool.allocPoint) / totalAllocPoint;
            accRewardPerShare += (reward * 1e12) / lpSupply;
        }

        uint256 baseRewards = user.pendingRewards + ((uint256(user.amount) * accRewardPerShare) / 1e12 - user.rewardDebt);
        uint256 effectiveMultiplier = user.boostMultiplier;
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

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
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

    function getUserStake(uint256 _pid, address _user) external view returns (uint256 amount, uint256 lockUntil, uint256 boostMultiplier) {
        UserInfo memory user = userInfo[_pid][_user];
        return (user.amount, user.lockUntil, user.boostMultiplier);
    }

    // === INTERNAL FUNCTIONS ===
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            if (poolInfo[pid].isActive) updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public validatePool(_pid) {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) return;

        uint256 lpSupply = pool.totalStaked;
        if (lpSupply == 0) {
            pool.lastRewardBlock = uint64(block.number);
            return;
        }

        uint256 multiplier = getRewardMultiplier(uint256(pool.lastRewardBlock), block.number);
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
            emit RewardHalving(rewardPerBlock, halvingCount); // ✅ FIXED: Event now exists
        }
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    // Internal helpers
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
            uint256 boostedRewards = (totalPending * user.boostMultiplier) / BASE_MULTIPLIER;
            
            totalRewardsDistributed += uint128(boostedRewards);
            _safeCozyTransfer(_user, boostedRewards);
            emit ClaimRewards(_user, _pid, boostedRewards);
        }
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

    function _safeCozyTransfer(address _to, uint256 _amount) internal {
        uint256 cozyBal = SafeERC20.balanceOf(IERC20(cozyToken), address(this));
        uint256 transferAmount = _amount > cozyBal ? cozyBal : _amount;
        if (transferAmount > 0) IERC20(cozyToken).safeTransfer(_to, transferAmount);
    }

    function _addDefaultLockOptions(uint256 _pid) internal {
        lockOptions[_pid].push(LockOption(uint32(30 days), 120, true));
        lockOptions[_pid].push(LockOption(uint32(90 days), 150, true)); 
        lockOptions[_pid].push(LockOption(uint32(180 days), 200, true));
        lockOptions[_pid].push(LockOption(uint32(365 days), 300, true));
    }
}

// Library
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transfer failed");
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        (bool success, bytes memory data) = address(token).call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "SafeERC20: transferFrom failed");
    }

    function balanceOf(IERC20 token, address account) internal view returns (uint256) {
        (bool success, bytes memory data) = address(token).staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, account));
        require(success, "SafeERC20: balanceOf failed");
        return abi.decode(data, (uint256));
    }
}

// Interface
interface IERC20 {
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}