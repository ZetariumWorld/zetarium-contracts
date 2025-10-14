# Zetarium Smart Contracts

**Decentralized Staking and Bond Platform on BNB Chain (BSC)**

Zetarium smart contracts provide a secure, flexible, and user-friendly infrastructure for creating decentralized staking pools and token bond sales on Binance Smart Chain. Built with security-first principles and optimized for gas efficiency.

## 📋 Table of Contents

- [Overview](#-overview)
- [Contracts](#-contracts)
  - [StakingPlatform](#stakingplatform)
  - [VestingSalePlatform](#vestingsaleplatform)
- [Key Features](#-key-features)
- [Security Features](#-security-features)
- [Technical Specifications](#-technical-specifications)
- [Contract Architecture](#-contract-architecture)
- [Deployment](#-deployment)
- [Usage Examples](#-usage-examples)
- [Audits & Security](#-audits--security)
- [License](#-license)

---

## 🌟 Overview

Zetarium smart contracts consist of two primary systems designed to empower DeFi projects and users on BNB Chain:

1. **Staking Platform** - Factory-based staking pool system with APR rewards
2. **Vesting Sale Platform** - Token bond/sale system with linear vesting

Both platforms use a factory pattern for scalability, allowing anyone to create and manage their own pools/sales with minimal setup while maintaining security and transparency.

---

## 📦 Contracts

### StakingPlatform

A comprehensive staking solution that enables projects to create their own staking pools with customizable parameters.

#### **Core Features:**
- ✅ **Factory Pattern** - Deploy unlimited staking pools
- ✅ **Flexible APR** - Customizable annual percentage rate (up to 500%)
- ✅ **Per-Second Rewards** - Precise reward calculation
- ✅ **Time-Bounded Pools** - Set pool duration (1-365 days)
- ✅ **Emergency Controls** - 24-hour timelock for emergency withdrawals
- ✅ **User Tracking** - Real-time tracking of active stakes
- ✅ **Pool Discovery** - Query pools by range, owner, or user participation

#### **Smart Contract Components:**

**StakingPlatform (Factory)**
- Pool creation and registry
- User participation tracking
- Emergency withdrawal controls
- Treasury management
- Fee collection (0.002 BNB default)

**StakingPool (Child Contract)**
- Stake/unstake functionality
- Automated reward accrual
- Claim rewards
- Pool statistics and analytics
- Reward reserve management

#### **Key Parameters:**
```solidity
- poolCreationFee: 0.002 BNB (configurable)
- aprBps: Basis points (e.g., 500 = 5% APR, max 50000 = 500%)
- duration: 1 day to 365 days
- EMERGENCY_DELAY: 24 hours
```

---

### VestingSalePlatform

A secure token sale platform with built-in vesting mechanism, perfect for token launches, bond offerings, and fundraising.

#### **Core Features:**
- ✅ **Multi-Currency Support** - Accept BNB, USDT, or custom stablecoins
- ✅ **Off-Chain Quote Signing** - Secure price oracles via ECDSA signatures
- ✅ **Linear Vesting** - Daily unlock schedule post-sale
- ✅ **Hard Cap Protection** - Automatic sale termination
- ✅ **Discount Mechanism** - Configurable discount (0-100%)
- ✅ **1% Platform Fee** - Transparent fee structure
- ✅ **Emergency Controls** - Factory owner safety mechanisms
- ✅ **Nonce Protection** - Prevent replay attacks

#### **Smart Contract Components:**

**VestingSalePlatform (Factory)**
- Sale creation and registry
- User participation tracking
- Quote signer management
- Fee collection and distribution
- Emergency withdrawal controls

**VestingSale (Child Contract)**
- Purchase with signed quotes
- Linear vesting mechanism
- Claim vested tokens
- Proceeds withdrawal
- Unsold token recovery

#### **Key Parameters:**
```solidity
- saleCreationFee: 0.002 BNB (configurable)
- defaultSaleDuration: 180 days (configurable)
- platformFee: 1% (100 basis points)
- vestingDuration: Minimum 1 day
- discount: 0-10000 basis points (0-100%)
```

---

## 🎯 Key Features

### Factory Pattern Architecture
Both platforms use factory contracts to deploy child contracts, enabling:
- Unlimited pool/sale creation
- Centralized registry and discovery
- Consistent security model
- Efficient gas usage
- Easy upgradability through new factories

### Real-Time Reward Calculation
StakingPlatform calculates rewards per-second with high precision:
```
Reward = (stakedAmount × aprBps × timeElapsed) / (10000 × 365 days)
```

### Secure Quote System
VestingSalePlatform uses ECDSA signature verification:
- Off-chain price calculation
- On-chain signature verification
- Nonce-based replay protection
- Chain ID validation
- Deadline enforcement

### Comprehensive User Tracking
- Track user participation across all pools/sales
- Query active stakes per user
- Historical claim data
- Pool/sale discovery by owner

---

## 🔐 Security Features

### Reentrancy Protection
- All critical functions protected with `ReentrancyGuard`
- SafeERC20 for all token transfers
- Checks-Effects-Interactions pattern

### Access Control
- OpenZeppelin `Ownable` for admin functions
- Multi-level access: Factory owner, Pool/Sale owner
- Emergency controls with timelock

### Emergency Mechanisms
**StakingPlatform:**
- 24-hour timelock before emergency withdrawal
- Protected user funds (staked + reserved rewards)
- Only excess tokens withdrawable
- Cancellable emergency withdrawals

**VestingSalePlatform:**
- Factory owner emergency controls
- Separate ETH and ERC20 withdrawal functions
- Protected user allocations

### Input Validation
- Range checks on all numeric inputs
- Zero address validation
- Duration limits (1-365 days)
- APR caps (max 500%)
- Discount limits (max 100%)

### Overflow Protection
- Solidity 0.8.24+ built-in overflow checks
- Safe mathematical operations
- Precise decimal handling

---

## 🛠 Technical Specifications

### Blockchain
- **Network**: Binance Smart Chain (BSC)
- **Chain ID**: 56 (Mainnet) / 97 (Testnet)
- **Standard**: BEP-20 (ERC-20 compatible)

### Solidity Version
- **Compiler**: `^0.8.24`
- **Optimization**: Enabled (200 runs recommended)

### Dependencies
```json
{
  "@openzeppelin/contracts": "^5.0.0"
}
```

**OpenZeppelin Contracts Used:**
- `Ownable` - Access control
- `ReentrancyGuard` - Reentrancy protection
- `IERC20` / `IERC20Metadata` - Token interfaces
- `SafeERC20` - Safe token operations
- `ECDSA` / `MessageHashUtils` - Signature verification

### Gas Optimization
- Immutable variables where applicable
- Efficient storage packing
- Minimal SLOAD operations
- Batch operations support

---

## 🏗 Contract Architecture

### StakingPlatform Flow

```
User → StakingPlatform.createPool() 
         ↓
     Deploys StakingPool
         ↓
User → StakingPool.stake()
         ↓
     Accrues rewards per-second
         ↓
User → StakingPool.claim() / unstake()
```

### VestingSalePlatform Flow

```
Project → VestingSalePlatform.createSale()
            ↓
        Deploys VestingSale
            ↓
Backend → Signs purchase quote
            ↓
User → VestingSale.buyWithQuote()
            ↓
       Sale ends (time/hardcap)
            ↓
User → VestingSale.claim() (linear vesting)
            ↓
Project → VestingSale.withdrawProceeds()
```

---

## 🚀 Deployment

### Prerequisites
```bash
npm install @openzeppelin/contracts
```

### Deployment Order

**1. StakingPlatform**
```solidity
constructor(address _treasury)
```
Parameters:
- `_treasury`: Address to receive pool creation fees

**2. VestingSalePlatform**
```solidity
constructor(address _treasury, address _usdt, address _usd1)
```
Parameters:
- `_treasury`: Address to receive fees
- `_usdt`: USDT token address (or zero)
- `_usd1`: Custom stablecoin address (or zero)

Post-deployment:
```solidity
// Set quote signer for VestingSalePlatform
vestingSalePlatform.setQuoteSigner(signerAddress);
```

### Network Addresses

**BSC Mainnet:**
```
StakingPlatform: [To be deployed]
VestingSalePlatform: [To be deployed]
```

**BSC Testnet:**
```
StakingPlatform: [To be deployed]
VestingSalePlatform: [To be deployed]
```

---

## 💡 Usage Examples

### Creating a Staking Pool

```solidity
// Approve reward tokens first
IERC20(rewardToken).approve(stakingPlatform, initialRewardAmount);

// Create pool
(uint256 poolId, address poolAddress) = stakingPlatform.createPool{value: 0.002 ether}(
    stakingToken,        // Address of token to stake
    500,                 // APR in basis points (5%)
    90 days,             // Pool duration
    1_000_000 * 1e18     // Initial reward amount
);
```

### Staking Tokens

```solidity
// Approve staking tokens
IERC20(stakingToken).approve(poolAddress, amount);

// Stake
StakingPool(poolAddress).stake(amount);

// Check rewards
(uint256 staked, uint256 claimable, uint256 claimed, uint256 lastUpdate) = 
    StakingPool(poolAddress).getUserStake(userAddress);

// Claim rewards
StakingPool(poolAddress).claim();

// Unstake (claims rewards + returns stake)
StakingPool(poolAddress).unstake();
```

### Creating a Token Sale

```solidity
// Create sale
(uint256 saleId, address saleAddress) = vestingSalePlatform.createSale{value: 0.002 ether}(
    tokenAddress,           // Token being sold
    PaymentCurrency.NATIVE, // Accept BNB
    90 days,                // Vesting duration
    10_000_000 * 1e18,      // Hard cap
    500                     // 5% discount
);

// Fund sale with tokens
IERC20(tokenAddress).transfer(saleAddress, amount);
```

### Purchasing with Quote

```javascript
// Backend signs quote
const message = ethers.utils.solidityKeccak256(
    ['uint256', 'address', 'address', 'address', 'uint256', 'uint256', 'uint256', 'uint256'],
    [chainId, saleAddress, buyer, paymentToken, paymentAmount, tokensOut, deadline, nonce]
);
const signature = await signer.signMessage(ethers.utils.arrayify(message));

// User purchases
await vestingSale.buyWithQuote(
    paymentToken,
    paymentAmount,
    tokensOut,
    deadline,
    nonce,
    signature,
    { value: paymentAmount } // if BNB
);
```

### Claiming Vested Tokens

```solidity
// Check claimable amount
uint256 claimableAmount = VestingSale(saleAddress).claimable(userAddress);

// Claim
VestingSale(saleAddress).claim();
```

---

## 📊 View Functions

### StakingPlatform Views

```solidity
// Pool discovery
totalPools() → uint256
getPoolsInRange(fromId, toId) → PoolMeta[]
getPoolByIndex(poolId) → PoolMeta
getOwnerPoolIds(owner) → uint256[]
getUserActivePools(user) → uint256[]

// Pool stats
StakingPool.getPoolStats() → (...)
StakingPool.getUserStake(user) → (amount, claimable, claimed, lastUpdate)
StakingPool.getRewardAnalysis() → (totalAllocated, distributed, remaining, ...)
```

### VestingSalePlatform Views

```solidity
// Sale discovery
totalSales() → uint256
getSalesInRange(fromId, toId) → Sale[]
getSaleByIndex(saleId) → Sale
getUserSaleIds(user) → uint256[]

// Sale data
VestingSale.getBuyerInfo(user) → (PurchaseInfo, pending)
VestingSale.vestedAmount(user) → uint256
VestingSale.claimable(user) → uint256
VestingSale.isActive() → bool
VestingSale.hasEnded() → bool
```

---

## 🔍 Audits & Security

### Security Measures Implemented
- ✅ Reentrancy guards on all state-changing functions
- ✅ SafeERC20 for token operations
- ✅ Access control with OpenZeppelin Ownable
- ✅ Emergency withdrawal timelocks
- ✅ Input validation and bounds checking
- ✅ Nonce-based replay attack prevention
- ✅ Chain ID validation for signatures
- ✅ Protected user funds in emergency scenarios

### Recommended Security Practices
1. **Audit**: Get contracts audited by reputable firms before mainnet deployment
2. **Testing**: Comprehensive unit and integration tests
3. **Testnet**: Deploy and test thoroughly on BSC testnet
4. **Monitoring**: Monitor contracts for unusual activity post-deployment
5. **Multisig**: Use multisig wallets for factory ownership
6. **Upgradability**: Consider proxy patterns for critical parameters

### Known Limitations
- Quote signer private key must be secured (VestingSalePlatform)
- Pool creators must fund reward reserves adequately (StakingPlatform)
- Emergency withdrawals require 24-hour timelock (StakingPlatform)

---

## 🌐 Integration

### Frontend Integration

**Web3 Libraries:**
- Viem 2.37+ (recommended)
- Wagmi 2.17+ (React hooks)
- Ethers.js 6.x (alternative)

**Example with Viem:**
```typescript
import { createPublicClient, http } from 'viem';
import { bsc } from 'viem/chains';

const client = createPublicClient({
  chain: bsc,
  transport: http()
});

// Read pool stats
const poolStats = await client.readContract({
  address: poolAddress,
  abi: StakingPoolABI,
  functionName: 'getPoolStats'
});
```

---

## 📝 Events

### StakingPlatform Events
```solidity
event PoolCreated(uint256 indexed poolId, address indexed poolAddress, ...);
event PoolMirrored(uint256 indexed poolId, uint256 totalStaked, ...);
event EmergencyInitiated(uint256 indexed poolId, uint256 executeAfter);
event EmergencyExecuted(uint256 indexed poolId);
event Staked(address indexed user, uint256 amount);
event Unstaked(address indexed user, uint256 amount);
event Claimed(address indexed user, uint256 amount);
```

### VestingSalePlatform Events
```solidity
event SaleCreated(uint256 indexed saleId, address indexed saleAddress, ...);
event Purchased(uint256 indexed saleId, address indexed buyer, ...);
event Claimed(uint256 indexed saleId, address indexed buyer, uint256 claimedAmount);
event ProceedsWithdrawn(uint256 indexed saleId, address indexed projectOwner, ...);
event EndedEarly(uint256 when);
```

---

## 🤝 Contributing

This is a production-ready smart contract system. For improvements or bug reports:

1. Review the code thoroughly
2. Create detailed issue reports
3. Propose changes via pull requests
4. Include comprehensive tests

---

## 📄 License

```
SPDX-License-Identifier: MIT
```

This project is licensed under the MIT License. See the LICENSE file for details.

---

## 📞 Contact & Links

- **Website**: [https://zetarium.world](https://zetarium.world)
- **Documentation**: [https://whitepaper.zetarium.world](https://whitepaper.zetarium.world)
- **Twitter**: [@Zetarium](https://twitter.com/zetarium_)
- **GitHub**: [Zetarium Contracts](https://github.com/ZetariumWorld)

---

## ⚠️ Disclaimer

These smart contracts are provided as-is. While built with security best practices:

- **Not Audited**: Contracts have not been audited by third-party security firms
- **Use at Own Risk**: Users and projects deploy/interact at their own risk
- **No Warranty**: No guarantees of fitness for any particular purpose
- **DeFi Risks**: All DeFi platforms carry inherent risks including smart contract bugs, economic attacks, and market volatility

**Recommendations:**
- Conduct thorough testing before mainnet deployment
- Obtain professional security audits
- Use testnet for initial deployment and testing
- Start with small amounts to verify functionality
- Never invest more than you can afford to lose

---

## 🔧 Contract Addresses

### BSC Mainnet (Chain ID: 56)
```
StakingPlatform:        [Pending Deployment]
VestingSalePlatform:    [Pending Deployment]
Treasury:               [To Be Announced]
```

### BSC Testnet (Chain ID: 97)
```
StakingPlatform:        [Pending Deployment]
VestingSalePlatform:    [Pending Deployment]
Treasury:               [To Be Announced]
```

---

## 📚 Additional Resources

### Documentation
- [Solidity Documentation](https://docs.soliditylang.org/)
- [OpenZeppelin Contracts](https://docs.openzeppelin.com/contracts/)
- [BNB Chain Developer Docs](https://docs.bnbchain.org/)

### Tools
- [Remix IDE](https://remix.ethereum.org/)
- [Hardhat](https://hardhat.org/)
- [BSCScan](https://bscscan.com/)

---

**Built with ❤️ for the BNB Chain ecosystem**

*Empowering decentralized finance through secure, flexible, and user-friendly smart contracts.*

