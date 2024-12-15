// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

contract MockStaking {
    mapping(address => uint256) public stakeTracker;

    function stake(uint256 _amount) external {
        stakeTracker[msg.sender] += _amount;
    }

    function unstake(uint256 _amount) external {
        stakeTracker[msg.sender] -= _amount;
    }

    function stakes(address _user) external view returns (uint256) {
        return stakeTracker[_user];
    }
}
