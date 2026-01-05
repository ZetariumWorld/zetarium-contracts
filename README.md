# Zetarium Contracts

A comprehensive Solidity smart contract suite for token staking and vesting sale platforms on EVM-compatible blockchains.

## Overview

This repository contains two main contract systems:

1. **StakingPlatform** - A factory contract that deploys staking pools where users can stake tokens and earn APR-based rewards calculated per-second
2. **VestingSalePlatform** - A factory contract that deploys token sale contracts with linear vesting schedules

Both platforms use a factory pattern where the main contract deploys child contracts for each pool/sale, enabling efficient gas usage and modular design.

## Contracts

### StakingPlatform

A factory contract that creates and manages staking pools. Each pool allows users to stake a token and earn rewards based on a configurable APR (Annual Percentage Rate).

#### Key Features

- **Factory Pattern**: Deploys individual `StakingPool` contracts for each staking opportunity
- **Per-Second APR Calculation**: Rewards are calculated per-second for precise accrual
- **Backend Signature Validation**: Pool creation requires backend validation signature
- **Quote-Based Staking**: Users can stake with backend-signed quotes for additional validation
- **Emergency Controls**: Factory owner can initiate emergency withdrawals with 24-hour timelock
- **User Tracking**: Tracks user participation across multiple pools
- **Reward Reserve System**: Pre-allocated reward reserves ensure reward availability

#### Main Functions

- `createPoolValidated()` - Create a new staking pool with backend signature validation
- `stake()` / `stakeWithQuote()` - Stake tokens (with optional quote validation)
- `unstake()` - Unstake all tokens and claim pending rewards
- `claim()` - Claim accrued rewards without unstaking
- `setActive()` - Pool owner can pause/resume rewards
- `setAprBps()` - Pool owner can update APR
- `fundRewards()` - Pool owner can add more reward tokens

#### Security Features

- Reentrancy protection on all external functions
- Signature-based validation for pool creation and staking
- Emergency withdrawal mechanism with timelock
- Protected user funds during emergency withdrawals

### VestingSalePlatform

A factory contract that creates token sale contracts with linear vesting schedules. Supports multiple payment currencies (ETH, USDT, USD1).

#### Key Features

- **Factory Pattern**: Deploys individual `VestingSale` contracts for each sale
- **Multiple Payment Currencies**: Supports native ETH, USDT, and USD1
- **Linear Vesting**: Tokens vest linearly over a configurable duration after sale ends
- **Backend Quote System**: Purchase requires backend-signed quote for pricing
- **Hard Cap Protection**: Sales automatically end when hard cap is reached
- **Platform Fee**: 1% fee on proceeds (configurable)
- **Early Sale End**: Sales can end early if hard cap is reached

#### Main Functions

- `createSaleValidated()` - Create a new sale with backend signature validation
- `buyWithQuote()` - Purchase tokens using backend-signed quote
- `claim()` - Claim vested tokens
- `withdrawProceeds()` - Project owner withdraws raised funds (after sale ends)
- `withdrawUnsoldTokens()` - Project owner withdraws unsold tokens

#### Security Features

- Reentrancy protection
- Sequential nonce system prevents signature replay attacks
- Chain ID included in signatures to prevent cross-chain replay
- Emergency withdrawal controls for factory owner

## Installation

### Prerequisites

- Node.js (v16+)
- npm or yarn
- Hardhat or Foundry (for compilation and testing)

### Setup

```bash
# Install dependencies
npm install

# Compile contracts
npx hardhat compile

# Run tests (if available)
npx hardhat test
```

## Usage

### StakingPlatform

#### Creating a Pool

```solidity
// Pool creator must:
// 1. Get backend signature for pool creation
// 2. Transfer initial reward tokens to factory
// 3. Call createPoolValidated with signature

stakingPlatform.createPoolValidated(
    stakingToken,
    aprBps,           // e.g., 500 for 5% APR
    endTime,          // Unix timestamp
    initialRewardAmount,
    deadline,         // Signature expiration
    signature         // Backend signature
);
```

#### Staking

```solidity
// Simple stake
stakingPool.stake(amount);

// Stake with quote (requires backend signature)
stakingPool.stakeWithQuote(
    amount,
    deadline,
    nonce,
    signature
);
```

#### Claiming Rewards

```solidity
// Claim accrued rewards
stakingPool.claim();

// Or unstake and claim together
stakingPool.unstake();
```

### VestingSalePlatform

#### Creating a Sale

```solidity
// Sale creator must:
// 1. Get backend signature for sale creation
// 2. Transfer hardCap tokens to factory
// 3. Pay creation fee
// 4. Call createSaleValidated

vestingSalePlatform.createSaleValidated{value: creationFee}(
    token,
    currency,         // PaymentCurrency.NATIVE, USDT, or USD1
    vestingDuration,  // e.g., 180 days
    hardCap,          // Total tokens to sell
    discount,         // Discount in basis points
    deadline,         // Signature expiration
    signature         // Backend signature
);
```

#### Purchasing Tokens

```solidity
// Purchase requires backend quote signature
vestingSale.buyWithQuote{value: paymentAmount}(
    paymentToken,      // address(0) for ETH
    paymentAmount,
    tokensOut,
    deadline,
    nonce,
    signature
);
```

#### Claiming Vested Tokens

```solidity
// Claim vested tokens (only after sale ends)
vestingSale.claim();
```

## Architecture

### Factory Pattern

Both platforms use a factory pattern:

- **Factory Contract**: Manages registry, metadata, and deployment
- **Child Contracts**: Individual pools/sales with their own state
- **Mirroring**: Child contracts update factory with lightweight stats

### Signature System

Both platforms use ECDSA signatures for:

- **Pool/Sale Creation**: Backend validates token/parameters before creation
- **Staking/Purchasing**: Backend provides pricing quotes via signatures

Signatures include:
- Chain ID (prevents cross-chain replay)
- User address (prevents signature reuse)
- Nonce (prevents replay attacks)
- Deadline (expiration protection)

## Security Considerations

### Audited Libraries

Both contracts use OpenZeppelin's audited libraries:
- `Ownable` - Access control
- `ReentrancyGuard` - Reentrancy protection
- `SafeERC20` - Safe token transfers
- `ECDSA` - Signature verification

### Best Practices

- Always verify signatures off-chain before submitting transactions
- Use sequential nonces to prevent replay attacks
- Monitor emergency withdrawal timelocks
- Validate all parameters before contract interactions

## Configuration

### StakingPlatform

- `poolCreationFee`: Default 0.002 ETH (configurable by owner)
- `EMERGENCY_DELAY`: 24 hours timelock for emergency withdrawals
- `MAX_APR`: 500% (50,000 basis points)

### VestingSalePlatform

- `saleCreationFee`: Default 0.002 ETH (configurable by owner)
- `FEE_BPS`: 100 basis points (1% platform fee)
- `defaultSaleDuration`: 180 days (6 months, configurable)

## Events

Both platforms emit comprehensive events for:
- Pool/Sale creation
- User actions (stake, purchase, claim)
- Admin actions (fee changes, emergency controls)
- State changes (active status, APR updates)

## License

MIT License - see LICENSE file for details

## Contributing

Contributions are welcome! Please ensure:
- Code follows Solidity style guide
- All functions have NatSpec documentation
- Tests are included for new features
- Security best practices are followed

## Support

For issues, questions, or contributions, please open an issue on GitHub.


Built on BNB Chain

