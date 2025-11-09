// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockERC721 - Minimal ERC721 mock for testing SuperMart
 * @notice Mints NFTs freely for fuzz and integration testing
 */
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

contract MockERC721 is ERC721 {
    uint256 public nextTokenId;

    constructor(string memory name, string memory symbol) ERC721(name, symbol) {}

    function mint(address to) external returns (uint256) {
        uint256 tokenId = ++nextTokenId;
        _mint(to, tokenId);
        return tokenId;
    }

    function mint(address to, uint256 tokenId) public {
        _mint(to, tokenId);
    }
}
