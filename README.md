# Cresera Assignment

## Multi-Reward ERC-20 Staking

This repository contains a gas-conscious staking contract where users deposit a
single ERC-20 token and earn rewards in one or more ERC-20 reward tokens. Each
reward token can run on its own emission schedule and duration, while user
accounting stays constant-time with respect to the number of stakers.

The implementation lives in [src/MultiRewardStaking.sol](/Users/f4him/cresera-staking/src/MultiRewardStaking.sol) and is supported by Hardhat tests in [test/MultiRewardStaking.test.js](/Users/f4him/cresera-staking/test/MultiRewardStaking.test.js).

## Stack

- Solidity `0.8.24`
- Hardhat
- OpenZeppelin Contracts
- Chai / Ethers test tooling

## Repository Layout

- [src/MultiRewardStaking.sol](/Users/f4him/cresera-staking/src/MultiRewardStaking.sol): main staking contract
- [src/MockERC20.sol](/Users/f4him/cresera-staking/src/MockERC20.sol): test token used in fixtures
- [src/ReentrantRewardToken.sol](/Users/f4him/cresera-staking/src/ReentrantRewardToken.sol): helper used to probe reentrancy behavior
- [test/MultiRewardStaking.test.js](/Users/f4him/cresera-staking/test/MultiRewardStaking.test.js): core behavior and edge-case tests
- [scripts/deploy.js](/Users/f4him/cresera-staking/scripts/deploy.js): deployment entry point
- [scripts/compile-check.js](/Users/f4him/cresera-staking/scripts/compile-check.js): lightweight compile validation through `solc`

## Core Design

### 1. Reward Accounting

The contract uses the standard cumulative reward-index pattern. For every reward
token, a global `index` value tracks how much reward has accrued
per staked token over time. Each user stores the last reward index they were
settled against.

At a high level:

```text
earned(user, token)
= user balance * (global reward index - user snapshot) / 1e18
+ previously accrued rewards
```

That design means:

- no iteration over users
- `stake`, `unstake`, and `claimRewards` only touch caller state
- gas cost depends on the number of configured reward tokens, not on the number
  of stakers

### 2. Multiple Reward Tokens

Each reward token has isolated configuration in `RewardSchedule`:

- `tokensPerSecond`
- `endsAt`
- `updatedAt`
- `duration`
- `index`

The owner can register reward tokens with `addRewardToken(...)` and fund them
through `fundReward(...)`.

If funding happens while a reward period is still active, leftover emissions are
rolled into the next schedule instead of being discarded. This matches the
common Synthetix-style top-up pattern.

### 3. Edge-Case Behavior

- Late joiners do not receive rewards emitted before they stake.
- If total supply is zero, the reward index does not advance and those idle
  emissions are effectively forfeited.
- Partial unstaking preserves already-earned rewards because reward state is
  settled before balances change.

## Gas-Oriented Choices

The contract is intentionally optimized for the hot paths:

- reward schedule state is storage-packed to reduce slot reads and writes.
- `stakingToken` is immutable.
- loops use `unchecked { ++i; }` where safe.
- custom errors are used instead of revert strings.
- per-user reward writes are skipped when no new accrual exists.
- account stake is cached once during reward checkpointing instead of being
  reloaded for each reward token.
- `unstake` caches the sender balance before mutation.

The main gas tradeoff is straightforward: user actions scale linearly with
`rewardAssets.length`, so the reward-token set should stay reasonably small.

## Security Notes

### Reentrancy

- `stake`
- `unstake`
- `claimRewards`

are all protected by `nonReentrant`.

The contract also follows checks-effects-interactions ordering before token
transfers.

### Reward Solvency

When a reward period is funded, the contract verifies that the balance is large
enough to sustain the computed emission rate for the full duration. If the reward
token is the same asset as the staking token, staked principal is excluded from
that solvency calculation.

### Admin Capabilities

The owner can:

- add reward tokens
- fund reward schedules
- update reward duration after a period has ended

The owner cannot, through the exposed staking API:

- seize user stake
- rewrite user balances
- arbitrarily rewrite user reward snapshots

Ownership transfer uses `Ownable2Step`.

## Local Setup

Install dependencies:

```bash
npm install
```

Run the test suite:

```bash
npm test
```

Run the lightweight compile check:

```bash
npm run verify
```

Run the deployment script:

```bash
npm run deploy
```

## Test Coverage

The current test suite covers:

- zero-value stake protection
- over-unstake protection
- late joiner reward distribution
- zero-supply intervals
- leftover reward rollover on top-up
- duplicate reward token rejection
- unknown reward token funding rejection
- duration updates only after a period ends
- reentrancy resistance during reward claims

## Scalability

This design already scales to large user counts because user state is updated on
demand. Whether there are 10 users or 10,000 users, the contract does not loop
through the user set. The limiting factor is the number of reward tokens, not
the number of active stakers.

## Assumptions

- staking and reward assets are standard ERC-20 tokens
- fee-on-transfer and rebasing assets are out of scope
- reward-token contracts are trusted by the owner when registered
- timestamp-level drift is acceptable for reward distribution windows
