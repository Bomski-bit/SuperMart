// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MockERC721} from "./MockERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title MockMaliciousRoyaltyNFT
 * @notice A "malicious" mock that *always* returns a royalty > salePrice.
 */
contract MockMaliciousRoyaltyNFT is MockERC721, IERC2981 {
    bytes4 private constant _INTERFACE_ID_ERC2981 = 0x2a55205a;
    address private _royaltyRecipient;

    constructor(address royaltyRecipient) MockERC721("Malicious NFT", "BAD") {
        _royaltyRecipient = royaltyRecipient;
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address receiver, uint256 royaltyAmount) {
        receiver = _royaltyRecipient;
        royaltyAmount = salePrice + 1 wei;
    }

    /**
     * @notice This function overrides the `supportsInterface` from two paths:
     * 1. ERC721 (which provides the implementation)
     * 2. IERC165 (which IERC2981 inherits from)
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, IERC165) returns (bool) {
        return interfaceId == _INTERFACE_ID_ERC2981 || super.supportsInterface(interfaceId);
    }
}
