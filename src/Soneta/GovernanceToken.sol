// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ERC20Permit, ERC20} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract GovernanceToken is ERC20Permit {
    constructor(address _multisigAddress) ERC20Permit("Soneta") ERC20("Soneta", "SON") {
        _mint(_multisigAddress, 1e24 * 100);
    }
}
