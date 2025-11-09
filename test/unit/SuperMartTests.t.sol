// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SuperMart} from "../../src/SuperMart.sol";

import {MockERC721} from "../mocks/MockERC721.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockRoyaltyNFT} from "../mocks/MockRoyaltyNFT.sol";
import {MockRevertingNFT} from "../mocks/MockRevertingNFT.sol";
import {MockMaliciousRoyaltyNFT} from "../mocks/MockMaliciousRoyaltyNFT.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// ---------------------------------------------------------------------------
/// Test Contract
/// ---------------------------------------------------------------------------

/**
 * @title SuperMartTests
 * @notice Comprehensive Foundry test suite for the `SuperMart` NFT marketplace.
 * @dev This contract validates core functionalities of the SuperMart marketplace including:
 *      - Admin operations (ownership, fee updates, pausing/unpausing)
 *      - Fixed-price listings and purchases (ETH + ERC20)
 *      - Royalties and platform fee distributions
 *      - Auction mechanisms (ETH & ERC20)
 *      - Withdrawals and refund flows
 *      - Edge cases and revert conditions
 *
 * ### Design Notes
 * - Tests use `MockERC721`, `MockERC20`, `MockRoyaltyNFT`, and `MockRevertingNFT`
 *   for controlled, deterministic simulations of different marketplace behaviors.
 * - The test suite mirrors all key SuperMart events, ensuring that
 *   `vm.expectEmit` checks are precise and signature-compatible.
 * - Constants define consistent actors and price points for reproducibility.
 * - The `setUp()` function ensures fresh deployment and funded test accounts before each run.
 *
 * ### Test Categories
 * 1. **Admin Tests** — Ownership, fee management, and pause functionality.
 * 2. **Listings & Purchases** — Fixed-price ETH and ERC20 payments, royalty routing.
 * 3. **Auctions** — Bidding, outbids/refunds, and auction termination.
 * 4. **Withdrawals** — Pending ETH and ERC20 withdrawals.
 * 5. **Edge Cases & Reverts** — Invalid inputs, unauthorized calls, timing violations.
 *
 * @author Boma
 */
contract SuperMartTests is Test {
    // -----------------------------------------------------------------------
    // Event declarations (mirrors SuperMart events)
    // -----------------------------------------------------------------------
    // Declaring them allows `vm.expectEmit` then `emit Event(...)` in tests.
    // If the signatures don't match exactly with SuperMart, the event assertion will fail.
    event ItemListed(
        address indexed seller,
        address indexed nftContract,
        uint256 indexed tokenId,
        address paymentToken,
        uint256 price
    );
    event ListingCancelled(address indexed seller, address indexed nftContract, uint256 indexed tokenId);
    event ItemSold(
        address indexed seller, address indexed buyer, address indexed nftContract, uint256 tokenId, uint256 price
    );
    event AuctionCreated(
        address indexed seller,
        address indexed nftContract,
        uint256 indexed tokenId,
        address paymentToken,
        uint256 startingBid,
        uint256 endTime
    );
    event NewBid(address indexed bidder, address indexed nftContract, uint256 indexed tokenId, uint256 amount);
    event AuctionHasEnded(
        address indexed winner, address indexed seller, address indexed nftContract, uint256 tokenId, uint256 amount
    );
    event WithdrawalETH(address indexed user, uint256 amount);
    event WithdrawalERC20(address indexed user, address indexed token, uint256 amount);
    event PlatformFeeUpdated(uint256 newFeePercent);
    event PlatformFeeRecipientUpdated(address indexed newRecipient);
    event PlatformFeePaid(address indexed recipient, uint256 amount);
    event RoyaltyPaid(address indexed recipient, uint256 amount);
    event AuctionCancelled(address indexed nftContract, uint256 indexed tokenId);

    // -----------------------------------------------------------------------
    // State variables & constants
    // -----------------------------------------------------------------------
    SuperMart public superMart;

    MockERC721 public mockNft; // standard ERC-721 used for normal flows
    MockRoyaltyNFT public mockRoyaltyNft; // royalty-capable ERC-721
    MockERC20 public mockErc20; // ERC-20 used for token payments
    MockRevertingNFT public mockRevertingNft; // NFT that reverts on transfer
    MockMaliciousRoyaltyNFT public mockMaliciousRoyaltyNft; // NFT with malicious royalty implementation

    // Actors
    address public constant OWNER = address(0x1); // will be deployer/owner of SuperMart in tests
    address public constant SELLER = address(0x2);
    address public constant BUYER_1 = address(0x3);
    address public constant BUYER_2 = address(0x4);
    address public constant ROYALTY_RECIPIENT = address(0x5);

    // Marketplace constants used consistently by tests
    uint256 public constant DEFAULT_FEE_BPS = 250; // 2.5% platform fee (basis points)
    uint256 public constant TOKEN_ID_1 = 1;
    uint256 public constant TOKEN_ID_2 = 2;
    uint256 public constant TOKEN_ID_3 = 3;
    uint256 public constant TOKEN_ID_4 = 4;
    uint256 public constant LIST_PRICE_ETH = 1 ether;
    uint256 public constant LIST_PRICE_ERC20 = 100 * 1e18;
    uint256 public constant STARTING_BID_ETH = 0.5 ether;
    uint256 public constant STARTING_BID_ERC20 = 50 * 1e18;
    uint256 public constant AUCTION_DURATION = 1 days;

    // -----------------------------------------------------------------------
    // setUp — executed before each test
    // -----------------------------------------------------------------------

    /**
     * @notice Deploy a fresh SuperMart and mock tokens before each test.
     * @dev We `prank` as OWNER for the constructor so ownership is clear in tests.
     *
     * Steps:
     * 1. Deploy SuperMart as OWNER so owner functions are callable by OWNER.
     * 2. Deploy mocks: standard ERC-721, royalty ERC-721, ERC-20, and reverting ERC-721.
     * 3. Mint unique token IDs to SELLER so SELLER can list them.
     * 4. Mint ERC-20 to buyers for payment scenarios.
     * 5. Fund accounts with ETH for ETH flows and gas.
     */
    function setUp() public {
        // Deploy SuperMart with a 2.5% initial fee; constructor expects an initial fee in bps
        vm.prank(OWNER);
        superMart = new SuperMart(DEFAULT_FEE_BPS);

        // Deploy mock tokens and NFTs
        mockNft = new MockERC721("Mock NFT", "MNFT");
        mockErc20 = new MockERC20("Mock Token", "MTK", 18);
        mockRoyaltyNft = new MockRoyaltyNFT(ROYALTY_RECIPIENT, 250);
        mockRevertingNft = new MockRevertingNFT();
        mockMaliciousRoyaltyNft = new MockMaliciousRoyaltyNFT(ROYALTY_RECIPIENT);

        // Mint NFTs to SELLER so they can list
        // Mint standard NFT (TOKEN_ID_1 = 1)
        mockNft.mint(SELLER); // Mints token 0
        mockNft.mint(SELLER); // Mints token 1 (this is TOKEN_ID_1)

        // Mint royalty NFT (TOKEN_ID_2 = 2)
        mockRoyaltyNft.mint(SELLER); // Mints token 0
        mockRoyaltyNft.mint(SELLER); // Mints token 1
        mockRoyaltyNft.mint(SELLER); // Mints token 2 (this is TOKEN_ID_2)

        // Mint reverting NFT (TOKEN_ID_3 = 3)
        mockRevertingNft.mint(SELLER, 0); // Mints token 0
        mockRevertingNft.mint(SELLER, 1); // Mints token 1
        mockRevertingNft.mint(SELLER, 2); // Mints token 2
        mockRevertingNft.mint(SELLER, TOKEN_ID_3); // Mints token 3 (this is TOKEN_ID_3)

        // Mint malicious royalty NFT (TOKEN_ID_4 = 4)
        mockMaliciousRoyaltyNft.mint(SELLER); // Mints token 0
        mockMaliciousRoyaltyNft.mint(SELLER); // Mints token 1
        mockMaliciousRoyaltyNft.mint(SELLER); // Mints token 2
        mockMaliciousRoyaltyNft.mint(SELLER); // Mints token 3
        mockMaliciousRoyaltyNft.mint(SELLER); // Mints token 4 (this is TOKEN_ID_4)

        // Mint ERC-20 tokens to buyers to allow ERC20 payments and bids
        mockErc20.mint(BUYER_1, 1000 * 1e18);
        mockErc20.mint(BUYER_2, 1000 * 1e18);

        // Fund accounts with ETH for ETH purchases and bids
        vm.deal(SELLER, 10 ether);
        vm.deal(BUYER_1, 10 ether);
        vm.deal(BUYER_2, 10 ether);
        vm.deal(ROYALTY_RECIPIENT, 10 ether);
        vm.deal(OWNER, 10 ether);
    }

    // -----------------------------------------------------------------------
    // 1) ADMIN TESTS
    // -----------------------------------------------------------------------

    /// @notice Ensure constructor sets owner and platform fee info correctly
    function testConstructorSetsCorrectly() public view {
        // Owner set by constructor call in setUp via vm.prank(OWNER)
        assertEq(superMart.owner(), OWNER);

        // Platform fee info should have deployer (OWNER) as recipient and DEFAULT_FEE_BPS
        (address recipient, uint256 feePercent) = superMart.getPlatformFeeInfo();
        assertEq(recipient, OWNER);
        assertEq(feePercent, DEFAULT_FEE_BPS);
    }

    /// @notice Owner can update platform fee (and event is emitted)
    function testAdminUpdatePlatformFee() public {
        uint256 newFee = 1000; // 10%
        vm.prank(OWNER);

        // Tell forge to expect an event; the `emit` below "replays" the event context for verification
        vm.expectEmit(true, true, true, true);
        emit PlatformFeeUpdated(newFee);

        // Call the function as OWNER
        superMart.updatePlatformFee(newFee);

        // Verify the new fee persisted
        (, uint256 feePercent) = superMart.getPlatformFeeInfo();
        assertEq(feePercent, newFee);
    }

    /// @notice Only owner can pause/unpause and paused functions revert
    function testAdminCanPauseAndUnpause() public {
        // Pause as owner
        vm.prank(OWNER);
        superMart.pause();
        assertTrue(superMart.paused(), "contract should be paused after owner pause()");

        // Attempting to list while paused should revert with Pausable: paused
        vm.prank(SELLER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        superMart.listItem(address(mockNft), TOKEN_ID_1, address(0), LIST_PRICE_ETH);

        // Unpause as owner and confirm behavior returns
        vm.prank(OWNER);
        superMart.unpause();
        assertFalse(superMart.paused(), "contract should be unpaused after owner unpause()");

        // Approve & list should succeed now
        vm.prank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        vm.prank(SELLER);
        superMart.listItem(address(mockNft), TOKEN_ID_1, address(0), LIST_PRICE_ETH);
    }

    /**
     * @notice Tests that the OWNER can successfully cancel *any* user's listing.
     */
    function testAdminCanCancelListing() public {
        // 1. Arrange: Seller lists an item
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listItem(address(mockNft), TOKEN_ID_1, address(0), LIST_PRICE_ETH);
        vm.stopPrank();

        // 2. Act: OWNER cancels the listing
        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true);
        emit ListingCancelled(SELLER, address(mockNft), TOKEN_ID_1);
        superMart.adminCancelListing(address(mockNft), TOKEN_ID_1);

        // 3. Assert: The listing is deleted
        SuperMart.Listing memory listing = superMart.getListing(address(mockNft), TOKEN_ID_1);
        assertEq(listing.price, 0);
    }

    /**
     * @notice Tests that a non-owner *cannot* call adminCancelListing.
     */
    function testRevertsWhenNotAdminCancelsListing() public {
        // 1. Arrange: Seller lists an item
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listItem(address(mockNft), TOKEN_ID_1, address(0), LIST_PRICE_ETH);
        vm.stopPrank();

        // 2. Act & Assert: BUYER_1 (a non-owner) tries to call the admin function
        vm.prank(BUYER_1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BUYER_1));
        superMart.adminCancelListing(address(mockNft), TOKEN_ID_1);
    }

    /**
     * @notice Tests that the OWNER can cancel an auction that has *no bids*.
     */
    function testAdminCanCancelAuctionWithNoBids() public {
        // 1. Arrange: Seller lists an auction
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        // 2. Act: OWNER cancels the auction
        vm.prank(OWNER);
        vm.expectEmit(true, true, false, false);
        emit AuctionCancelled(address(mockNft), TOKEN_ID_1);
        superMart.adminCancelAuction(address(mockNft), TOKEN_ID_1);

        // 3. Assert: The auction is deleted
        SuperMart.Auction memory auction = superMart.getAuction(address(mockNft), TOKEN_ID_1);
        assertEq(auction.endTime, 0);
    }

    /**
     * @notice Tests that the OWNER can cancel an auction that *has an ETH bid*
     * and that the bidder is correctly refunded.
     */
    function testAdminCanCancelAuctionWithETHBidAndRefundTheBidder() public {
        // 1. Arrange: Seller lists and Buyer_1 bids
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        vm.prank(BUYER_1);
        superMart.bid{value: STARTING_BID_ETH}(address(mockNft), TOKEN_ID_1, STARTING_BID_ETH);

        // 2. Act: OWNER cancels the auction
        vm.prank(OWNER);
        superMart.adminCancelAuction(address(mockNft), TOKEN_ID_1);

        // 3. Assert:
        // Auction is deleted
        SuperMart.Auction memory auction = superMart.getAuction(address(mockNft), TOKEN_ID_1);
        assertEq(auction.endTime, 0);
        // Bidder's funds are in pending withdrawals
        assertEq(superMart.getPendingWithdrawalsETH(BUYER_1), STARTING_BID_ETH);
    }

    /**
     * @notice Tests that the OWNER can cancel an auction that *has an ERC20 bid*
     * and that the bidder is correctly refunded.
     */
    function testAdminCanCancelAuctionWithERC20BidAndRefundTheBidder() public {
        // 1. Arrange: Seller lists and Buyer_1 bids with ERC20
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(mockErc20), STARTING_BID_ERC20, AUCTION_DURATION);
        vm.stopPrank();

        vm.startPrank(BUYER_1);
        mockErc20.approve(address(superMart), STARTING_BID_ERC20);
        superMart.bid(address(mockNft), TOKEN_ID_1, STARTING_BID_ERC20);
        vm.stopPrank();

        // 2. Act: OWNER cancels the auction
        vm.prank(OWNER);
        superMart.adminCancelAuction(address(mockNft), TOKEN_ID_1);

        // 3. Assert:
        // Auction is deleted
        SuperMart.Auction memory auction = superMart.getAuction(address(mockNft), TOKEN_ID_1);
        assertEq(auction.endTime, 0);
        // Bidder's funds are in pending withdrawals
        assertEq(superMart.getPendingWithdrawalsERC20(address(mockErc20), BUYER_1), STARTING_BID_ERC20);
    }

    /**
     * @notice Tests that a non-owner *cannot* call adminCancelAuction.
     */
    function testRevertWhenNotAdminCancelsAuction() public {
        // 1. Arrange: Seller lists an auction
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        // 2. Act & Assert: BUYER_1 tries to call the admin function
        vm.prank(BUYER_1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BUYER_1));
        superMart.adminCancelAuction(address(mockNft), TOKEN_ID_1);
    }

    /**
     * @notice Tests that the OWNER can successfully update the fee recipient.
     */
    function testAdminCanUpdatePlatformFeeRecipient() public {
        // 1. Arrange: Define a new recipient (we can use BUYER_1's address)
        address newRecipient = BUYER_1;

        // 2. Act: Owner calls the function
        vm.prank(OWNER);
        vm.expectEmit(true, false, false, true); // Check indexed recipient
        emit PlatformFeeRecipientUpdated(newRecipient);
        superMart.updatePlatformFeeRecipient(newRecipient);

        // 3. Assert: The recipient address is updated in the contract
        (address recipient,) = superMart.getPlatformFeeInfo();
        assertEq(recipient, newRecipient);
    }

    /**
     * @notice Tests that a non-owner *cannot* update the fee recipient.
     */
    function testRevertWhenNotAdminUpdatesPlatformFeeRecipient() public {
        // 1. Arrange: Define a new recipient
        address newRecipient = BUYER_1;

        // 2. Act & Assert: BUYER_2 (a non-owner) tries to call the function
        vm.prank(BUYER_2);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BUYER_2));
        superMart.updatePlatformFeeRecipient(newRecipient);
    }

    /**
     * @notice Tests that the OWNER *cannot* set the fee recipient to the zero address.
     */
    function testRevertWhenAdminUpdatesPlatformFeeRecipientToZeroAddress() public {
        // 1. Arrange: Define the new recipient as the zero address
        address newRecipient = address(0);

        // 2. Act & Assert: Owner tries to set the recipient to address(0)
        vm.prank(OWNER);
        vm.expectRevert(SuperMart.RecipientIsZeroAddress.selector);
        superMart.updatePlatformFeeRecipient(newRecipient);
    }

    // -----------------------------------------------------------------------
    // 2) FIXED-PRICE LISTING & BUYING (ETH and ERC20 + royalties)
    // -----------------------------------------------------------------------

    /// @notice Seller can list item for ETH and event is emitted
    function testListItemWithETHSucceeds() public {
        // Seller must approve marketplace to transfer NFT on sale
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);

        // Expect ItemListed event
        vm.expectEmit(true, true, true, true);
        emit ItemListed(SELLER, address(mockNft), TOKEN_ID_1, address(0), LIST_PRICE_ETH);

        // List as SELLER for ETH (paymentToken = address(0))
        superMart.listItem(address(mockNft), TOKEN_ID_1, address(0), LIST_PRICE_ETH);
        vm.stopPrank();

        // Validate stored listing state
        SuperMart.Listing memory listing = superMart.getListing(address(mockNft), TOKEN_ID_1);
        assertEq(listing.seller, SELLER);
        assertEq(listing.paymentToken, address(0));
        assertEq(listing.price, LIST_PRICE_ETH);
    }

    /// @notice Buying with ETH executes payouts: royalty (if any), platform fee, then seller
    function testBuyingItemWithETHExecutesSequentially() public {
        // Seller approves and lists
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listItem(address(mockNft), TOKEN_ID_1, address(0), LIST_PRICE_ETH);
        vm.stopPrank();

        // Snapshot balances before purchase for thorough assertions
        uint256 sellerBalanceBefore = SELLER.balance;

        // Platform fee and expected payout
        uint256 platformFee = (LIST_PRICE_ETH * DEFAULT_FEE_BPS) / 10000;
        uint256 sellerPayout = LIST_PRICE_ETH - platformFee;

        // BUYER_1 purchases by sending exact ETH value — incorrect amounts should revert
        vm.prank(BUYER_1);
        vm.expectEmit(true, true, true, true);
        emit ItemSold(SELLER, BUYER_1, address(mockNft), TOKEN_ID_1, LIST_PRICE_ETH);
        superMart.buyItem{value: LIST_PRICE_ETH}(address(mockNft), TOKEN_ID_1);

        // Confirm NFT ownership change and cleanup of listing
        assertEq(mockNft.ownerOf(TOKEN_ID_1), BUYER_1);
        SuperMart.Listing memory listing = superMart.getListing(address(mockNft), TOKEN_ID_1);
        assertEq(listing.price, 0, "listing should be removed after purchase");

        // Check payouts: seller and owner (fee recipient) balances updated
        assertEq(SELLER.balance, sellerBalanceBefore + sellerPayout, "seller should receive sale amount minus fee");
        assertEq(address(superMart).balance, platformFee, "contract should hold the accumulated ETH fee");
        assertEq(superMart.getAccumulatedFeesETH(), platformFee, "accumulatedFeesETH should increase correctly");
    }

    /// @notice Buying a royalty-enabled NFT pays: royalty, platform fee, seller
    function testBuyingItemWithETHWithRoyaltyExecutesSequentially() public {
        // --- 1. Arrange ---
        // Token (TOKEN_ID_2) is already minted to SELLER in setUp()
        vm.startPrank(SELLER);
        mockRoyaltyNft.approve(address(superMart), TOKEN_ID_2);
        superMart.listItem(address(mockRoyaltyNft), TOKEN_ID_2, address(0), LIST_PRICE_ETH);
        vm.stopPrank();

        // --- 2. Snapshot balances ---
        uint256 sellerBefore = SELLER.balance;
        uint256 royaltyBefore = ROYALTY_RECIPIENT.balance;

        // --- 3. Calculate expectations ---
        uint256 platformFee = (LIST_PRICE_ETH * 250) / 10000; // 0.025 ETH
        uint256 royaltyAmount = (LIST_PRICE_ETH * 250) / 10000; // 0.025 ETH
        uint256 sellerPayout = LIST_PRICE_ETH - platformFee - royaltyAmount; // 0.95 ETH

        // --- 4. Expect events (in the correct order) ---
        vm.startPrank(BUYER_1);

        // PlatformFeePaid is emitted FIRST
        vm.expectEmit(true, true, true, true);
        emit PlatformFeePaid(OWNER, platformFee);

        // RoyaltyPaid is emitted SECOND
        vm.expectEmit(true, true, true, true);
        emit RoyaltyPaid(ROYALTY_RECIPIENT, royaltyAmount);

        // ItemSold is emitted last
        vm.expectEmit(true, true, true, true);
        emit ItemSold(SELLER, BUYER_1, address(mockRoyaltyNft), TOKEN_ID_2, LIST_PRICE_ETH);

        // --- 5. Act: Buyer purchases ---
        superMart.buyItem{value: LIST_PRICE_ETH}(address(mockRoyaltyNft), TOKEN_ID_2);
        vm.stopPrank();

        // --- 6. Assertions ---
        assertEq(mockRoyaltyNft.ownerOf(TOKEN_ID_2), BUYER_1, "buyer should own the NFT after purchase");
        assertEq(SELLER.balance, sellerBefore + sellerPayout, "seller gets amount after royalty + fee");
        assertEq(address(superMart).balance, platformFee, "contract should hold the accumulated ETH fee");
        assertEq(superMart.getAccumulatedFeesETH(), platformFee, "accumulatedFeesETH should increase correctly");
        assertEq(ROYALTY_RECIPIENT.balance, royaltyBefore + royaltyAmount, "royalty recipient receives royalty");
    }

    /// @notice Buying with ERC20: buyer must approve the marketplace first
    function testBuyingItemWithERC20ExecutesSequentially() public {
        // Seller lists for ERC20
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listItem(address(mockNft), TOKEN_ID_1, address(mockErc20), LIST_PRICE_ERC20);
        vm.stopPrank();

        // Buyer approves marketplace to transfer tokens on their behalf
        vm.prank(BUYER_1);
        mockErc20.approve(address(superMart), LIST_PRICE_ERC20);

        // Snapshot token balances
        uint256 sellerTokenBefore = mockErc20.balanceOf(SELLER);
        uint256 buyerTokenBefore = mockErc20.balanceOf(BUYER_1);

        // Expected splits
        uint256 platformFee = (LIST_PRICE_ERC20 * DEFAULT_FEE_BPS) / 10000;
        uint256 sellerPayout = LIST_PRICE_ERC20 - platformFee;

        // Buyer calls buyItem (no ETH)
        vm.prank(BUYER_1);
        superMart.buyItem(address(mockNft), TOKEN_ID_1);

        // Check token transfers and NFT ownership
        assertEq(mockNft.ownerOf(TOKEN_ID_1), BUYER_1);
        assertEq(mockErc20.balanceOf(SELLER), sellerTokenBefore + sellerPayout, "seller should receive ERC20 payout");
        assertEq(
            mockErc20.balanceOf(address(superMart)), platformFee, "contract should hold the accumulated platform fee"
        );
        assertEq(
            superMart.getAccumulatedFeesERC20(address(mockErc20)),
            platformFee,
            "accumulatedFeesERC20 should increase correctly"
        );
        assertEq(mockErc20.balanceOf(BUYER_1), buyerTokenBefore - LIST_PRICE_ERC20, "buyer should be debited");
    }

    /// @notice Buying with ERC20 but without approval should revert with InsufficientAllowance
    function testRevertBuyingWithERC20ButNoApproval() public {
        // Seller lists for ERC20
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listItem(address(mockNft), TOKEN_ID_1, address(mockErc20), LIST_PRICE_ERC20);
        vm.stopPrank();

        // Buyer does NOT approve: calling buyItem should revert due to insufficient allowance
        vm.prank(BUYER_1);
        vm.expectRevert(SuperMart.InsufficientAllowance.selector);
        superMart.buyItem(address(mockNft), TOKEN_ID_1);
    }

    /**
     * @notice Tests that the *correct* seller can successfully cancel their own listing.
     */
    function testSellerCanCancelListing() public {
        // 1. Arrange: Seller lists an item
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listItem(address(mockNft), TOKEN_ID_1, address(0), LIST_PRICE_ETH);

        // 2. Act: Seller cancels the listing
        vm.expectEmit(true, true, true, true);
        emit ListingCancelled(SELLER, address(mockNft), TOKEN_ID_1);
        superMart.cancelListing(address(mockNft), TOKEN_ID_1);
        vm.stopPrank();

        // 3. Assert: The listing is deleted
        SuperMart.Listing memory listing = superMart.getListing(address(mockNft), TOKEN_ID_1);
        assertEq(listing.price, 0);
    }

    /**
     * @notice Tests that a random user *cannot* cancel someone else's listing.
     */
    function testRevertIfNotSellerCancelsListing() public {
        // 1. Arrange: Seller lists an item
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listItem(address(mockNft), TOKEN_ID_1, address(0), LIST_PRICE_ETH);
        vm.stopPrank();

        // 2. Act & Assert: BUYER_1 (a non-seller) tries to cancel
        vm.prank(BUYER_1);
        vm.expectRevert(SuperMart.NotSeller.selector);
        superMart.cancelListing(address(mockNft), TOKEN_ID_1);
    }

    /**
     * @notice Tests that canceling a non-existent listing reverts.
     */
    function testRevertCancelListingIfListingDoesNotExist() public {
        // 1. Arrange: No item is listed

        // 2. Act & Assert: Seller tries to cancel a token that isn't listed
        vm.prank(SELLER);
        vm.expectRevert(SuperMart.ItemNotListed.selector);
        superMart.cancelListing(address(mockNft), TOKEN_ID_1);
    }

    // -----------------------------------------------------------------------
    // 3) AUCTION TESTS: ETH & ERC20 — bidding, outbid refunds, optimal end behavior
    // -----------------------------------------------------------------------

    /// @notice Seller creates an auction (ETH payment)
    function testListAuctionWithETHSucceeds() public {
        // Seller approves then creates auction
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);

        vm.expectEmit(true, true, true, true);
        emit AuctionCreated(
            SELLER, address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, block.timestamp + AUCTION_DURATION
        );

        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        SuperMart.Auction memory auction = superMart.getAuction(address(mockNft), TOKEN_ID_1);
        assertEq(auction.seller, SELLER);
        assertEq(auction.paymentToken, address(0));
        assertEq(auction.startingBid, STARTING_BID_ETH);
        assertEq(auction.endTime, block.timestamp + AUCTION_DURATION);
    }

    /// @notice First bid (ETH) must be >= starting bid; the contract should hold funds
    function testFirstBidWithETHSucceeds() public {
        // Setup: list auction
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        // Buyer places first bid equal to starting bid
        vm.startPrank(BUYER_1);
        vm.expectEmit(true, true, true, true);
        emit NewBid(BUYER_1, address(mockNft), TOKEN_ID_1, STARTING_BID_ETH);
        superMart.bid{value: STARTING_BID_ETH}(address(mockNft), TOKEN_ID_1, STARTING_BID_ETH);
        vm.stopPrank();

        // Check that auction highestBidder and highestBid updated
        SuperMart.Auction memory auction = superMart.getAuction(address(mockNft), TOKEN_ID_1);
        assertEq(auction.highestBidder, BUYER_1);
        assertEq(auction.highestBid, STARTING_BID_ETH);

        // Confirm contract holds ETH equal to bid
        assertEq(address(superMart).balance, STARTING_BID_ETH);
    }

    /// @notice Second higher bid refunds previous highest bidder via pending withdrawal
    function testSecondBidWithETHSucceedsAndProcessesRefund() public {
        // Setup: create auction + first bid
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        vm.prank(BUYER_1);
        superMart.bid{value: STARTING_BID_ETH}(address(mockNft), TOKEN_ID_1, STARTING_BID_ETH);

        // Second bidder outbids
        uint256 secondBid = STARTING_BID_ETH + 0.1 ether;
        vm.startPrank(BUYER_2);
        vm.expectEmit(true, true, true, true);
        emit NewBid(BUYER_2, address(mockNft), TOKEN_ID_1, secondBid);
        superMart.bid{value: secondBid}(address(mockNft), TOKEN_ID_1, secondBid);
        vm.stopPrank();

        // Check highest bid updated
        SuperMart.Auction memory auction = superMart.getAuction(address(mockNft), TOKEN_ID_1);
        assertEq(auction.highestBidder, BUYER_2);
        assertEq(auction.highestBid, secondBid);

        // The previous bid (BUYER_1) should be in pending withdrawals (ETH)
        uint256 pending = superMart.getPendingWithdrawalsETH(BUYER_1);
        assertEq(pending, STARTING_BID_ETH);

        // Contract balance should equal only the current highest bid (previous bid moved to pending)
        assertEq(address(superMart).balance, STARTING_BID_ETH + secondBid);
    }

    /// @notice Outbid buyer withdraws their ETH
    function testWithdrawETHFromAuctionSucceeds() public {
        // Setup auction and outbid scenario
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        vm.prank(BUYER_1);
        superMart.bid{value: STARTING_BID_ETH}(address(mockNft), TOKEN_ID_1, STARTING_BID_ETH);

        vm.prank(BUYER_2);
        superMart.bid{value: STARTING_BID_ETH + 0.1 ether}(address(mockNft), TOKEN_ID_1, STARTING_BID_ETH + 0.1 ether);

        // BUYER_1's balance before withdraw
        uint256 buyer1Before = BUYER_1.balance;

        // Expect WithdrawalETH event when buyer withdraws
        vm.startPrank(BUYER_1);
        vm.expectEmit(true, true, true, true);
        emit WithdrawalETH(BUYER_1, STARTING_BID_ETH);
        superMart.withdrawETH();
        vm.stopPrank();

        // After withdraw, pending should be zero and buyer balance should increase roughly by bid (less gas)
        assertEq(superMart.getPendingWithdrawalsETH(BUYER_1), 0);
        assertGe(
            BUYER_1.balance,
            buyer1Before + STARTING_BID_ETH - 1_000_000,
            "buyer balance should increase by refund amount (minus gas)"
        );
    }

    /// @notice Auction end distributes funds correctly and transfers NFT to winner
    function testEndAuctionUsingETHEndsSequentially() public {
        // Seller lists and buyer bids
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        vm.prank(BUYER_1);
        superMart.bid{value: STARTING_BID_ETH}(address(mockNft), TOKEN_ID_1, STARTING_BID_ETH);

        // Snapshot balances
        uint256 sellerBefore = SELLER.balance;

        // Platform fee and expected seller payout
        uint256 platformFee = (STARTING_BID_ETH * DEFAULT_FEE_BPS) / 10000;
        uint256 sellerPayout = STARTING_BID_ETH - platformFee;

        // Fast-forward time past auction end
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        // Expect AuctionHasEnded event
        vm.startPrank(OWNER);
        vm.expectEmit(true, true, true, true);
        emit AuctionHasEnded(BUYER_1, SELLER, address(mockNft), TOKEN_ID_1, STARTING_BID_ETH);
        superMart.endAuction(address(mockNft), TOKEN_ID_1);
        vm.stopPrank();

        // Verify NFT ownership and payouts
        assertEq(mockNft.ownerOf(TOKEN_ID_1), BUYER_1);
        assertEq(SELLER.balance, sellerBefore + sellerPayout);
        assertEq(address(superMart).balance, platformFee, "contract should hold the accumulated ETH fee");
        assertEq(superMart.getAccumulatedFeesETH(), platformFee, "accumulatedFeesETH should increase correctly");
    }

    /// @notice ERC20 auction flow: bids use tokens and payouts deliver ERC20 tokens
    function testEndAuctionUsingERC20EndsSequentially() public {
        // Seller lists for ERC20
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(mockErc20), STARTING_BID_ERC20, AUCTION_DURATION);
        vm.stopPrank();

        // Buyer approves and bids
        vm.startPrank(BUYER_1);
        mockErc20.approve(address(superMart), STARTING_BID_ERC20);
        superMart.bid(address(mockNft), TOKEN_ID_1, STARTING_BID_ERC20);
        vm.stopPrank();

        // Snapshot token balances
        uint256 sellerTokenBefore = mockErc20.balanceOf(SELLER);

        // Platform fee and expected seller payout
        uint256 platformFee = (STARTING_BID_ERC20 * DEFAULT_FEE_BPS) / 10000;
        uint256 sellerPayout = STARTING_BID_ERC20 - platformFee;

        // Fast-forward time and end
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        vm.prank(OWNER);
        superMart.endAuction(address(mockNft), TOKEN_ID_1);

        // Assertions
        assertEq(mockNft.ownerOf(TOKEN_ID_1), BUYER_1);
        assertEq(mockErc20.balanceOf(SELLER), sellerTokenBefore + sellerPayout);
        assertEq(
            mockErc20.balanceOf(address(superMart)),
            platformFee,
            "contract should hold the accumulated ERC20 platform fee"
        );
        assertEq(
            superMart.getAccumulatedFeesERC20(address(mockErc20)),
            platformFee,
            "accumulatedFeesERC20 should increase correctly"
        );
    }

    /// @notice ERC20 outbid refunds via withdrawERC20
    function testWithdrawERC20FromAuctionSucceeds() public {
        // List for ERC20
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(mockErc20), STARTING_BID_ERC20, AUCTION_DURATION);
        vm.stopPrank();

        // BUYER_1 bids
        vm.startPrank(BUYER_1);
        mockErc20.approve(address(superMart), STARTING_BID_ERC20);
        superMart.bid(address(mockNft), TOKEN_ID_1, STARTING_BID_ERC20);
        vm.stopPrank();

        // BUYER_2 outbids
        uint256 secondBid = STARTING_BID_ERC20 + 10e18;
        vm.startPrank(BUYER_2);
        mockErc20.approve(address(superMart), secondBid);
        superMart.bid(address(mockNft), TOKEN_ID_1, secondBid);
        vm.stopPrank();

        // Now BUYER_1 has pending ERC20 refunds
        uint256 pending = superMart.getPendingWithdrawalsERC20(address(mockErc20), BUYER_1);
        assertEq(pending, STARTING_BID_ERC20);

        uint256 buyerBefore = mockErc20.balanceOf(BUYER_1);

        // BUYER_1 withdraws
        vm.startPrank(BUYER_1);
        vm.expectEmit(true, true, true, true);
        emit WithdrawalERC20(BUYER_1, address(mockErc20), STARTING_BID_ERC20);
        superMart.withdrawERC20(address(mockErc20));
        vm.stopPrank();

        // After withdraw, contract pending cleared and buyer balance is restored
        assertEq(superMart.getPendingWithdrawalsERC20(address(mockErc20), BUYER_1), 0);
        assertEq(mockErc20.balanceOf(BUYER_1), buyerBefore + STARTING_BID_ERC20);
    }

    function testWithdrawAccumulatedFeesETH() public {
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listItem(address(mockNft), TOKEN_ID_1, address(0), LIST_PRICE_ETH);
        vm.stopPrank();

        vm.prank(BUYER_1);
        superMart.buyItem{value: LIST_PRICE_ETH}(address(mockNft), TOKEN_ID_1);

        uint256 ownerBefore = OWNER.balance;
        uint256 accumulatedBefore = superMart.getAccumulatedFeesETH();
        assertGt(accumulatedBefore, 0, "should have some ETH fees before withdrawal");

        vm.prank(OWNER);
        superMart.withdrawAccumulatedFees(address(0));

        assertEq(OWNER.balance, ownerBefore + accumulatedBefore, "owner should receive accumulated ETH");
        assertEq(address(superMart).balance, 0, "SuperMart balance should reset after withdrawal");
        assertEq(superMart.getAccumulatedFeesETH(), 0, "accumulated ETH fees should reset");
    }

    function testWithdrawAccumulatedFeesERC20() public {
        // Mint ERC20 tokens to the buyer and approve the marketplace
        vm.startPrank(BUYER_1);
        mockErc20.mint(BUYER_1, LIST_PRICE_ERC20);
        mockErc20.approve(address(superMart), LIST_PRICE_ERC20);
        vm.stopPrank();

        // Seller lists an NFT priced in ERC20
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_2);
        superMart.listItem(address(mockNft), TOKEN_ID_2, address(mockErc20), LIST_PRICE_ERC20);
        vm.stopPrank();

        // Buyer purchases it — this generates ERC20 fees
        vm.prank(BUYER_1);
        superMart.buyItem(address(mockNft), TOKEN_ID_2);

        uint256 ownerBefore = mockErc20.balanceOf(OWNER);
        uint256 accumulatedBefore = superMart.getAccumulatedFeesERC20(address(mockErc20));
        assertGt(accumulatedBefore, 0, "should have some ERC20 fees before withdrawal");

        vm.prank(OWNER);
        superMart.withdrawAccumulatedFees(address(mockErc20));

        assertEq(mockErc20.balanceOf(OWNER), ownerBefore + accumulatedBefore, "owner should receive accumulated ETH");
        assertEq(address(superMart).balance, 0, "SuperMart balance should reset after withdrawal");
        assertEq(superMart.getAccumulatedFeesERC20(address(mockErc20)), 0, "accumulated ERC20 fees should reset");
    }

    /**
     * @notice Tests that the *correct* seller can cancel their auction if no bids exist.
     */
    function testCanCancelAuctionWithNoBids() public {
        // 1. Arrange: Seller lists an auction
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        // 2. Act: Seller cancels the auction
        vm.prank(SELLER);
        vm.expectEmit(true, true, false, false); // Only checking indexed topics
        emit AuctionCancelled(address(mockNft), TOKEN_ID_1);
        superMart.cancelAuction(address(mockNft), TOKEN_ID_1);

        // 3. Assert: The auction is deleted
        SuperMart.Auction memory auction = superMart.getAuction(address(mockNft), TOKEN_ID_1);
        assertEq(auction.endTime, 0);
    }

    // -----------------------------------------------------------------------
    // 4) Edge Cases & Negative Tests
    // -----------------------------------------------------------------------

    /**
     * @notice Tests that a random user *cannot* cancel someone else's auction.
     */
    function testRevertWhenNotSellerCancelsAuction() public {
        // 1. Arrange: Seller lists an auction
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        // 2. Act & Assert: BUYER_1 tries to cancel it
        vm.prank(BUYER_1);
        vm.expectRevert(SuperMart.NotSeller.selector);
        superMart.cancelAuction(address(mockNft), TOKEN_ID_1);
    }

    /**
     * @notice Tests that a seller *cannot* cancel an auction once a bid has been placed.
     */
    function testRevertCancelAuctionIfAuctionHasAlreadyStarted() public {
        // 1. Arrange: Seller lists and Buyer_1 bids
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        vm.prank(BUYER_1);
        superMart.bid{value: STARTING_BID_ETH}(address(mockNft), TOKEN_ID_1, STARTING_BID_ETH);

        // 2. Act & Assert: Seller tries to cancel
        vm.prank(SELLER);
        vm.expectRevert(SuperMart.AuctionAlreadyStarted.selector);
        superMart.cancelAuction(address(mockNft), TOKEN_ID_1);
    }

    /// @notice Non-owner cannot change platform fee (Ownable enforcement)
    function testRevertWhenNotOwnerUpdatesPlatformFee() public {
        vm.prank(BUYER_1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BUYER_1));

        superMart.updatePlatformFee(1000);
    }

    /// @notice Listing with 0 price should revert (PriceMustBeAboveZero)
    function testRevertWhenListItemPriceIsZero() public {
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        vm.expectRevert(SuperMart.PriceMustBeAboveZero.selector);
        superMart.listItem(address(mockNft), TOKEN_ID_1, address(0), 0);
        vm.stopPrank();
    }

    /// @notice Auction with startingBid = 0 should revert (PriceMustBeAboveZero)
    function testRevertWhenAuctionStartingBidIsZero() public {
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        vm.expectRevert(SuperMart.PriceMustBeAboveZero.selector);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), 0, AUCTION_DURATION);
        vm.stopPrank();
    }

    /// @notice Buying an already-sold item should revert (ItemNotListed)
    function testRevertWhenBuyingItemAlreadySold() public {
        // Sell the item
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listItem(address(mockNft), TOKEN_ID_1, address(0), LIST_PRICE_ETH);
        vm.stopPrank();

        vm.prank(BUYER_1);
        superMart.buyItem{value: LIST_PRICE_ETH}(address(mockNft), TOKEN_ID_1);

        // Attempt to buy again should revert with ItemNotListed
        vm.prank(BUYER_2);
        vm.expectRevert(SuperMart.ItemNotListed.selector);
        superMart.buyItem{value: LIST_PRICE_ETH}(address(mockNft), TOKEN_ID_1);
    }

    /// @notice Bidding after auction end should revert (AuctionEnded)
    function testRevertForBidAfterAuctionEnds() public {
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        // Fast-forward beyond end
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        vm.prank(BUYER_1);
        vm.expectRevert(SuperMart.AuctionEnded.selector);
        superMart.bid{value: STARTING_BID_ETH}(address(mockNft), TOKEN_ID_1, STARTING_BID_ETH);
    }

    /// @notice First bid below startingBid should revert
    function testRevertIfFirstBidIsBelowStartingBid() public {
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        vm.prank(BUYER_1);
        vm.expectRevert(SuperMart.BidBelowStartingPrice.selector);
        superMart.bid{value: STARTING_BID_ETH - 0.1 ether}(address(mockNft), TOKEN_ID_1, STARTING_BID_ETH - 0.1 ether);
    }

    /// @notice ETH bid amount mismatch (amount param vs msg.value) should revert (BidAmountMismatch)
    function testRevertIfETHBidAndAmountMismatch() public {
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        // Call with msg.value = 0 but amount param > 0 -> mismatch
        vm.prank(BUYER_1);
        vm.expectRevert(SuperMart.BidAmountMismatch.selector);
        superMart.bid(address(mockNft), TOKEN_ID_1, STARTING_BID_ETH);
    }

    /// @notice Ending an auction with no bids should revert (NoBidsPlaced)
    function testRevertWhenEndingAuctionWithNoBids() public {
        vm.startPrank(SELLER);
        mockNft.approve(address(superMart), TOKEN_ID_1);
        superMart.listAuction(address(mockNft), TOKEN_ID_1, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        vm.prank(OWNER);
        vm.expectRevert(SuperMart.NoBidsPlaced.selector);
        superMart.endAuction(address(mockNft), TOKEN_ID_1);
    }

    /// @notice Test royalty > price edge-case: contract logic should set royalty to 0 and pay seller+fee
    function testIfRoyaltyExceedsPriceJustPaysSeller() public {
        // --- 1. Arrange ---
        // We use the new MockMaliciousRoyaltyNFT and its token.
        // We don't need to call setRoyalty() because it's always malicious.
        vm.startPrank(SELLER);
        mockMaliciousRoyaltyNft.approve(address(superMart), TOKEN_ID_4);
        superMart.listItem(address(mockMaliciousRoyaltyNft), TOKEN_ID_4, address(0), LIST_PRICE_ETH);
        vm.stopPrank();

        // --- 2. Snapshot balances ---
        uint256 sellerBefore = SELLER.balance;
        uint256 royaltyBefore = ROYALTY_RECIPIENT.balance;
        uint256 contractBefore = address(superMart).balance;

        // --- 3. Calculate expectations ---
        // Your marketplace logic should detect royalty >= price
        // and correctly set the royaltyAmount to 0.
        uint256 platformFee = (LIST_PRICE_ETH * DEFAULT_FEE_BPS) / 10000;
        uint256 sellerPayout = LIST_PRICE_ETH - platformFee;

        // --- 4. Act ---
        vm.prank(BUYER_1);
        superMart.buyItem{value: LIST_PRICE_ETH}(address(mockMaliciousRoyaltyNft), TOKEN_ID_4);

        // --- 5. Assert ---
        // Royalty recipient should NOT be paid.
        // Seller should receive the full price minus the platform fee.
        assertEq(SELLER.balance, sellerBefore + sellerPayout, "Seller payout is wrong");
        assertEq(ROYALTY_RECIPIENT.balance, royaltyBefore, "Royalty recipient was paid!");
        assertEq(address(superMart).balance, contractBefore + platformFee, "Contract did not accumulate fee");
        assertEq(superMart.getAccumulatedFeesETH(), platformFee, "Fee tracking mismatch");
        assertEq(mockMaliciousRoyaltyNft.ownerOf(TOKEN_ID_4), BUYER_1, "NFT was not transferred");
    }

    /// @notice If NFT transfer reverts during buy, the whole tx must revert and state unchanged
    function testRevertTransactionIfNFTTransferReverts() public {
        // Approve and list a reverting NFT
        vm.startPrank(SELLER);
        mockRevertingNft.approve(address(superMart), TOKEN_ID_3);
        superMart.listItem(address(mockRevertingNft), TOKEN_ID_3, address(0), LIST_PRICE_ETH);
        vm.stopPrank();

        // Snapshot balances and ownership
        uint256 sellerBefore = SELLER.balance;
        uint256 ownerBefore = OWNER.balance;
        address ownerOfTokenBefore = mockRevertingNft.ownerOf(TOKEN_ID_3);

        // Attempt to buy should revert with custom error
        vm.prank(BUYER_1);
        vm.expectRevert(MockRevertingNFT.TransferReverted.selector);
        superMart.buyItem{value: LIST_PRICE_ETH}(address(mockRevertingNft), TOKEN_ID_3);

        // State should be unchanged: balances and token owner
        assertEq(SELLER.balance, sellerBefore);
        assertEq(OWNER.balance, ownerBefore);
        assertEq(mockRevertingNft.ownerOf(TOKEN_ID_3), ownerOfTokenBefore);
    }

    /// @notice If NFT transfer reverts during endAuction, the tx must revert and auction state preserved
    function testRevertTransactionDuringEndAuctionButPreserveAuctionState() public {
        // Approve and list reverting NFT, bid
        vm.startPrank(SELLER);
        mockRevertingNft.approve(address(superMart), TOKEN_ID_3);
        superMart.listAuction(address(mockRevertingNft), TOKEN_ID_3, address(0), STARTING_BID_ETH, AUCTION_DURATION);
        vm.stopPrank();

        vm.prank(BUYER_1);
        superMart.bid{value: STARTING_BID_ETH}(address(mockRevertingNft), TOKEN_ID_3, STARTING_BID_ETH);

        // Fast-forward time to end
        vm.warp(block.timestamp + AUCTION_DURATION + 1);

        // endAuction should revert because transferFrom reverts; auction data should remain
        vm.prank(OWNER);
        vm.expectRevert(MockRevertingNFT.TransferReverted.selector);
        superMart.endAuction(address(mockRevertingNft), TOKEN_ID_3);

        // Auction should still be present and hold highestBid
        SuperMart.Auction memory auction = superMart.getAuction(address(mockRevertingNft), TOKEN_ID_3);
        assertEq(auction.highestBid, STARTING_BID_ETH);
    }

    // -----------------------------------------------------------------------
    // 5) OWNER STUCK FUND WITHDRAWALS (recovering tokens & ETH accidentally sent)
    // -----------------------------------------------------------------------

    /// @notice Owner can withdraw ETH accidentally sent to contract (withdrawStuckETH)
    function testOwnerCanWithdrawStuckETH() public {
        // Send 1 ETH to marketplace contract directly (simulate accidental transfer)
        (bool success,) = payable(address(superMart)).call{value: 1 ether}("");
        require(success, "failed to fund marketplace for test");

        // Snapshot owner balance
        uint256 ownerBefore = OWNER.balance;
        assertEq(address(superMart).balance, 1 ether, "contract should hold 1 ETH before withdrawal");

        // Owner invokes withdrawStuckETH -> funds forwarded to platform fee recipient (defaults to OWNER)
        vm.prank(OWNER);
        superMart.withdrawStuckETH();

        // After withdrawal, contract balance is zero and owner balance increased by 1 ETH
        assertEq(address(superMart).balance, 0);
        assertEq(OWNER.balance, ownerBefore + 1 ether);
    }

    /// @notice Non-owner cannot call withdrawStuckETH
    function testRevertWhenNotOwnerWithdrawsStuckETH() public {
        // Fund contract
        (bool success,) = payable(address(superMart)).call{value: 1 ether}("");
        require(success, "fund failed");

        // Non-owner attempt should revert via Ownable guard
        vm.prank(BUYER_1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BUYER_1));
        superMart.withdrawStuckETH();
    }

    /// @notice Withdraw stuck ETH when contract balance is zero should revert
    function testRevertWhenOwnerWithdrawsStuckETHFromZeroBalance() public {
        // Ensure contract has zero balance first
        assertEq(address(superMart).balance, 0);

        vm.prank(OWNER);
        vm.expectRevert(SuperMart.NoFundsToWithdrawETH.selector);
        superMart.withdrawStuckETH();
    }

    /// @notice Owner can withdraw stuck ERC20 tokens that were accidentally sent
    function testOwnerCanWithdrawStuckERC20() public {
        // Mint ERC20 tokens directly to the contract (simulate accidental transfer)
        mockErc20.mint(address(superMart), 100e18);

        uint256 ownerBefore = mockErc20.balanceOf(OWNER);
        assertEq(mockErc20.balanceOf(address(superMart)), 100e18);

        // Owner withdraws
        vm.prank(OWNER);
        superMart.withdrawStuckERC20(address(mockErc20));

        // Contract has zero token balance and owner received tokens
        assertEq(mockErc20.balanceOf(address(superMart)), 0);
        assertEq(mockErc20.balanceOf(OWNER), ownerBefore + 100e18);
    }

    /// @notice Only owner can withdraw stuck ERC20
    function testRevertWhenNotOwnerWithdrawsStuckERC20() public {
        mockErc20.mint(address(superMart), 100e18);

        vm.prank(BUYER_1);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, BUYER_1));
        superMart.withdrawStuckERC20(address(mockErc20));
    }

    /// @notice Withdraw stuck ERC20 when contract balance is zero should revert
    function testRevertWhenOwnerWithdrawsStuckERC20FromZeroBalance() public {
        assertEq(mockErc20.balanceOf(address(superMart)), 0);

        vm.prank(OWNER);
        vm.expectRevert(SuperMart.NoFundsToWithdrawERC20.selector);
        superMart.withdrawStuckERC20(address(mockErc20));
    }
}
