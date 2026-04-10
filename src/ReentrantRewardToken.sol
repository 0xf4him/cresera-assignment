// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IStakingClaim {
    function claimRewards() external;
}

contract ReentrantRewardToken is ERC20 {
    address public staking;
    bool public shouldReenter;
    bool private _entered;

    constructor() ERC20("Reentrant Reward", "RRT") {}

    function setStaking(address staking_) external {
        staking = staking_;
    }

    function setShouldReenter(bool enabled) external {
        shouldReenter = enabled;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (shouldReenter && !_entered && staking != address(0) && from == staking && to != address(0)) {
            _entered = true;
            IStakingClaim(staking).claimRewards();
            _entered = false;
        }
        super._update(from, to, value);
    }
}
