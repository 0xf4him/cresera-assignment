// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract MultiRewardStaking is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

 
    struct RewardSchedule {
        uint96 tokensPerSecond;
        uint32 endsAt;
        uint32 updatedAt;
        uint32 duration;
        // 64 free bits in this slot
        uint256 index;
    }


    uint256 private constant PRECISION = 1e18;

    IERC20 public immutable stakingToken;

    uint256 private _totalStaked;
    mapping(address => uint256) private _stakedBalances;

    address[] public rewardAssets;
    mapping(address => bool) public isRewardAsset;
    mapping(address => RewardSchedule) public rewardSchedules;

    mapping(address => mapping(address => uint256)) public userIndexPaid;
    /// @notice Accrued-but-unclaimed rewards per user per token.
    mapping(address => mapping(address => uint256)) public unclaimedRewards;


    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, address indexed rewardToken, uint256 amount);
    event RewardAssetAdded(address indexed rewardToken, uint256 duration);
    event RewardFunded(address indexed rewardToken, uint256 amount, uint256 endsAt);
    event RewardsDurationUpdated(address indexed rewardToken, uint256 newDuration);
    event Recovered(address indexed token, uint256 amount);

    error ZeroAmount();
    error ZeroAddress();
    error InsufficientBalance();
    error RewardTokenAlreadyAdded();
    error RewardTokenNotFound();
    error RewardTooHigh();
    error PeriodStillActive();
    error CannotRecoverActiveToken();

    constructor(address _stakingToken, address _owner) Ownable(_owner) {
        if (_stakingToken == address(0)) revert ZeroAddress();
        stakingToken = IERC20(_stakingToken);
    }

    function totalSupply() external view returns (uint256) {
        return _totalStaked;
    }

    function balanceOf(address account) external view returns (uint256) {
        return _stakedBalances[account];
    }

    /// @notice Last timestamp at which rewards for `token` are still accruing.
    function lastRewardTimestamp(address token) public view returns (uint256) {
        uint256 endsAt = rewardSchedules[token].endsAt;
        return block.timestamp < endsAt ? block.timestamp : endsAt;
    }

    function rewardPerToken(address token) public view returns (uint256) {
        RewardSchedule storage schedule = rewardSchedules[token];
        return _currentRewardIndex(schedule, lastRewardTimestamp(token), _totalStaked);
    }

    function earned(address account, address token) public view returns (uint256) {
        uint256 stakedBalance = _stakedBalances[account];
        uint256 indexDelta = rewardPerToken(token) - userIndexPaid[account][token];
        return (stakedBalance * indexDelta) / PRECISION + unclaimedRewards[account][token];
    }

    function pendingRewards(address account)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        uint256 rewardAssetCount = rewardAssets.length;
        tokens = new address[](rewardAssetCount);
        amounts = new uint256[](rewardAssetCount);
        for (uint256 i; i < rewardAssetCount;) {
            address rewardAsset = rewardAssets[i];
            tokens[i] = rewardAsset;
            amounts[i] = earned(account, rewardAsset);
            unchecked { ++i; }
        }
    }

    function pendingRewards(address account, address token) external view returns (uint256) {
        return earned(account, token);
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _checkpointAccount(msg.sender);

        unchecked {
            _totalStaked += amount;
            _stakedBalances[msg.sender] += amount;
        }

        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) public nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 stakedBalance = _stakedBalances[msg.sender];
        if (amount > stakedBalance) revert InsufficientBalance();
        _checkpointAccount(msg.sender);

        unchecked {
            _totalStaked -= amount;
            _stakedBalances[msg.sender] = stakedBalance - amount;
        }

        stakingToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claimRewards() external nonReentrant {
        address account = msg.sender;
        _checkpointAccount(account);

        uint256 rewardAssetCount = rewardAssets.length;
        for (uint256 i; i < rewardAssetCount;) {
            address rewardAsset = rewardAssets[i];
            uint256 payout = unclaimedRewards[account][rewardAsset];
            if (payout != 0) {
                unclaimedRewards[account][rewardAsset] = 0;
                IERC20(rewardAsset).safeTransfer(account, payout);
                emit RewardPaid(account, rewardAsset, payout);
            }
            unchecked { ++i; }
        }
    }

    function addRewardToken(address token, uint256 duration) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (isRewardAsset[token]) revert RewardTokenAlreadyAdded();
        if (duration == 0 || duration > type(uint32).max) revert ZeroAmount();

        isRewardAsset[token] = true;
        rewardAssets.push(token);
        rewardSchedules[token].duration = uint32(duration);

        emit RewardAssetAdded(token, duration);
    }

    /// @notice Update the emission duration of a reward token. Only allowed when
    ///         the current emission period has ended, to keep accounting sane.
    function setRewardsDuration(address token, uint256 duration) external onlyOwner {
        if (!isRewardAsset[token]) revert RewardTokenNotFound();
        if (block.timestamp <= rewardSchedules[token].endsAt) revert PeriodStillActive();
        if (duration == 0 || duration > type(uint32).max) revert ZeroAmount();

        rewardSchedules[token].duration = uint32(duration);
        emit RewardsDurationUpdated(token, duration);
    }

    /// @notice Fund a reward token with `amount` units to be distributed over its
    ///         configured duration. If called while a period is active, the leftover
    ///         is rolled into the new distribution (standard Synthetix pattern).
    function fundReward(address token, uint256 amount) external onlyOwner {
        if (!isRewardAsset[token]) revert RewardTokenNotFound();
        if (amount == 0) revert ZeroAmount();

        _checkpointGlobalIndex(token);

        RewardSchedule storage schedule = rewardSchedules[token];
        uint256 duration = schedule.duration;
        uint256 newTokensPerSecond;

        if (block.timestamp >= schedule.endsAt) {
            newTokensPerSecond = amount / duration;
        } else {
            uint256 secondsRemaining = schedule.endsAt - block.timestamp;
            uint256 undistributed = secondsRemaining * schedule.tokensPerSecond;
            newTokensPerSecond = (amount + undistributed) / duration;
        }

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (token == address(stakingToken)) {
            balance -= _totalStaked;
        }
        if (newTokensPerSecond > balance / duration) revert RewardTooHigh();
        if (newTokensPerSecond > type(uint96).max) revert RewardTooHigh();

        uint32 fundedAt = uint32(block.timestamp);
        uint256 endsAt = uint256(fundedAt) + duration;
        schedule.tokensPerSecond = uint96(newTokensPerSecond);
        schedule.updatedAt = fundedAt;
        schedule.endsAt = uint32(endsAt);

        emit RewardFunded(token, amount, endsAt);
    }


    /// @dev Settles every reward token's global index and the user's per-token snapshot.
    ///      This is the only place per-user state is written outside claim/stake/unstake.
    function _checkpointAccount(address account) private {
        uint256 rewardAssetCount = rewardAssets.length;
        uint256 stakedBalance = _stakedBalances[account];
        for (uint256 i; i < rewardAssetCount;) {
            address rewardAsset = rewardAssets[i];
            uint256 rewardIndex = _checkpointGlobalIndex(rewardAsset);
            // Snapshot user accrual.
            uint256 paidIndex = userIndexPaid[account][rewardAsset];
            if (rewardIndex != paidIndex) {
                if (stakedBalance != 0) {
                    unchecked {
                        unclaimedRewards[account][rewardAsset] += (stakedBalance * (rewardIndex - paidIndex)) / PRECISION;
                    }
                }
                userIndexPaid[account][rewardAsset] = rewardIndex;
            }
            unchecked { ++i; }
        }
    }

    function _checkpointGlobalIndex(address token) private returns (uint256 rewardIndex) {
        RewardSchedule storage schedule = rewardSchedules[token];
        uint256 currentTimestamp = lastRewardTimestamp(token);
        rewardIndex = _currentRewardIndex(schedule, currentTimestamp, _totalStaked);
        schedule.index = rewardIndex;
        schedule.updatedAt = uint32(currentTimestamp);
    }

    function _currentRewardIndex(
        RewardSchedule storage schedule,
        uint256 currentTimestamp,
        uint256 totalStaked
    ) private view returns (uint256) {
        uint256 storedIndex = schedule.index;
        if (totalStaked == 0) {
            return storedIndex;
        }

        uint256 updatedAt = schedule.updatedAt;
        if (currentTimestamp <= updatedAt) {
            return storedIndex;
        }

        unchecked {
            uint256 indexDelta = (currentTimestamp - updatedAt) * schedule.tokensPerSecond * PRECISION / totalStaked;
            return storedIndex + indexDelta;
        }
    }
}
