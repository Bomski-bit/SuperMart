// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/**
 * @title MockRevertingNFT
 * @notice Mock ERC721 token that reverts on transfers (for testing marketplace edge cases).
 * @dev Compatible with OpenZeppelin 5.x ERC721 implementation.
 */
contract MockRevertingNFT is ERC721 {
    error TransferReverted();

    constructor() ERC721("Mock Reverting NFT", "MRNFT") {}

    /**
     * @dev This override simulates a transfer failure by reverting when both `from` and `to` are nonzero.
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = _ownerOf(tokenId);

        // Allow mint (from == address(0)) and burn (to == address(0)), but revert on normal transfers.
        if (from != address(0) && to != address(0)) {
            revert TransferReverted();
        }

        // Call parent hook to maintain ERC721 logic
        return super._update(to, tokenId, auth);
    }

    /// @notice Simple mint helper for testing.
    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}
