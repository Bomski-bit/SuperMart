// SPDX License-Identifier: MIT

pragma solidity ^0.8.20;

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title SuperMart NFT Marketplace
 * @notice A decentralized NFT marketplace that supports both fixed-price listings and time-based auctions.
 * @dev
 * - Accepts ETH and any ERC-20 token as payment.
 * - Integrates EIP-2981 royalties for automated creator payouts.
 * - Includes configurable platform fees and secure admin controls.
 * - Implements pausing, safe withdrawals, and protection against reentrancy.
 *
 * Key Features:
 * - Fixed-price sales using ETH or ERC-20 tokens.
 * - Auctions with minimum bid and duration.
 * - EIP-2981 royalty detection and payment.
 * - Platform fee configurable by owner (capped at 20%).
 * - Pausable contract with onlyOwner administrative functions.
 * - Secure refund pattern for outbid bidders and failed transfers.
 *
 * Security:
 * - Uses ReentrancyGuard for critical functions.
 * - Follows Checks-Effects-Interactions pattern.
 * - SafeERC20 for token transfers.
 * - Supports fallback and receive for ETH deposits.
 *
 * @author Boma Ogolo
 */
contract SuperMart is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;
    /////////////////////////////
    //     Type Declarations
    /////////////////////////////
    /**
     * - @dev A struct to store information about a direct-sale listing.
     * - @param seller The address of the NFT owner.
     * - @param price The price.
     * - @param paymentToken The address of the payment token (address(0) for ETH).
     * - @notice A listing with `price == 0` indicates no active listing.
     */

    struct Listing {
        address seller; // The address of the NFT owner
        address paymentToken; // address(0) = ETH, otherwise ERC-20 address
        uint256 price; // The price in wei
    }

    /**
     * - @dev A struct to store information about an auction.
     * - @param endTime The timestamp when the auction ends.
     * - @param highestBid The highest bid amount.
     * - @param highestBidder The address of the highest bidder.
     * - @param seller The address of the NFT owner.
     * - @param startingBid The minimum starting bid.
     * - @notice `endTime == 0` indicates that no auction exists.
     */
    struct Auction {
        address seller; // The address of the NFT owner
        address paymentToken; // address(0) = ETH, otherwise ERC-20 address
        uint256 startingBid; // The minimum price
        uint256 endTime; // The block timestamp when the auction ends
        address highestBidder; // The current highest bidder
        uint256 highestBid; // The current highest bid amount
    }

    ///////////////////
    //     Errors
    ///////////////////
    error PriceMustBeAboveZero();
    error NotOwner();
    error NotApprovedForMarketplace();
    error AuctionAlreadyExists();
    error ItemNotListed();
    error NotSeller();
    error IncorrectPrice();
    error TransferFailed();
    error DurationMustBeAboveZero();
    error AlreadyListed();
    error AuctionNotFound();
    error AuctionEnded();
    error BidBelowStartingPrice();
    error BidTooLow();
    error AuctionNotYetEnded();
    error NoBidsPlaced();
    error NoFundsToWithdrawETH();
    error NoFundsToWithdrawERC20();
    error FeeTooHigh();
    error BidAmountMismatch();
    error EthNotAcceptedForThisAuction();
    error InsufficientFunds();
    error InsufficientAllowance();
    error EthNotAcceptedForThisListing();
    error RecipientIsZeroAddress();
    error AuctionAlreadyStarted();

    ///////////////////////
    //  State Variables
    ///////////////////////
    // Mapping from NFT contract address to token ID to Listing details
    mapping(address => mapping(uint256 => Listing)) private s_listings;
    // Mapping from NFT contract address to token ID to Auction end time
    mapping(address => mapping(uint256 => Auction)) public s_auctions;
    // Mapping of pending withdrawals for outbid bidders
    mapping(address => uint256) public s_pendingWithdrawalsETH;
    // Mapping of Token Address => User Address => Pending ERC-20 withdrawal amount
    mapping(address => mapping(address => uint256)) public s_pendingWithdrawalsERC20;
    // Mapping to cache royalty support checks
    mapping(address => bool) private s_checkedRoyaltySupport;
    // Mapping to store whether a contract supports royalties
    mapping(address => bool) private s_supportsRoyalty;
    // Tracks total accumulated ERC20 fees per token.
    mapping(address => uint256) private s_accumulatedFeesERC20;

    /**
     * - @dev The EIP-2981 (royalty) interface ID.
     * - We check this ID to see if an NFT contract supports on-chain royalties.
     */
    bytes4 private constant _INTERFACE_ID_ERC2981 = 0x2a55205a;

    // The platform fee, in basis points (e.g., 500 = 5%)
    uint256 private s_platformFeePercent;
    // The address that receives platform fees
    address private s_platformFeeRecipient;
    // Added a max fee constant (e.g., 20% = 2000)
    uint256 private constant _MAX_PLATFORM_FEE = 2000; // 20%
    // Tracks total accumulated ETH fees.
    uint256 private s_accumulatedFeesETH;

    ///////////////////
    //     Events
    ///////////////////
    /**
     * - @dev Emitted when an item is listed for sale.
     * - @param seller The address of the NFT owner.
     * - @param nftContract The address of the NFT contract.
     * - @param paymentToken The address of the payment token (address(0) for ETH).
     * - @param tokenId The ID of the token listed.
     * - @param price The sale price.
     */
    event ItemListed(
        address indexed seller,
        address indexed nftContract,
        uint256 indexed tokenId,
        address paymentToken,
        uint256 price
    );

    /**
     * - @dev Emitted when a listing is cancelled.
     * - @param seller The address of the NFT owner.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token listed.
     */
    event ListingCancelled(address indexed seller, address indexed nftContract, uint256 indexed tokenId);

    /**
     * - @dev Emitted when an item is sold.
     * - @param seller The address of the NFT owner.
     * - @param buyer The address of the buyer.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token sold.
     * - @param price The sale price.
     */
    event ItemSold(
        address indexed seller, address indexed buyer, address indexed nftContract, uint256 tokenId, uint256 price
    );

    /**
     * - @dev Emitted when an auction is created.
     * - @param seller The address of the NFT owner.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token auctioned.
     * - @param startingBid The minimum starting bid.
     * - @param endTime The timestamp when the auction ends.
     */
    event AuctionCreated(
        address indexed seller,
        address indexed nftContract,
        uint256 indexed tokenId,
        address paymentToken,
        uint256 startingBid,
        uint256 endTime
    );

    /**
     * - @dev Emitted when a new bid is placed.
     * - @param bidder The address of the bidder.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token being bid on.
     * - @param amount The bid amount.
     */
    event NewBid(address indexed bidder, address indexed nftContract, uint256 indexed tokenId, uint256 amount);

    /**
     * - @dev Emitted when an auction ends.
     * - @param winner The address of the winning bidder.
     * - @param seller The address of the NFT owner.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token auctioned.
     * - @param amount The winning bid amount.
     */
    event AuctionHasEnded(
        address indexed winner, address indexed seller, address indexed nftContract, uint256 tokenId, uint256 amount
    );

    /**
     * - @dev Emitted when a user withdraws funds.
     * - @param user The address of the user.
     * - @param amount The amount withdrawn.
     */
    event WithdrawalETH(address indexed user, uint256 amount);

    /**
     * - @dev Emitted when a user withdraws ERC-20 tokens.
     * - @param user The address of the user.
     * - @param token The address of the ERC-20 token.
     * - @param amount The amount withdrawn.
     */
    event WithdrawalERC20(address indexed user, address indexed token, uint256 amount);

    /**
     * - @dev Emitted when a royalty payment is made.
     * - @param recipient The address of the royalty recipient.
     * - @param amount The royalty amount paid.
     */
    event RoyaltyPaid(address indexed recipient, uint256 amount);

    /**
     * - @dev Emitted when the platform fee is updated.
     * - @param newFeePercent The new platform fee in basis points.
     */
    event PlatformFeeUpdated(uint256 newFeePercent);

    /**
     * - @dev Emitted when the platform fee recipient is updated.
     * - @param newRecipient The address of the new fee recipient.
     */
    event PlatformFeeRecipientUpdated(address indexed newRecipient);

    /**
     * - @dev Emitted when a platform fee is paid.
     * - @param recipient The address of the fee recipient.
     * - @param amount The fee amount paid.
     */
    event PlatformFeePaid(address indexed recipient, uint256 amount);

    /**
     * - @dev Emitted when an auction is cancelled.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token from the auction.
     */
    event AuctionCancelled(address indexed nftContract, uint256 indexed tokenId);

    ///////////////////
    //   Constructor
    ///////////////////
    /**
     * - @dev Initializes the contract, setting the owner, initial platform fee, and the recipient for those fees.
     * - @param _initialFeePercent The starting fee in basis points (e.g., 250 = 2.5%).
     */
    constructor(uint256 _initialFeePercent) Ownable(msg.sender) {
        if (_initialFeePercent > _MAX_PLATFORM_FEE) revert FeeTooHigh();
        s_platformFeePercent = _initialFeePercent;
        s_platformFeeRecipient = msg.sender; // Default recipient is the deployer
    }

    ///////////////////
    // Fallback/Receive
    ///////////////////
    /**
     * - @dev Allows the contract to receive raw ETH.
     * - This ETH can be recovered by the owner using `withdrawStuckETH()`.
     */
    receive() external payable whenNotPaused {}

    fallback() external payable whenNotPaused {}

    ///////////////////
    //     Functions
    ///////////////////
    /**
     * - @dev Lists an NFT for a fixed-price sale.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token to list.
     * - @param price The sale price.
     * - Requirements:
     *     - `price` must be greater than 0.
     *     - `msg.sender` must own the `tokenId`.
     *     - The marketplace must be approved to transfer the `tokenId`.
     *     - The item must not already be in an auction.
     * - @notice Uses `whenNotPaused` modifier to prevent actions when paused.
     */
    function listItem(address nftContract, uint256 tokenId, address paymentToken, uint256 price)
        external
        whenNotPaused
    {
        if (price == 0) revert PriceMustBeAboveZero();
        if (s_auctions[nftContract][tokenId].endTime > 0) revert AuctionAlreadyExists();

        IERC721 nft = IERC721(nftContract);
        if (nft.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (nft.getApproved(tokenId) != address(this)) revert NotApprovedForMarketplace();

        s_listings[nftContract][tokenId] = Listing(msg.sender, paymentToken, price);
        emit ItemListed(msg.sender, nftContract, tokenId, paymentToken, price);
    }

    /**
     * - @dev Cancels a direct-sale listing.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token to cancel.
     * - @notice Requirements:
     * - The item must be listed.
     * - `msg.sender` must be the seller
     * - @notice Uses `whenNotPaused` modifier to prevent actions when paused.
     */
    function cancelListing(address nftContract, uint256 tokenId) external whenNotPaused {
        Listing memory listing = s_listings[nftContract][tokenId];
        if (listing.price == 0) revert ItemNotListed();
        if (listing.seller != msg.sender) revert NotSeller();

        delete s_listings[nftContract][tokenId];
        emit ListingCancelled(msg.sender, nftContract, tokenId);
    }

    /**
     * - @dev Buys a listed NFT.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token to buy.
     * - @notice Requirements:
     * - The item must be listed for sale.
     * - If buying with ETH, `msg.value` must equal the price.
     * - If buying with ERC-20, the buyer must have *approved* this contract to spend the required amount *before* calling this function.
     * - @notice Uses `nonReentrant` modifier to prevent re-entrancy attacks.
     * - @notice Uses `whenNotPaused` modifier to prevent actions when paused.
     */
    function buyItem(address nftContract, uint256 tokenId) external payable whenNotPaused nonReentrant {
        Listing memory listing = s_listings[nftContract][tokenId];
        if (listing.price == 0) revert ItemNotListed();
        if (listing.paymentToken == address(0)) {
            // --- ETH Payment ---
            if (msg.value != listing.price) revert IncorrectPrice();
        } else {
            // --- ERC-20 Payment ---
            if (msg.value > 0) revert EthNotAcceptedForThisListing(); // Ensure no ETH is sent

            // Pull ERC-20 tokens from buyer
            IERC20 token = IERC20(listing.paymentToken);
            if (token.balanceOf(msg.sender) < listing.price) revert InsufficientFunds();
            if (token.allowance(msg.sender, address(this)) < listing.price) revert InsufficientAllowance();

            // Use safeTransferFrom to securely pull tokens
            token.safeTransferFrom(msg.sender, address(this), listing.price);
        }

        // Delete the listing *before* payment to prevent re-entrancy.
        delete s_listings[nftContract][tokenId];

        // Handle payment to seller and creator (if royalties are supported)
        _handlePayment(nftContract, tokenId, listing.seller, listing.paymentToken, listing.price);

        // Transfer the NFT from the seller to the buyer
        IERC721(nftContract).transferFrom(listing.seller, msg.sender, tokenId);

        emit ItemSold(listing.seller, msg.sender, nftContract, tokenId, listing.price);
    }

    /**
     * - @dev Lists an NFT for auction.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token to auction.
     * - @param startingBid The minimum bid.
     * - @param duration The auction duration in seconds.
     * - @notice Requirements:
     * - `startingBid` must be greater than 0.
     * - `duration` must be greater than 0.
     * - `msg.sender` must own the `tokenId`.
     * - The marketplace must be approved to transfer the `tokenId`.
     * - The item must not already be listed for direct sale.
     * - @notice Uses `whenNotPaused` modifier to prevent actions when paused.
     */
    function listAuction(
        address nftContract,
        uint256 tokenId,
        address paymentToken,
        uint256 startingBid,
        uint256 duration
    ) external whenNotPaused {
        if (startingBid == 0) revert PriceMustBeAboveZero();
        if (duration == 0) revert DurationMustBeAboveZero();
        if (s_listings[nftContract][tokenId].price > 0) revert AlreadyListed();

        IERC721 nft = IERC721(nftContract);
        if (nft.getApproved(tokenId) != address(this)) revert NotApprovedForMarketplace();
        if (nft.ownerOf(tokenId) != msg.sender) revert NotOwner();

        uint256 endTime = block.timestamp + duration;
        s_auctions[nftContract][tokenId] = Auction(msg.sender, paymentToken, startingBid, endTime, address(0), 0);

        emit AuctionCreated(msg.sender, nftContract, tokenId, paymentToken, startingBid, endTime);
    }

    /**
     * - @dev Places a bid on an active auction.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token to bid on.
     * - @param amount The bid amount.
     * - @notice Requirements:
     * - The auction must exist and be active.
     * - The `msg.value` (bid) must be higher than the `startingBid` (if first bid).
     * - The `msg.value` must be higher than the `highestBid` (if not first bid).
     * - @notice Uses `nonReentrant` modifier.
     * - @notice Uses `whenNotPaused` modifier to prevent actions when paused.
     */
    function bid(address nftContract, uint256 tokenId, uint256 amount) external payable whenNotPaused nonReentrant {
        // --- 1. Checks ---
        Auction storage auction = s_auctions[nftContract][tokenId];
        if (auction.endTime == 0) revert AuctionNotFound();
        if (block.timestamp >= auction.endTime) revert AuctionEnded();

        uint256 bidAmount;
        if (auction.paymentToken == address(0)) {
            // --- ETH Bid ---
            if (amount != msg.value) revert BidAmountMismatch();
            bidAmount = msg.value;
        } else {
            // --- ERC-20 Bid ---
            if (msg.value > 0) revert EthNotAcceptedForThisAuction();
            bidAmount = amount;
        }

        bool isFirstBid = (auction.highestBidder == address(0));
        if (isFirstBid) {
            if (bidAmount < auction.startingBid) revert BidBelowStartingPrice();
        } else {
            if (bidAmount <= auction.highestBid) revert BidTooLow();
        }

        // --- 2. Effects ---
        // If there was a previous bidder, add their bid to pending withdrawals.
        if (!isFirstBid) {
            _refundPreviousBidder(auction.highestBidder, auction.paymentToken, auction.highestBid);
        }

        if (auction.paymentToken != address(0)) {
            // Pull ERC-20 funds
            IERC20 token = IERC20(auction.paymentToken);
            if (token.balanceOf(msg.sender) < bidAmount) revert InsufficientFunds();
            if (token.allowance(msg.sender, address(this)) < bidAmount) revert InsufficientAllowance();

            token.safeTransferFrom(msg.sender, address(this), bidAmount);
        }
        // For ETH bids, the funds are already held by the contract from msg.value.

        // Update the auction with the new highest bid.
        auction.highestBidder = msg.sender;
        auction.highestBid = bidAmount;

        // --- 3. Interactions ---
        emit NewBid(msg.sender, nftContract, tokenId, msg.value);
    }

    /**
     * - @dev Ends an auction after its duration has passed.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token from the auction.
     * - @notice Requirements:
     * - The auction must exist.
     * - The auction's `endTime` must be in the past.
     * - There must have been at least one bid.
     * - @notice Uses `nonReentrant` modifier.
     * - @notice Uses `whenNotPaused` modifier to prevent actions when paused.
     */
    function endAuction(address nftContract, uint256 tokenId) external whenNotPaused nonReentrant {
        // --- 1. Checks ---
        Auction memory auction = s_auctions[nftContract][tokenId];
        if (auction.endTime == 0) revert AuctionNotFound();
        if (block.timestamp < auction.endTime) revert AuctionNotYetEnded();
        if (auction.highestBidder == address(0)) revert NoBidsPlaced();

        // --- 2. Effects ---
        // Delete the auction *before* payment to prevent re-entrancy.
        delete s_auctions[nftContract][tokenId];

        // --- 3. Interactions ---
        // Handle payment to seller and creator (if royalties are supported)
        _handlePayment(nftContract, tokenId, auction.seller, auction.paymentToken, auction.highestBid);

        // Transfer the NFT from the seller to the winning bidder
        IERC721(nftContract).transferFrom(auction.seller, auction.highestBidder, tokenId);

        emit AuctionHasEnded(auction.highestBidder, auction.seller, nftContract, tokenId, auction.highestBid);
    }

    /**
     * - @dev Cancels an auction before any bids have been placed.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token from the auction.
     * - @notice Requirements:
     * - The auction must exist.
     * - `msg.sender` must be the seller.
     * - No bids must have been placed yet.
     * - @notice Uses `whenNotPaused` modifier to prevent actions when paused.
     */
    function cancelAuction(address nftContract, uint256 tokenId) external whenNotPaused {
        // --- 1. Checks ---
        Auction memory auction = s_auctions[nftContract][tokenId];
        if (auction.endTime == 0) revert AuctionNotFound();
        if (auction.seller != msg.sender) revert NotSeller();
        if (auction.highestBidder != address(0)) revert AuctionAlreadyStarted();

        // --- 2. Effects ---
        // Deletes the auction before first bid.
        delete s_auctions[nftContract][tokenId];

        // --- 3. Interactions ---
        emit AuctionCancelled(nftContract, tokenId);
    }

    /**
     * - @dev Allows users to withdraw funds (e.g., from being outbid).
     * - Follows the secure withdrawal pattern.
     */
    function withdrawETH() external nonReentrant {
        // --- 1. Checks ---
        uint256 amount = s_pendingWithdrawalsETH[msg.sender];
        if (amount == 0) revert NoFundsToWithdrawETH();

        // --- 2. Effects ---
        // Set to 0 *before* sending to prevent re-entrancy.
        s_pendingWithdrawalsETH[msg.sender] = 0;

        // --- 3. Interactions ---
        _safeTransferETH(msg.sender, amount);
        emit WithdrawalETH(msg.sender, amount);
    }

    /**
     * - @dev Allows users to withdraw ERC-20 tokens (e.g., from being outbid).
     * - @param token The address of the ERC-20 token to withdraw.
     */
    function withdrawERC20(address token) external nonReentrant {
        // --- 1. Checks ---
        uint256 amount = s_pendingWithdrawalsERC20[token][msg.sender];
        if (amount == 0) revert NoFundsToWithdrawERC20();

        // --- 2. Effects ---
        // Set to 0 *before* sending to prevent re-entrancy
        s_pendingWithdrawalsERC20[token][msg.sender] = 0;

        // --- 3. Interactions ---
        // Uses safe transfer
        IERC20(token).safeTransfer(msg.sender, amount);

        emit WithdrawalERC20(msg.sender, token, amount);
    }

    /**
     * - @dev Pauses the contract, halting major functions.
     * - @notice Only callable by the owner.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * - @dev Unpauses the contract, resuming major functions.
     * - @notice Only callable by the owner.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * - @dev Updates the platform fee percentage.
     * - @param newFeePercent The new fee in basis points (e.g., 300 = 3%).
     * - @notice Only callable by the owner.
     */
    function updatePlatformFee(uint256 newFeePercent) external onlyOwner {
        if (newFeePercent > _MAX_PLATFORM_FEE) revert FeeTooHigh();
        s_platformFeePercent = newFeePercent;
        emit PlatformFeeUpdated(newFeePercent);
    }

    /**
     * - @dev Updates the address that receives platform fees.
     * - @param newRecipient The address of the new fee recipient.
     * - @notice Only callable by the owner.
     */
    function updatePlatformFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert RecipientIsZeroAddress();
        s_platformFeeRecipient = newRecipient;
        emit PlatformFeeRecipientUpdated(newRecipient);
    }

    /**
     * - @dev Admin function to cancel a direct-sale listing.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token from the listing.
     * - @notice Only callable by the owner.
     */
    function adminCancelListing(address nftContract, uint256 tokenId) external onlyOwner {
        Listing memory listing = s_listings[nftContract][tokenId];
        if (listing.price == 0) revert ItemNotListed();

        delete s_listings[nftContract][tokenId];
        emit ListingCancelled(listing.seller, nftContract, tokenId);
    }

    /**
     * - @dev Admin function to cancel an auction.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token from the auction.
     * - @notice If a bid was placed, the highest bidder is refunded.
     * - @notice Only callable by the owner.
     */
    function adminCancelAuction(address nftContract, uint256 tokenId) external onlyOwner {
        Auction memory auction = s_auctions[nftContract][tokenId];
        if (auction.endTime == 0) revert AuctionNotFound();

        // Refund the highest bidder if one exists
        if (auction.highestBidder != address(0)) {
            _refundPreviousBidder(auction.highestBidder, auction.paymentToken, auction.highestBid);
        }

        delete s_auctions[nftContract][tokenId];
        emit AuctionCancelled(nftContract, tokenId);
    }

    /**
     * - @dev Allows the owner to withdraw any ETH accidentally sent to the contract.
     * - @notice This is for recovering stuck *funds*, not for platform fees (which are paid out automatically).
     * - @notice Only callable by the owner.
     */
    function withdrawStuckETH() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoFundsToWithdrawETH();
        _safeTransferETH(s_platformFeeRecipient, balance);
    }

    /**
     * - @dev Allows the owner to withdraw any ERC-20 tokens accidentally sent.
     * - @param token The address of the ERC-20 token to withdraw.
     * - @notice Only callable by the owner.
     */
    function withdrawStuckERC20(address token) external onlyOwner {
        IERC20 tokenContract = IERC20(token);
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert NoFundsToWithdrawERC20();
        tokenContract.safeTransfer(s_platformFeeRecipient, balance);
    }

    /**
     * - @dev Allows the owner to withdraw accumulated platform fees.
     * - @param token The address of the token to withdraw (address(0) for ETH).
     * - @notice Only callable by the owner.
     */
    function withdrawAccumulatedFees(address token) external onlyOwner {
        address recipient = s_platformFeeRecipient;
        if (token == address(0)) {
            uint256 amount = s_accumulatedFeesETH;
            require(amount > 0, "No ETH fees");
            s_accumulatedFeesETH = 0;
            (bool success,) = payable(recipient).call{value: amount}("");
            require(success, "ETH fee withdrawal failed");
        } else {
            uint256 amount = s_accumulatedFeesERC20[token];
            require(amount > 0, "No ERC20 fees");
            s_accumulatedFeesERC20[token] = 0;
            IERC20(token).transfer(recipient, amount);
        }
    }

    ///////////////////////////
    //   Internal Functions
    ///////////////////////////
    /**
     * - @dev Internal function to securely handle payments.
     * - @notice This function contains the EIP-165 check for EIP-2981 royalties.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token.
     * - @param seller The address of the seller.
     * - @param price The total sale price.
     */
    function _handlePayment(address nftContract, uint256 tokenId, address seller, address paymentToken, uint256 price)
        private
    {
        // --- 1. Calculate Platform Fee ---
        uint256 platformFee = (price * s_platformFeePercent) / 10000;

        // --- 2. Calculate Royalty ---
        uint256 royaltyAmount = 0;
        address royaltyRecipient = address(0);

        // --- The EIP-165 Check ---
        // This will handle:
        // 1. Contracts that support EIP-2981 (returns true).
        // 2. Contracts that support EIP-165 but NOT EIP-2981 (returns false).
        // 3. Contracts that don't support EIP-165 at all (reverts, caught by `catch`).
        // Check cache first
        if (!s_checkedRoyaltySupport[nftContract]) {
            // We haven't checked this contract before.
            s_checkedRoyaltySupport[nftContract] = true; // Mark as checked
            try IERC165(nftContract).supportsInterface(_INTERFACE_ID_ERC2981) returns (bool isSupported) {
                if (isSupported) {
                    // It is supported, save this result
                    s_supportsRoyalty[nftContract] = true;
                }
            } catch {
                // If the call reverts, it doesn't support it.
                // s_supportsRoyalty[nftContract] remains false (default)
            }
        }

        // Now, read from the cache
        if (s_supportsRoyalty[nftContract]) {
            // We know this contract supports EIP-2981, so it's safe to call royaltyInfo
            // We still need a 'try/catch' in case the royaltyInfo function itself reverts
            try IERC2981(nftContract).royaltyInfo(tokenId, price) returns (address rec, uint256 amt) {
                royaltyRecipient = rec;
                royaltyAmount = amt;
            } catch {
                // Handle a faulty royaltyInfo implementation
                royaltyAmount = 0;
            }
        }

        // --- 3. Payout Calculation & Transfer ---

        // Sanity check: Royalties should never be 100% or more.
        if (royaltyAmount >= price) {
            royaltyAmount = 0; // In this case, just pay the seller.
        }

        // Sanity check: Fees + Royalties should not be >= 100%.
        if (platformFee + royaltyAmount >= price) {
            // In this case, prioritize royalty, then fee. Seller gets 0.
            // This should rarely happen with sane values.
            if (platformFee >= price) platformFee = 0; // Fee config is wrong
            if (royaltyAmount >= price) royaltyAmount = 0; // NFT config is wrong

            if (platformFee + royaltyAmount >= price) {
                // Prioritize royalty. Fee is reduced to what's left.
                royaltyAmount = (royaltyAmount < price) ? royaltyAmount : price;
                platformFee = price - royaltyAmount;
            }
        }

        uint256 sellerPayout = price - royaltyAmount - platformFee;

        // --- 4. Payouts ---

        // Pay platform fee
        if (platformFee > 0) {
            if (paymentToken == address(0)) {
                s_accumulatedFeesETH += platformFee;
            } else {
                s_accumulatedFeesERC20[paymentToken] += platformFee;
            }
            emit PlatformFeePaid(s_platformFeeRecipient, platformFee);
        }

        // Pay royalty
        if (royaltyAmount > 0) {
            _safeTransferToken(paymentToken, royaltyRecipient, royaltyAmount);
            emit RoyaltyPaid(royaltyRecipient, royaltyAmount);
        }

        // Pay seller
        if (sellerPayout > 0) {
            _safeTransferToken(paymentToken, seller, sellerPayout);
        }
    }

    /**
     * - @dev Internal function to safely send Ether.
     * - @param to The recipient address.
     * - @param amount The amount.
     */
    function _safeTransferETH(address to, uint256 amount) private {
        (bool success,) = payable(to).call{value: amount}("");
        if (!success) revert TransferFailed();
    }

    /**
     * - @dev Internal function to transfer either ETH or an ERC-20 token.
     * - @notice Assumes the contract *holds* the tokens if it's an ERC-20.
     * - @param token The address of the token (address(0) for ETH).
     * - @param to The recipient address.
     * - @param amount The amount.
     */
    function _safeTransferToken(address token, address to, uint256 amount) private {
        if (token == address(0)) {
            // It's ETH
            _safeTransferETH(to, amount);
        } else {
            // It's ERC-20
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /**
     * - @dev Internal function to add a user's refund to the pending withdrawals.
     */
    function _refundPreviousBidder(address bidder, address paymentToken, uint256 amount) private {
        if (paymentToken == address(0)) {
            s_pendingWithdrawalsETH[bidder] += amount;
        } else {
            s_pendingWithdrawalsERC20[paymentToken][bidder] += amount;
        }
    }

    ///////////////////////////
    //   Getter Functions
    ///////////////////////////
    /**
     * - @dev Returns the listing details for a given NFT.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token.
     * - @return The Listing struct containing seller and price.
     */
    function getListing(address nftContract, uint256 tokenId) external view returns (Listing memory) {
        return s_listings[nftContract][tokenId];
    }

    /**
     * - @dev Returns the auction details for a given NFT.
     * - @param nftContract The address of the NFT contract.
     * - @param tokenId The ID of the token.
     * - @return The Auction struct containing auction details.
     */
    function getAuction(address nftContract, uint256 tokenId) external view returns (Auction memory) {
        return s_auctions[nftContract][tokenId];
    }

    /**
     * - @dev Returns the pending ETH withdrawal amount for a user.
     * - @param user The address of the user.
     * - @return The pending withdrawal amount.
     */
    function getPendingWithdrawalsETH(address user) external view returns (uint256) {
        return s_pendingWithdrawalsETH[user];
    }

    /**
     * - @dev Returns the pending ERC-20 withdrawal amount for a user.
     * - @param token The address of the ERC-20 token.
     * - @param user The address of the user.
     * - @return The pending withdrawal amount.
     */
    function getPendingWithdrawalsERC20(address token, address user) external view returns (uint256) {
        return s_pendingWithdrawalsERC20[token][user];
    }

    /**
     * - @dev Returns the current platform fee and recipient.
     * - @return recipient The address receiving platform fees.
     * - @return feePercent The platform fee in basis points.
     */
    function getPlatformFeeInfo() external view returns (address recipient, uint256 feePercent) {
        return (s_platformFeeRecipient, s_platformFeePercent);
    }

    /**
     * - @dev Returns the total accumulated fees in ETH and ERC-20 tokens.
     * - @return The accumulated fees.
     */
    function getAccumulatedFeesETH() external view returns (uint256) {
        return s_accumulatedFeesETH;
    }

    /**
     * - @dev Returns the total accumulated fees for a specific ERC-20 token.
     * - @param token The address of the ERC-20 token.
     * - @return The accumulated fees for the token.
     */
    function getAccumulatedFeesERC20(address token) external view returns (uint256) {
        return s_accumulatedFeesERC20[token];
    }
}
