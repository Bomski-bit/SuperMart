// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SuperMart} from "../../src/SuperMart.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Handler} from "./Handler.sol";

/**
 * @title Invariant Tests for SuperMart NFT Marketplace
 * @notice This contract defines the core "rules" or "invariants" of the SuperMart marketplace.
 * @dev These invariants are checked by Foundry's stateful fuzzer.
 * The fuzzer will call functions on the `Handler` contract in a
 * random sequence, and after each call, it will check that
 * every function starting with `invariant_` still holds true.
 *
 * Key Invariants:
 * 1.  **ETH Accounting:** The marketplace's ETH balance must
 * perfectly match the sum of all active ETH bids and pending withdrawals.
 * 2.  **ERC20 Accounting:** The marketplace's ERC20 balance must
 * perfectly match the sum of all active ERC20 bids and pending withdrawals.
 * 3.  **No Trapped NFTs:** The marketplace should never own any NFTs.
 * 4.  **State Exclusivity:** An NFT cannot be in a fixed-price
 * listing and an auction at the same time.
 * 5.  **Fee Sanity:** The platform fee can never be set
 * higher than the contract's defined maximum (2000).
 */
contract SuperMartInvariantTest is StdInvariant, Test {
    // === State Variables ===

    SuperMart internal marketplace;
    Handler internal handler;
    MockERC721 internal nft;
    MockERC20 internal erc20;

    // === Setup ===

    function setUp() public {
        // 1. Deploy the marketplace with a 5% (500) fee
        marketplace = new SuperMart(500);

        // 2. Deploy Mock Contracts
        nft = new MockERC721("Test NFT", "TNFT");
        erc20 = new MockERC20("Test Token", "TKN", 18);

        // 3. Deploy the Handler
        // We pass the newly created contracts into its constructor
        handler = new Handler(marketplace, nft, erc20);

        // 4. Add the ownership transfer here ---
        // The test contract (the current owner) calls transferOwnership
        // and passes in the public OWNER address from the handler.
        marketplace.transferOwnership(handler.OWNER());

        // 5. Point Foundry's invariant fuzzer to the Handler contract.
        targetContract(address(handler));
    }

    // === Invariants ===

    /**
     * @notice INVARIANT: The contract's ETH balance must *always* be greater than or equal
     * the sum of all pending ETH withdrawals + all active ETH bids.
     * @dev This ensures no ETH is lost by the contract.
     */
    function invariant_ethAccounting() public view {
        uint256 totalPendingETH = handler.totalPendingETHWithdrawals();
        uint256 totalActiveETHBids = handler.totalActiveETHBids();
        uint256 contractBalance = address(marketplace).balance;

        assertGe(contractBalance, totalPendingETH + totalActiveETHBids, "ETH Accounting Invariant Violated");
    }

    /**
     * @notice INVARIANT: The contract's ERC20 balance must *always* be greater than or equal
     * the sum of all pending ERC20 withdrawals + all active ERC20 bids.
     * @dev This ensures no ERC20 tokens are lost.
     */
    function invariant_erc20Accounting() public view {
        address tokenAddress = address(erc20);

        uint256 totalPending = handler.totalPendingERC20Withdrawals(tokenAddress);
        uint256 totalActive = handler.totalActiveERC20Bids(tokenAddress);
        uint256 contractBalance = erc20.balanceOf(address(marketplace));

        assertGe(contractBalance, totalPending + totalActive, "ERC20 Accounting Invariant Violated");
    }

    /**
     * @notice INVARIANT: The marketplace contract should *never* own any NFTs.
     * @dev It operates via approvals, so the NFT balance should always be 0.
     * If this fails, an NFT is trapped in the contract.
     */
    function invariant_noContractOwnedNFTs() public view {
        assertEq(nft.balanceOf(address(marketplace)), 0, "NFT Trapped Invariant Violated");
    }

    /**
     * @notice INVARIANT: An NFT cannot be in a fixed-price listing
     * and an auction at the same time.
     * @dev This checks the internal state of our *handler* (which mirrors
     * the contract) to ensure this exclusivity rule is never broken.
     */
    function invariant_stateExclusivity() public view {
        // We check across a bounded number of token IDs that the fuzzer interacts with
        uint256 numTokenIdsToTest = handler.fuzzTokenIdRange();
        for (uint256 i = 0; i < numTokenIdsToTest; i++) {
            if (handler.s_isListed(i) && handler.s_isAuctioned(i)) {
                revert("State Exclusivity Invariant Violated");
            }
        }
    }

    /**
     * @notice INVARIANT: The platform fee can never exceed the max (2000).
     * @dev This confirms the `updatePlatformFee` setter logic is correct.
     */
    function invariant_platformFeeIsSane() public view {
        (, uint256 feePercent) = marketplace.getPlatformFeeInfo();
        assertTrue(
            feePercent <= 2000, // 2000 is _MAX_PLATFORM_FEE
            "Fee Sanity Invariant Violated"
        );
    }
}
