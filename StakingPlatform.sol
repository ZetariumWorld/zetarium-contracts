// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title Staking Platform (Factory + Pool)
/// @notice Factory deploys staking pools where users can stake a token and earn APR rewards
///         calculated per-second. Modeled similarly to VestingSalePlatform pattern.
contract StakingPlatform is Ownable(msg.sender) {
    using SafeERC20 for IERC20;

    uint256 public constant BPS_DENOM = 10_000; // 100% = 10000
    
    /// @notice Pool creation fee in BNB (default 0.002 BNB)
    uint256 public poolCreationFee = 0.002 ether;
    
    /// @notice Treasury where pool creation fees are sent
    address public treasury;
    
    /// @notice Backend signer for stake quotes
    address public quoteSigner;

    /// @notice Basic pool metadata stored in factory for discovery
    struct PoolMeta {
        address poolAddress;
        address owner; // project owner who created pool
        address stakingToken;
        address rewardToken; // if zero at creation, equals stakingToken in child
        uint256 aprBps; // APR in basis points (e.g. 500 = 5% APR)
        uint256 createdAt;
        uint256 duration; // pool duration in seconds
        uint256 endTime; // createdAt + duration
        bool active; // mirrored from child; owner may pause/close new rewards
        uint256 totalStaked; // mirrored from child
        uint256 totalClaimed; // mirrored from child
    }

    // Pools registry
    mapping(uint256 => PoolMeta) public pools; // poolId => meta
    uint256 public totalPoolsCount;
    mapping(address => uint256) public poolIdOf; // child => id

    // Owner index
    mapping(address => uint256[]) private _ownerPoolIds; // owner => ids
    
    // User stake tracking
    mapping(address => uint256[]) private _userActivePools; // user => poolIds where user has active stake
    mapping(address => mapping(uint256 => bool)) private _userInPool; // user => poolId => hasStake
    
    // Emergency withdrawal timelock
    mapping(uint256 => uint256) public emergencyTimestamp; // poolId => timestamp when emergency triggered
    uint256 public constant EMERGENCY_DELAY = 24 hours; // 24 hour delay for emergency withdrawal

    /// @notice Emitted when a new pool is created
    event PoolCreated(
        uint256 indexed poolId,
        address indexed poolAddress,
        address indexed owner,
        address stakingToken,
        address rewardToken,
        uint256 aprBps,
        uint256 duration,
        uint256 endTime,
        address quoteSigner,
        bytes signature
    );

    /// @notice Emitted when pool state mirrors change
    event PoolMirrored(uint256 indexed poolId, uint256 totalStaked, uint256 totalClaimed, bool active);
    
    /// @notice Emitted when emergency withdrawal is initiated
    event EmergencyInitiated(uint256 indexed poolId, uint256 executeAfter);
    
    /// @notice Emitted when emergency withdrawal is executed
    event EmergencyExecuted(uint256 indexed poolId);
    
    /// @notice Emitted when emergency withdrawal is cancelled
    event EmergencyCancelled(uint256 indexed poolId);
    
    /// @notice Emitted when pool creation fee is changed
    event PoolCreationFeeSet(uint256 newFee);
    
    /// @notice Emitted when treasury is changed
    event TreasuryChanged(address indexed oldTreasury, address indexed newTreasury);
    
    /// @notice Emitted when pool creation fee is collected
    event FeeCollected(address indexed payer, uint256 amount);
    
    /// @notice Emitted when quote signer is changed
    event QuoteSignerSet(address indexed oldSigner, address indexed newSigner);

    // --------- Constructor ---------
    
    constructor(address _treasury) {
        treasury = _treasury == address(0) ? msg.sender : _treasury;
    }

    // --------- Views ---------

    function totalPools() external view returns (uint256) {
        return totalPoolsCount;
    }

    function getPoolsInRange(uint256 fromId, uint256 toId) external view returns (PoolMeta[] memory list) {
        require(toId >= fromId, "range");
        require(toId <= totalPoolsCount, "oob");
        uint256 len = toId - fromId + 1;
        list = new PoolMeta[](len);
        for (uint256 i = 0; i < len; i++) {
            list[i] = pools[fromId + i];
        }
    }

    function getPoolByIndex(uint256 poolId) external view returns (PoolMeta memory) {
        return pools[poolId];
    }

    function getOwnerPoolIds(address owner_) external view returns (uint256[] memory) {
        return _ownerPoolIds[owner_];
    }
    
    /// @notice Returns pool IDs where user has active stakes
    /// @param user The user address to check
    /// @return Array of pool IDs where user has active stakes
    function getUserActivePools(address user) external view returns (uint256[] memory) {
        return _userActivePools[user];
    }
    
    /// @notice Returns the current pool creation fee
    /// @return The fee amount in BNB wei
    function getPoolCreationFee() external view returns (uint256) {
        return poolCreationFee;
    }

    // --------- Hooks from child to mirror lightweight stats ---------

    function _mirror(uint256 totalStaked, uint256 totalClaimed, bool active) external {
        uint256 id = poolIdOf[msg.sender];
        // Verify that msg.sender is actually a registered pool
        require(pools[id].poolAddress == msg.sender, "pool");
        PoolMeta storage m = pools[id];
        m.totalStaked = totalStaked;
        m.totalClaimed = totalClaimed;
        m.active = active;
        emit PoolMirrored(id, totalStaked, totalClaimed, active);
    }

    /// @notice Add user to pool's active list (called by child pool)
    /// @dev Only pool contracts can call this
    /// @param user The user who staked
    function _addUserToPool(address user) external {
        uint256 poolId = poolIdOf[msg.sender];
        // Verify that msg.sender is actually a registered pool
        require(pools[poolId].poolAddress == msg.sender, "pool");
        
        // If user is not already in this pool, add them
        if (!_userInPool[user][poolId]) {
            _userActivePools[user].push(poolId);
            _userInPool[user][poolId] = true;
        }
    }
    
    /// @notice Remove user from pool's active list (called by child pool)
    /// @dev Only pool contracts can call this
    /// @param user The user who unstaked completely
    function _removeUserFromPool(address user) external {
        uint256 poolId = poolIdOf[msg.sender];
        // Verify that msg.sender is actually a registered pool
        require(pools[poolId].poolAddress == msg.sender, "pool");
        
        // If user is in this pool, remove them
        if (_userInPool[user][poolId]) {
            // Remove from active pools array
            uint256[] storage userPools = _userActivePools[user];
            for (uint256 i = 0; i < userPools.length; i++) {
                if (userPools[i] == poolId) {
                    userPools[i] = userPools[userPools.length - 1];
                    userPools.pop();
                    break;
                }
            }
            _userInPool[user][poolId] = false;
        }
    }

    // --------- Admin functions ---------
    
    /// @notice Set treasury address (only owner)
    /// @param _treasury New treasury address
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "treasury=0");
        emit TreasuryChanged(treasury, _treasury);
        treasury = _treasury;
    }
    
    /// @notice Set pool creation fee (only owner)
    /// @param newFee New fee amount in BNB wei
    function setPoolCreationFee(uint256 newFee) external onlyOwner {
        poolCreationFee = newFee;
        emit PoolCreationFeeSet(newFee);
    }
    
    /// @notice Set quote signer address (only owner)
    /// @param _quoteSigner New quote signer address
    function setQuoteSigner(address _quoteSigner) external onlyOwner {
        emit QuoteSignerSet(quoteSigner, _quoteSigner);
        quoteSigner = _quoteSigner;
    }

    // --------- Create pool ---------

    function createPool(
        address stakingToken,
        uint256 aprBps,
        uint256 duration,
        uint256 initialRewardAmount,
        bytes calldata signature
    ) external payable returns (uint256 poolId, address poolAddress) {
        require(msg.value >= poolCreationFee, "insufficient-fee");
        require(stakingToken != address(0), "stake=0");
        require(duration >= 1 days && duration <= 365 days, "duration");
        require(initialRewardAmount > 0, "no-rewards");
        require(aprBps <= BPS_DENOM * 5, "apr-high"); // cap APR <= 500% to avoid obvious mistakes
        
        // Emit fee collection event
        emit FeeCollected(msg.sender, msg.value);

        uint256 endTime = block.timestamp + duration;
        StakingPool pool = new StakingPool(
            address(this),
            msg.sender,
            stakingToken,
            aprBps,
            endTime
        );

        PoolMeta memory meta = PoolMeta({
            poolAddress: address(pool),
            owner: msg.sender,
            stakingToken: stakingToken,
            rewardToken: stakingToken, // reward token same as staking token
            aprBps: aprBps,
            createdAt: block.timestamp,
            duration: duration,
            endTime: endTime,
            active: true,
            totalStaked: 0,
            totalClaimed: 0
        });

        totalPoolsCount += 1;
        poolId = totalPoolsCount;
        pools[poolId] = meta;
        poolIdOf[address(pool)] = poolId;
        _ownerPoolIds[msg.sender].push(poolId);

        // Transfer initial reward tokens from creator to pool contract
        IERC20(stakingToken).safeTransferFrom(msg.sender, address(pool), initialRewardAmount);
        
        // Initialize reward reserve in pool contract
        StakingPool(address(pool)).initializeRewards(initialRewardAmount);

        emit PoolCreated(poolId, address(pool), msg.sender, stakingToken, stakingToken, aprBps, duration, endTime, quoteSigner, signature);
        
        // Forward creation fee to treasury
        if (msg.value > 0) {
            (bool ok, ) = payable(treasury).call{value: msg.value}("");
            require(ok, "fee-xfer");
        }
        
        return (poolId, address(pool));
    }

    /// @notice Initiate emergency withdrawal - starts 24 hour timelock
    /// @dev Only factory owner can trigger emergency withdrawal
    /// @param poolId The ID of the pool to prepare for emergency withdrawal
    function initiateEmergencyWithdraw(uint256 poolId) external onlyOwner {
        require(poolId > 0 && poolId <= totalPoolsCount, "invalid-pool");
        require(emergencyTimestamp[poolId] == 0, "already-initiated");
        
        emergencyTimestamp[poolId] = block.timestamp;
        emit EmergencyInitiated(poolId, block.timestamp + EMERGENCY_DELAY);
    }
    
    /// @notice Execute emergency withdrawal after timelock period
    /// @dev Can only be called after 24 hour delay
    /// @param poolId The ID of the pool to withdraw from
    function executeEmergencyWithdraw(uint256 poolId) external onlyOwner {
        require(poolId > 0 && poolId <= totalPoolsCount, "invalid-pool");
        require(emergencyTimestamp[poolId] > 0, "not-initiated");
        require(block.timestamp >= emergencyTimestamp[poolId] + EMERGENCY_DELAY, "timelock-active");
        
        PoolMeta storage meta = pools[poolId];
        address poolAddress = meta.poolAddress;
        require(poolAddress != address(0), "pool-not-exist");
        
        // Reset emergency timestamp
        emergencyTimestamp[poolId] = 0;
        
        // Call emergency withdraw on the pool contract
        StakingPool(poolAddress).emergencyWithdraw();
        
        emit EmergencyExecuted(poolId);
    }
    
    /// @notice Cancel emergency withdrawal before execution
    /// @dev Only factory owner can cancel
    /// @param poolId The ID of the pool to cancel emergency withdrawal for
    function cancelEmergencyWithdraw(uint256 poolId) external onlyOwner {
        require(poolId > 0 && poolId <= totalPoolsCount, "invalid-pool");
        require(emergencyTimestamp[poolId] > 0, "not-initiated");
        
        emergencyTimestamp[poolId] = 0;
        emit EmergencyCancelled(poolId);
    }
}

/// @dev Child staking pool with per-second APR rewards
contract StakingPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BPS_DENOM = 10_000;
    uint256 private constant YEAR = 365 days;

    StakingPlatform public immutable factory;
    address public immutable owner; // project owner
    address public immutable stakingToken;
    address public immutable rewardToken; // equals stakingToken if set to 0 at creation
    uint256 public immutable endTime; // pool automatically deactivates after this time
    uint8 public immutable stakingDecimals; // staking token decimals (6, 9, 18, etc.)
    uint8 public immutable rewardDecimals; // reward token decimals
    uint256 public aprBps; // APR in basis points
    bool public active; // if false, no new stake and rewards stop accruing from setActive(false) time

    // Pool aggregates
    uint256 public totalStaked;
    uint256 public totalClaimed;
    uint256 public rewardReserve; // dedicated reward token reserve

    struct UserInfo {
        uint256 amount;        // staked amount
        uint256 pending;       // accumulated but not yet claimed rewards
        uint256 claimed;       // lifetime claimed rewards
        uint256 lastUpdate;    // timestamp of last reward update/claim/stake change
    }
    mapping(address => UserInfo) public users;
    
    // Nonce tracking for signature verification
    mapping(address => uint256) public nonces;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 amount);
    event Funded(address indexed from, uint256 amount);
    event ActiveSet(bool active);
    event AprSet(uint256 aprBps);

    modifier onlyOwner() {
        require(msg.sender == owner, "owner");
        _;
    }

    constructor(
        address _factory,
        address _owner,
        address _stakingToken,
        uint256 _aprBps,
        uint256 _endTime
    ) {
        require(_factory != address(0) && _owner != address(0) && _stakingToken != address(0), "zero");
        require(_endTime > block.timestamp, "endTime");
        factory = StakingPlatform(_factory);
        owner = _owner;
        stakingToken = _stakingToken;
        rewardToken = _stakingToken; // reward token is same as staking token
        endTime = _endTime;
        
        // Get token decimals (both same since same token)
        stakingDecimals = IERC20Metadata(_stakingToken).decimals();
        rewardDecimals = stakingDecimals; // same as staking decimals
        
        require(_aprBps <= BPS_DENOM * 5, "apr-high");
        aprBps = _aprBps;
        active = true;
    }

    /// @notice Initialize reward reserve (called only once by factory during pool creation)
    function initializeRewards(uint256 amount) external {
        require(msg.sender == address(factory), "only-factory");
        require(rewardReserve == 0, "already-init");
        rewardReserve = amount;
        emit Funded(tx.origin, amount);
    }

    // --------- Admin ---------

    function setActive(bool _active) external onlyOwner {
        active = _active;
        _updateMirror();
        emit ActiveSet(_active);
    }

    function setAprBps(uint256 _aprBps) external onlyOwner {
        require(_aprBps <= BPS_DENOM * 5, "apr-high");
        aprBps = _aprBps;
        _updateMirror();
        emit AprSet(_aprBps);
    }

    /// @notice Fund reward reserves with rewardToken
    function fundRewards(uint256 amount) external onlyOwner {
        require(amount > 0, "zero");
        IERC20(rewardToken).safeTransferFrom(msg.sender, address(this), amount);
        rewardReserve += amount;
        emit Funded(msg.sender, amount);
    }

    /// @notice Emergency withdrawal - only factory owner can withdraw all tokens
    /// @dev This is for emergency situations only
    function emergencyWithdraw() external {
        require(msg.sender == address(factory), "only-factory");
        
        // Prevent multiple emergency withdrawals
        require(active, "already-emergency");
        
        // Get total balance of the staking token in this contract
        uint256 balance = IERC20(stakingToken).balanceOf(address(this));
        
        if (balance > 0) {
            // Only withdraw excess tokens above totalStaked + rewardReserve
            // This protects user staked funds and allocated rewards
            uint256 protectedAmount = totalStaked + rewardReserve;
            
            if (balance > protectedAmount) {
                uint256 excessAmount = balance - protectedAmount;
                IERC20(stakingToken).safeTransfer(StakingPlatform(factory).owner(), excessAmount);
            }
        }
        
        // Clear reward reserve and deactivate pool
        // Keep totalStaked intact to protect user funds
        rewardReserve = 0;
        active = false;
        
        // Update mirror to reflect emergency state consistently
        _updateMirror();
        
        emit ActiveSet(false);
    }

    // --------- Core: staking, unstaking, claiming ---------

    function stake(uint256 amount) external nonReentrant {
        _checkExpiration(); // Auto-deactivate if expired only
        require(active, "inactive");
        require(amount > 0, "zero");
        _accrue(msg.sender);
        users[msg.sender].amount += amount;
        totalStaked += amount;
        IERC20(stakingToken).safeTransferFrom(msg.sender, address(this), amount);
        
        // Notify factory about user staking (if first time in this pool)
        factory._addUserToPool(msg.sender);
        
        _updateMirror();
        emit Staked(msg.sender, amount);
    }
    
    /// @notice Stake with backend signature verification (same pattern as VestingSale.buyWithQuote)
    /// @param amount Amount to stake
    /// @param deadline Signature expiration timestamp
    /// @param nonce User's current nonce
    /// @param signature Backend signature authorizing the stake
    function stakeWithQuote(
        uint256 amount,
        uint256 deadline,
        uint256 nonce,
        bytes calldata signature
    ) external nonReentrant {
        _checkExpiration();
        require(active, "inactive");
        require(amount > 0, "zero");
        require(block.timestamp <= deadline, "expired");
        require(nonce == nonces[msg.sender], "nonce");
        
        // Verify signature from backend
        address quoteSigner = factory.quoteSigner();
        require(quoteSigner != address(0), "no-signer");
        
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("StakeQuote(address user,uint256 amount,uint256 deadline,uint256 nonce)"),
                msg.sender,
                amount,
                deadline,
                nonce
            )
        );
        
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(structHash);
        address recovered = ECDSA.recover(hash, signature);
        require(recovered == quoteSigner, "sig");
        
        // Increment nonce
        nonces[msg.sender]++;
        
        // Perform stake
        _accrue(msg.sender);
        users[msg.sender].amount += amount;
        totalStaked += amount;
        IERC20(stakingToken).safeTransferFrom(msg.sender, address(this), amount);
        
        // Notify factory about user staking (if first time in this pool)
        factory._addUserToPool(msg.sender);
        
        _updateMirror();
        emit Staked(msg.sender, amount);
    }

    function unstake() external nonReentrant {
        UserInfo storage u = users[msg.sender];
        require(u.amount > 0, "no-stake");
        
        // First accrue any pending rewards
        _accrue(msg.sender);
        
        uint256 stakeAmount = u.amount;
        uint256 claimableAmount = u.pending;
        
        // Reset user state
        u.amount = 0;
        u.pending = 0;
        if (claimableAmount > 0) {
            u.claimed += claimableAmount;
        }
        
        // Update pool totals
        totalStaked -= stakeAmount;
        if (claimableAmount > 0) {
            totalClaimed += claimableAmount;
            // Note: rewardReserve was already deducted during _accrue()
        }
        
        // Notify factory about user completely unstaking BEFORE external calls
        factory._removeUserFromPool(msg.sender);
        
        // Update mirror BEFORE external calls
        _updateMirror();
        
        // Transfer staked tokens back to user
        IERC20(stakingToken).safeTransfer(msg.sender, stakeAmount);
        
        // Transfer claimable rewards if any
        if (claimableAmount > 0) {
            IERC20(rewardToken).safeTransfer(msg.sender, claimableAmount);
            emit Claimed(msg.sender, claimableAmount);
        }
        emit Unstaked(msg.sender, stakeAmount);
    }

    function claim() external nonReentrant {
        _accrue(msg.sender); // Accrue rewards first, before checking expiration
        _checkAndUpdateActive(); // Auto-deactivate if expired or no rewards
        uint256 amt = users[msg.sender].pending;
        require(amt > 0, "no-claim");
        
        // Rewards are pre-allocated during accrual, so pending amount should always be claimable
        
        users[msg.sender].pending = 0;
        users[msg.sender].claimed += amt;
        totalClaimed += amt;
        // Note: rewardReserve was already deducted during _accrue()
        IERC20(rewardToken).safeTransfer(msg.sender, amt);
        _updateMirror();
        emit Claimed(msg.sender, amt);
    }

    // --------- Internals ---------

    function _accrue(address user) internal {
        UserInfo storage u = users[user];
        uint256 last = u.lastUpdate;
        uint256 nowTs = block.timestamp;
        if (last == 0) {
            u.lastUpdate = nowTs;
            return;
        }
        if (!active) {
            // When pool inactive, do not accrue beyond lastUpdate
            u.lastUpdate = nowTs; // still advance marker to avoid reprocessing past periods
            return;
        }
        if (u.amount == 0) {
            u.lastUpdate = nowTs;
            return;
        }
        uint256 dt = nowTs - last;
        if (dt == 0) return;
        // Cap accrual at endTime
        uint256 accrueUntil = nowTs > endTime ? endTime : nowTs;
        if (accrueUntil <= last) return;
        dt = accrueUntil - last;
        // reward = amount * apr% * dt / YEAR
        // Since staking and reward tokens are the same, no normalization needed
        // Use safe math to prevent overflow: (amount * aprBps * dt) / (BPS_DENOM * YEAR)
        uint256 reward = (u.amount * aprBps * dt) / (BPS_DENOM * YEAR);
        
        // Atomic operation to prevent race conditions in reward allocation
        if (rewardReserve >= reward) {
            u.pending += reward;
            rewardReserve -= reward; // Deduct from reserve as we allocate
        } else {
            // If insufficient reserves, allocate only what's available
            if (rewardReserve > 0) {
                u.pending += rewardReserve;
                rewardReserve = 0; // Use all remaining reserves
            }
        }
        
        u.lastUpdate = nowTs;
    }

    function _checkExpiration() internal {
        if (!active) return; // already inactive
        
        // Check if pool expired
        if (block.timestamp >= endTime) {
            active = false;
            emit ActiveSet(false);
        }
    }

    function _checkAndUpdateActive() internal {
        if (!active) return; // already inactive
        
        // Check if pool expired
        if (block.timestamp >= endTime) {
            active = false;
            emit ActiveSet(false);
        }
    }



    function _hasRewardReserves(uint256 amount) internal view returns (bool) {
        return rewardReserve >= amount;
    }

    function _updateMirror() internal {
        factory._mirror(totalStaked, totalClaimed, active);
    }

    // --------- Views ---------

    /// @notice Returns user's current stake data and live claimable reward
    function getUserStake(address user) external view returns (
        uint256 amount,
        uint256 claimable,
        uint256 claimed,
        uint256 lastClaimTs
    ) {
        UserInfo memory u = users[user];
        amount = u.amount;
        claimed = u.claimed;
        lastClaimTs = u.lastUpdate;
        // simulate accrue
        if (u.lastUpdate == 0 || u.amount == 0 || !active) {
            return (amount, u.pending, claimed, lastClaimTs);
        }
        uint256 accrueUntil = block.timestamp > endTime ? endTime : block.timestamp;
        if (accrueUntil <= u.lastUpdate) {
            return (amount, u.pending, claimed, lastClaimTs);
        }
        uint256 dt = accrueUntil - u.lastUpdate;
        // Since staking and reward tokens are the same, no normalization needed
        // Use safe math to prevent overflow: (amount * aprBps * dt) / (BPS_DENOM * YEAR)
        uint256 reward = (u.amount * aprBps * dt) / (BPS_DENOM * YEAR);
        claimable = u.pending + reward;
        return (amount, claimable, claimed, lastClaimTs);
    }

    /// @notice Detailed reward allocation analysis
    /// @return totalAllocated Total rewards initially allocated to pool
    /// @return totalDistributed Total rewards distributed to users  
    /// @return remainingRewards Remaining rewards in reserve
    /// @return distributedPercentage Percentage of rewards distributed (in basis points)
    /// @return remainingPercentage Percentage of rewards remaining (in basis points)
    function getRewardAnalysis() external view returns (
        uint256 totalAllocated,
        uint256 totalDistributed,
        uint256 remainingRewards,
        uint256 distributedPercentage,
        uint256 remainingPercentage
    ) {
        // Note: "totalAllocated" here represents claimed + remaining reserves.
        // It intentionally excludes rewards allocated to users' pending balances
        // (which have already been deducted from reserves during accrual).
        totalDistributed = totalClaimed;
        remainingRewards = rewardReserve;
        totalAllocated = totalDistributed + remainingRewards;
        
        if (totalAllocated == 0) {
            distributedPercentage = 0;
            remainingPercentage = 0;
        } else {
            // Calculate percentages in basis points (10000 = 100%)
            distributedPercentage = (totalDistributed * 10000) / totalAllocated;
            remainingPercentage = (remainingRewards * 10000) / totalAllocated;
        }
        
        return (totalAllocated, totalDistributed, remainingRewards, distributedPercentage, remainingPercentage);
    }

    /// @notice Convenience pool stats for UI
    function getPoolStats() external view returns (
        address _stakingToken,
        address _rewardToken,
        uint8 _stakingDecimals,
        uint8 _rewardDecimals,
        uint256 _aprBps,
        bool _active,
        uint256 _totalStaked,
        uint256 _totalClaimed,
        uint256 _rewardReserve,
        uint256 _endTime,
        bool _expired
    ) {
        _stakingToken = stakingToken;
        _rewardToken = rewardToken;
        _stakingDecimals = stakingDecimals;
        _rewardDecimals = rewardDecimals;
        _aprBps = aprBps;
        _active = active;
        _totalStaked = totalStaked;
        _totalClaimed = totalClaimed;
        _rewardReserve = rewardReserve;
        _endTime = endTime;
        _expired = block.timestamp >= endTime;
    }
}
