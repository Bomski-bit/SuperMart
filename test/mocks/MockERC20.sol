// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 *  @title MockERC20 - Minimal ERC20 mock for payment testing
 * @notice Used to simulate ERC20 transactions in SuperMart tests
 */
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint8 private _mockDecimals;

    // This accepts 3 arguments
    constructor(string memory name, string memory symbol, uint8 decimals_)
        // Pass 2 arguments to the ERC20 parent
        ERC20(name, symbol)
    {
        // Store the 3rd argument
        _mockDecimals = decimals_;
    }

    /**
     * @dev Overrides the decimals function to return our mock value.
     */
    function decimals() public view virtual override returns (uint8) {
        return _mockDecimals;
    }

    /// @notice Mint tokens for testing
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
