// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";

/**
 * @title MockRoyaltyNFT
 * @notice Mock ERC721 token with built-in EIP-2981 royalty support for testing.
 * @dev Compatible with OpenZeppelin 5.x ERC721 and ERC2981 implementations.
 *      - Provides a mint helper that auto-increments token IDs.
 *      - Stores the default royalty receiver in state so tests can update fee only.
 *      - Exposes `setRoyalty(uint96)` to change the default royalty numerator easily.
 */
contract MockRoyaltyNFT is ERC721, ERC2981 {
    uint256 private _nextTokenId;

    /// @notice The address receiving default royalty payments (kept for helper usage)
    address public defaultRoyaltyReceiver;

    /**
     * @param defaultReceiver The address to receive default royalties.
     * @param defaultRoyaltyFeeNumerator The default royalty in basis points (e.g., 500 = 5%).
     */
    constructor(address defaultReceiver, uint96 defaultRoyaltyFeeNumerator) ERC721("Mock Royalty NFT", "MRN") {
        require(defaultReceiver != address(0), "zero royalty receiver");
        defaultRoyaltyReceiver = defaultReceiver;
        _setDefaultRoyalty(defaultReceiver, defaultRoyaltyFeeNumerator);
    }

    /**
     * @notice Mint a new token to `to`. Token IDs are auto-incremented.
     * @param to The recipient of the minted token.
     * @return tokenId The minted token id.
     */
    function mint(address to) external returns (uint256 tokenId) {
        tokenId = ++_nextTokenId;
        _mint(to, tokenId);
    }

    /**
     * @notice Convenience helper for tests: update the default royalty fee while keeping the same receiver.
     * @dev Uses stored `defaultRoyaltyReceiver`. If you want to change receiver too, call
     *      `setDefaultRoyalty(receiver, feeNumerator)` directly (inherited internal function).
     * @param newFeeNumerator New royalty numerator (basis points).
     */
    function setRoyalty(uint96 newFeeNumerator) external {
        // Keep the same receiver and update the default royalty info
        // If tests want to change both receiver and fee, call setDefaultRoyaltyReceiverAndFee below.
        require(defaultRoyaltyReceiver != address(0), "no default receiver set");
        _setDefaultRoyalty(defaultRoyaltyReceiver, newFeeNumerator);
    }

    /**
     * @notice Optional helper: change both receiver and fee at once.
     * @param newReceiver The new royalty receiver address.
     * @param newFeeNumerator The new royalty numerator (basis points).
     */
    function setDefaultRoyaltyReceiverAndFee(address newReceiver, uint96 newFeeNumerator) external {
        require(newReceiver != address(0), "zero receiver");
        defaultRoyaltyReceiver = newReceiver;
        _setDefaultRoyalty(newReceiver, newFeeNumerator);
    }

    /**
     * @notice Standard supportsInterface override combining ERC721 and ERC2981.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Expose _update override in case parent requires it. We simply delegate to parent.
     *      This keeps compatibility with OZ v5's internal hook system.
     */
    function _update(address to, uint256 tokenId, address auth) internal virtual override(ERC721) returns (address) {
        return super._update(to, tokenId, auth);
    }
}
