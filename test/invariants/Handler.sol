// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {SuperMart} from "../../src/SuperMart.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @title Handler for SuperMart Invariant Testing
 * @notice This contract is the "agent" that Foundry's fuzzer will call.
 * @dev It simulates actions from a pool of different users.
 * It holds its own state to mirror the marketplace's state, which allows us to write
 * complex invariants that would be too gas-intensive to check on-chain directly.
 */
contract Handler is Test {
    ///////////////////////////
    //   State Variables
    ///////////////////////////
    SuperMart internal marketplace;
    MockERC721 internal nft;
    MockERC20 internal erc20;

    // A pool of users to simulate actions
    address[] internal users;
    address public constant OWNER = address(0x1); // Marketplace Owner
    address public constant FEE_RECIPIENT = address(0x2);

    // Max number of token IDs the fuzzer will interact with
    uint256 internal constant FUZZ_TOKEN_ID_RANGE = 50;

    /////////////////////////////
    //   Handler State Mirror
    /////////////////////////////

    // These variables mirror the marketplace's state to make invariant checking cheaper and easier.

    // s_isMinted[tokenId]
    mapping(uint256 => bool) public s_isMinted;
    // s_nftOwner[tokenId] -> user
    mapping(uint256 => address) public s_nftOwner;
    // s_isListed[tokenId]
    mapping(uint256 => bool) public s_isListed;
    // s_isAuctioned[tokenId]
    mapping(uint256 => bool) public s_isAuctioned;
    // s_activeBids[paymentToken][tokenId] -> amount
    mapping(address => mapping(uint256 => uint256)) public s_activeBids;

    ///////////////////////////
    //   Functions
    ///////////////////////////

    constructor(SuperMart _marketplace, MockERC721 _nft, MockERC20 _erc20) {
        marketplace = _marketplace;
        nft = _nft;
        erc20 = _erc20;

        // Create a pool of 3 users
        users.push(address(0x100));
        users.push(address(0x200));
        users.push(address(0x300));

        // Fund all users with ETH and ERC20 tokens
        for (uint256 i = 0; i < users.length; i++) {
            vm.deal(users[i], 100 ether);
            erc20.mint(users[i], 1_000_000 * 1e18);
        }
    }

    /**
     * @notice Simulates a user listing an NFT for ETH.
     * @param _seed The random number from the fuzzer.
     */
    function listItemETH(uint256 _seed) public {
        uint256 tokenId = _pickTokenId(_seed);
        address seller = s_isMinted[tokenId] ? s_nftOwner[tokenId] : _pickUser(_seed);
        uint256 price = bound(_seed, 1, 10 ether);

        _mintAndApproveIfMissing(seller, tokenId);

        vm.prank(seller);
        // We use `try/catch` so the fuzzer continues even on expected reverts
        try marketplace.listItem(address(nft), tokenId, address(0), price) {
            // --- On Success, update handler state ---
            s_isListed[tokenId] = true;
        } catch {}
    }

    /**
     * @notice Simulates a user listing an NFT for ERC20.
     * @param _seed The random number from the fuzzer.
     */
    function listItemERC20(uint256 _seed) public {
        uint256 tokenId = _pickTokenId(_seed);
        address seller = s_isMinted[tokenId] ? s_nftOwner[tokenId] : _pickUser(_seed);
        uint256 price = bound(_seed, 1, 10_000 * 1e18);

        _mintAndApproveIfMissing(seller, tokenId);

        vm.prank(seller);
        try marketplace.listItem(address(nft), tokenId, address(erc20), price) {
            // --- On Success, update handler state ---
            s_isListed[tokenId] = true;
        } catch {}
    }

    /**
     * @notice Simulates a user cancelling a listing.
     * @param _seed The random number from the fuzzer.
     */
    function cancelListing(uint256 _seed) public {
        uint256 tokenId = _pickTokenId(_seed);
        if (!s_isListed[tokenId]) return; // Ghost call

        address seller = s_nftOwner[tokenId];

        vm.prank(seller);
        try marketplace.cancelListing(address(nft), tokenId) {
            // --- On Success, update handler state ---
            s_isListed[tokenId] = false;
        } catch {}
    }

    /**
     * @notice Simulates a user buying an NFT with ETH.
     * @param _seed The random number from the fuzzer.
     */
    function buyItemETH(uint256 _seed) public {
        uint256 tokenId = _pickTokenId(_seed);
        if (!s_isListed[tokenId]) return; // Ghost call

        address buyer = _pickUser(_seed);
        SuperMart.Listing memory listing = marketplace.getListing(address(nft), tokenId);

        // Ensure it's a valid, ETH-based listing and not self-buying
        if (listing.price == 0 || listing.paymentToken != address(0) || buyer == listing.seller) {
            return;
        }

        // Ensure buyer has enough ETH
        if (buyer.balance < listing.price) {
            vm.deal(buyer, listing.price);
        }

        vm.prank(buyer);
        try marketplace.buyItem{value: listing.price}(address(nft), tokenId) {
            // --- On Success, update handler state ---

            s_isListed[tokenId] = false;
            s_nftOwner[tokenId] = buyer;
        } catch {}
    }

    /**
     * @notice Simulates a user buying an NFT with ERC20.
     * @param _seed The random number from the fuzzer.
     */
    function buyItemERC20(uint256 _seed) public {
        uint256 tokenId = _pickTokenId(_seed);
        if (!s_isListed[tokenId]) return; // Ghost call

        address buyer = _pickUser(_seed);
        SuperMart.Listing memory listing = marketplace.getListing(address(nft), tokenId);

        if (listing.price == 0 || listing.paymentToken != address(erc20) || buyer == listing.seller) {
            return;
        }

        // Ensure buyer has enough ERC20 balance — mint difference if needed for fuzzing
        uint256 bal = erc20.balanceOf(buyer);
        if (bal < listing.price) {
            erc20.mint(buyer, listing.price - bal);
        }

        // Buyer must approve the ERC20 token transfer
        vm.prank(buyer);
        erc20.approve(address(marketplace), type(uint256).max);

        vm.prank(buyer);
        try marketplace.buyItem(address(nft), tokenId) {
            // --- On Success, update handler state ---
            s_isListed[tokenId] = false;
            s_nftOwner[tokenId] = buyer;
        } catch {}
    }

    /**
     * @notice Simulates a user listing an NFT for auction with ETH.
     * @param _seed The random number from the fuzzer.
     */
    function listAuctionETH(uint256 _seed) public {
        uint256 tokenId = _pickTokenId(_seed);
        address seller = s_isMinted[tokenId] ? s_nftOwner[tokenId] : _pickUser(_seed);
        uint256 startingBid = bound(_seed, 1, 1 ether);
        uint256 duration = bound(_seed, 60, 60 * 60 * 24); // 1min - 1day

        _mintAndApproveIfMissing(seller, tokenId);

        vm.prank(seller);
        try marketplace.listAuction(address(nft), tokenId, address(0), startingBid, duration) {
            // --- On Success, update handler state ---
            s_isAuctioned[tokenId] = true;
        } catch {}
    }

    /**
     * @notice Simulates a user listing an NFT for auction with ERC20.
     * @param _seed The random number from the fuzzer.
     */
    function listAuctionERC20(uint256 _seed) public {
        uint256 tokenId = _pickTokenId(_seed);
        address seller = s_isMinted[tokenId] ? s_nftOwner[tokenId] : _pickUser(_seed);
        uint256 startingBid = bound(_seed, 1, 1000 * 1e18);
        uint256 duration = bound(_seed, 60, 60 * 60 * 24); // 1min - 1day

        _mintAndApproveIfMissing(seller, tokenId);

        vm.prank(seller);
        try marketplace.listAuction(address(nft), tokenId, address(erc20), startingBid, duration) {
            // --- On Success, update handler state ---
            s_isAuctioned[tokenId] = true;
        } catch {}
    }

    /**
     * @notice Simulates a user bidding on an ETH auction.
     * @param _seed The random number from the fuzzer.
     */
    function bidETH(uint256 _seed) public {
        uint256 tokenId = _pickTokenId(_seed);
        if (!s_isAuctioned[tokenId]) return; // Ghost call

        SuperMart.Auction memory auction = marketplace.getAuction(address(nft), tokenId);
        if (auction.endTime == 0 || auction.paymentToken != address(0) || block.timestamp >= auction.endTime) {
            return;
        }

        address bidder = _pickUser(_seed);
        if (bidder == auction.seller) return;

        // Bid 10% over the highest bid, or the starting bid
        uint256 minBid = auction.highestBid == 0 ? auction.startingBid : (auction.highestBid * 110) / 100;

        // Add a check to prevent overflow on the minBid calculation
        if (auction.highestBid > type(uint256).max / 110) {
            return; // Bid is too high, just skip this fuzzer run
        }

        // Cap the maximum bid to something sane relative to minBid (e.g., +100 ETH)
        uint256 cappedMax = minBid + 100 ether;
        // Ensure cappedMax >= minBid (guard against tiny values)
        if (cappedMax < minBid) cappedMax = minBid;

        uint256 bidAmount = bound(_seed, minBid, minBid + 1 ether);

        vm.deal(bidder, bidAmount); // Ensure bidder has enough ETH

        vm.prank(bidder);
        try marketplace.bid{value: bidAmount}(address(nft), tokenId, bidAmount) {
            // --- On Success, update handler state ---
            s_activeBids[address(0)][tokenId] = bidAmount;
        } catch {}
    }

    /**
     * @notice Simulates a user bidding on an ERC20 auction.
     * @param _seed The random number from the fuzzer.
     */
    function bidERC20(uint256 _seed) public {
        uint256 tokenId = _pickTokenId(_seed);
        if (!s_isAuctioned[tokenId]) return; // Ghost call

        SuperMart.Auction memory auction = marketplace.getAuction(address(nft), tokenId);
        if (auction.endTime == 0 || auction.paymentToken != address(erc20) || block.timestamp >= auction.endTime) {
            return;
        }

        address bidder = _pickUser(_seed);
        if (bidder == auction.seller) return;

        // Bid 10% over the highest bid, or the starting bid
        uint256 minBid = auction.highestBid == 0 ? auction.startingBid : (auction.highestBid * 110) / 100;

        // Prevent overflow and cap the top to a sane value (e.g., +100k tokens)
        if (auction.highestBid > type(uint256).max / 110) {
            return;
        }
        uint256 cappedMax = minBid + (100_000 * 1e18);
        if (cappedMax < minBid) cappedMax = minBid;

        uint256 bidAmount = bound(_seed, minBid, cappedMax);

        // Approve ERC20 transfer
        vm.prank(bidder);
        erc20.approve(address(marketplace), bidAmount);

        vm.prank(bidder);
        try marketplace.bid(address(nft), tokenId, bidAmount) {
            unchecked {
                // --- On Success, update handler state ---
                s_activeBids[address(erc20)][tokenId] = bidAmount;
            }
        } catch {}
    }

    /**
     * @notice Simulates ending an auction (can be called by anyone).
     * @param _seed The random number from the fuzzer.
     */
    function endAuction(uint256 _seed) public {
        uint256 tokenId = _pickTokenId(_seed);
        if (!s_isAuctioned[tokenId]) return; // Ghost call

        SuperMart.Auction memory auction = marketplace.getAuction(address(nft), tokenId);
        if (auction.endTime == 0 || block.timestamp < auction.endTime || auction.highestBidder == address(0)) {
            return;
        }

        // Fast-forward time to be just after the auction ends
        vm.warp(auction.endTime + 1);

        address caller = _pickUser(_seed); // Anyone can call endAuction
        vm.prank(caller);
        try marketplace.endAuction(address(nft), tokenId) {
            s_isAuctioned[tokenId] = false;
            s_nftOwner[tokenId] = auction.highestBidder;
            s_activeBids[auction.paymentToken][tokenId] = 0;
        } catch {}
    }

    /**
     * @notice Simulates a user withdrawing their pending ETH.
     * @param _seed The random number from the fuzzer.
     */
    function withdrawETH(uint256 _seed) public {
        address user = _pickUser(_seed);
        // 1. Get the amount *before* withdrawing
        uint256 amountToWithdraw = marketplace.getPendingWithdrawalsETH(user);
        if (amountToWithdraw == 0) return;

        vm.prank(user);
        try marketplace.withdrawETH() {} catch {}
    }

    /**
     * @notice Simulates a user withdrawing their pending ERC20.
     * @param _seed The random number from the fuzzer.
     */
    function withdrawERC20(uint256 _seed) public {
        address user = _pickUser(_seed);
        address token = address(erc20);

        // 1. Get the amount *before* withdrawing
        uint256 amountToWithdraw = marketplace.getPendingWithdrawalsERC20(token, user);
        if (amountToWithdraw == 0) {
            return;
        }

        vm.prank(user);
        try marketplace.withdrawERC20(address(erc20)) {} catch {}
    }

    /**
     * @notice Simulates the owner updating the platform fee.
     * @param _seed The random number from the fuzzer.
     */
    function updatePlatformFee(uint256 _seed) public {
        // Fuzz fees from 0% to 25% (20% is max, so 25% tests the revert)
        uint256 newFee = _seed % 2501;

        vm.prank(OWNER);
        try marketplace.updatePlatformFee(newFee) {
        // Success, fee was updated
        }
            catch {}
    }

    // === Accounting Helpers for Invariants ===
    // These functions must be `public` so the Invariant Test contract can call them.

    /**
     * @dev Calculates the total ETH held in active bids by reading the marketplace directly.
     */
    function totalActiveETHBids() public view returns (uint256 total) {
        for (uint256 i = 0; i < FUZZ_TOKEN_ID_RANGE; i++) {
            SuperMart.Auction memory auction = marketplace.getAuction(address(nft), i);
            if (auction.paymentToken == address(0)) {
                total += auction.highestBid;
            }
        }
        return total;
    }

    /**
     * @dev Calculates the total ERC20 held in active bids by reading the marketplace directly.
     */
    function totalActiveERC20Bids(address _token) public view returns (uint256 total) {
        for (uint256 i = 0; i < FUZZ_TOKEN_ID_RANGE; i++) {
            SuperMart.Auction memory auction = marketplace.getAuction(address(nft), i);
            if (auction.paymentToken == _token) {
                total += auction.highestBid;
            }
        }
        return total;
    }

    /**
     * @dev Calculates total pending ETH withdrawals + platform fees.
     */
    function totalPendingETHWithdrawals() public view returns (uint256 total) {
        // Sum all user pending withdrawals
        for (uint256 i = 0; i < users.length; i++) {
            total += marketplace.getPendingWithdrawalsETH(users[i]);
        }

        // Add unwithdrawn platform fees (marketplace revenue)
        total += marketplace.getAccumulatedFeesETH();

        return total;
    }

    /**
     * @dev Calculates total pending ERC20 withdrawals + platform fees.
     */
    function totalPendingERC20Withdrawals(address _token) public view returns (uint256 total) {
        for (uint256 i = 0; i < users.length; i++) {
            total += marketplace.getPendingWithdrawalsERC20(_token, users[i]);
        }

        // Add unwithdrawn platform fees for this token
        total += marketplace.getAccumulatedFeesERC20(_token);

        return total;
    }

    /**
     * @dev Exposes the fuzz range to the test contract.
     */
    function fuzzTokenIdRange() public pure returns (uint256) {
        return FUZZ_TOKEN_ID_RANGE;
    }

    ///////////////////////////
    //   Internal Functions
    ///////////////////////////

    /**
     * @dev Picks a random user from the pool using the fuzzer's `_seed`.
     */
    function _pickUser(uint256 _seed) internal view returns (address) {
        return users[_seed % users.length];
    }

    /**
     * @dev Picks a random token ID within the fuzzing range using `_seed`.
     */
    function _pickTokenId(uint256 _seed) internal pure returns (uint256) {
        return _seed % FUZZ_TOKEN_ID_RANGE;
    }

    /**
     * @dev Mints an NFT to a user and approves the marketplace, if not already done.
     */
    function _mintAndApproveIfMissing(address _user, uint256 _tokenId) internal {
        if (!s_isMinted[_tokenId]) {
            vm.prank(OWNER); // Use a central minter
            nft.mint(_user, _tokenId);
            s_isMinted[_tokenId] = true;
            s_nftOwner[_tokenId] = _user;
        }

        // The current owner must always approve
        address currentOwner = s_nftOwner[_tokenId];
        vm.prank(currentOwner);
        nft.approve(address(marketplace), _tokenId);
    }
}
