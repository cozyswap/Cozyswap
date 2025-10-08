// Tambahkan ini ke contract yang sudah ada:

// === MISSING VIEW FUNCTIONS ===
function getStakedAmount(uint256 _pid, address _user) external view validatePool(_pid) returns (uint256) {
    return userInfo[_pid][_user].amount;
}

function getPoolInfo(uint256 _pid) external view validatePool(_pid) returns (
    address lpToken,
    uint256 allocPoint,
    uint256 totalStaked,
    uint256 accRewardPerShare,
    bool allowsLock
) {
    PoolInfo storage pool = poolInfo[_pid];
    return (pool.lpToken, pool.allocPoint, pool.totalStaked, pool.accRewardPerShare, pool.allowsLock);
}

function getUserInfo(uint256 _pid, address _user) external view validatePool(_pid) returns (
    uint256 amount,
    uint256 rewardDebt,
    uint256 pendingRewards,
    uint256 lockUntil,
    uint256 lastDepositTime
) {
    UserInfo storage user = userInfo[_pid][_user];
    return (user.amount, user.rewardDebt, user.pendingRewards, user.lockUntil, user.lastDepositTime);
}

// === MISSING ADMIN FUNCTIONS ===
function setEndBlock(uint256 _endBlock) external onlyOwner {
    require(_endBlock > block.number, "CozyStaking: INVALID_END_BLOCK");
    require(_endBlock > startBlock, "CozyStaking: END_BEFORE_START");
    endBlock = _endBlock;
    emit EndBlockUpdated(_endBlock);
}

function recoverToken(address _token, uint256 _amount) external onlyOwner {
    require(_token != cozyToken, "CozyStaking: CANNOT_RECOVER_COZY");
    for (uint256 i = 0; i < poolInfo.length; i++) {
        require(_token != poolInfo[i].lpToken, "CozyStaking: CANNOT_RECOVER_LP");
    }
    IERC20(_token).transfer(msg.sender, _amount);
}

// === MISSING BATCH OPERATIONS ===
function claimAllRewards() external {
    uint256 totalPending;
    
    for (uint256 pid = 0; pid < poolInfo.length; pid++) {
        if (userInfo[pid][msg.sender].amount > 0) {
            updatePool(pid);
            UserInfo storage user = userInfo[pid][msg.sender];
            
            uint256 pending = (user.amount * poolInfo[pid].accRewardPerShare) / 1e12 - user.rewardDebt;
            if (pending > 0) {
                user.pendingRewards += pending;
            }
            user.rewardDebt = (user.amount * poolInfo[pid].accRewardPerShare) / 1e12;
            
            totalPending += user.pendingRewards;
            user.pendingRewards = 0;
        }
    }
    
    if (totalPending > 0) {
        safeCozyTransfer(msg.sender, totalPending);
        emit AllRewardsClaimed(msg.sender, totalPending);
    }
}

// === MISSING EVENTS ===
event AllRewardsClaimed(address indexed user, uint256 amount);
event EndBlockUpdated(uint256 newEndBlock);
event TokenRecovered(address indexed token, uint256 amount);