# 🏪 SuperMart

**SuperMart** is a fully on-chain **NFT marketplace** supporting both fixed-price sales and auctions.
It accepts **ETH and any ERC-20 token** as payment, implements EIP-2981 royalty support, includes platform fees, and provides robust admin controls with pause, withdraw, and emergency functions.

---

## ⚙️ Overview

SuperMart simplifies NFT trading by combining **modular design**, **secure payment handling**, and **developer-friendly tooling** powered by **Foundry**.

## Key Features

* Fixed-price NFT listings
* Timed auctions (ETH or ERC-20)
* Configurable platform fees
* EIP-2981 royalty support
* Pausable and onlyOwner admin controls
* Safe withdrawal of stuck ETH or tokens
* Fallback and receive functions for ETH

---

## Core Functions

**Sales**

* `listItem()` — List NFT for sale
* `buyItem()` — Purchase a listed NFT
* `cancelListing()` — Cancel an active listing

**Auctions**

* `listAuction()` — Start an auction
* `bid()` — Place a bid
* `endAuction()` — End and settle an auction
* `cancelAuction()` — Cancel if no bids yet

**Admin**

* `updatePlatformFee()` — Change platform fee
* `updateFeeRecipient()` — Update fee recipient
* `pause()` / `unpause()` — Emergency control
* `withdrawStuckETH()` / `withdrawStuckERC20()` — Recover assets

---

## 🧱 Architecture

### Smart Contracts
```
SuperMart/
├── src/
│ ├── SuperMart.sol # Core NFT Marketplace logic
│
├── script/
│ └── DeploySuperMart.s.sol # Foundry deployment script
│
├── test/
│ ├── invariants/
│ │ ├── Handler.sol # State handler for fuzz tests
│ │ └── SuperMart.invariant.t.sol# Invariant test suite
│ ├── mocks/
│ │ ├── MockERC20.sol # Mock ERC-20 token for testing
│ │ ├── MockERC721.sol # Mock ERC-721 NFT for testing
│ │ ├── MockRoyaltyNFT.sol # Mock NFT with royalties
│ │ ├── MockMaliciousRoyaltyNFT.sol # Malicious royalty NFT (for edge cases)
│ │ └── MockRevertingNFT.sol # NFT that reverts (failure tests)
│ └── unit/
│ ├── DeploySuperMartTest.t.sol# Unit test for deployment
│ └── SuperMartTest.t.sol # Core marketplace test suite
```

---

## 🧰 Tech Stack

- **Smart Contracts:** Solidity ^0.8.20, Foundry, OpenZeppelin  
- **Testing Framework:** Forge (fuzzing, invariants, unit tests)  
- **Token Standards:** ERC-20, ERC-721, ERC165, ERC2981  
- **Security:** Reentrancy guards, withdrawal pools, `onlyOwner` controls  
- **Language:** Solidity + Forge Stdlib  
- **Version Control:** GitHub + Foundry broadcast artifacts  

---

## 🧩 Installation

Clone the repository and install the neccesary dependencies:

```
# Clone the repository
git clone https://github.com/<your-username>/SuperMart.git
cd SuperMart

# Install Foundry dependencies
forge install

# Install additional libraries
forge install OpenZeppelin/openzeppelin-contracts

# Build the contracts:
forge build
```

---

## Dependencies

* OpenZeppelin Contracts v5+
    * Ownable
    * ReentrancyGuard
    * SafeERC20
    * IERC721
    * IERC20
    * IERC2981
    * IERC165
    * Pausable

---

## 🧑‍💻 Development

Run local compilation
```
forge build
```

Run tests
```
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test
forge test --mt <the_test_name>
```

Generate coverage reports
```
forge coverage
```

---

## 🚀 Deployment & Verification

Set Environment Variables
```
RPC_URL=<your_rpc_url>
ETHERSCAN_API_KEY=<your_api_key>
INITIAL_FEE_BPS=<platform_fee_in_bps>
```

Deploy Locally
```
# Start local Anvil node
anvil

# Deploy contracts (in another terminal)
forge script script/DeploySuperMart.s.sol --rpc-url http://localhost:8545 --broadcast
```

Deploy and Verify SuperMart using imported wallet
```
forge script script/DeploySuperMart.s.sol \
  --rpc-url $RPC_URL \
  --account <your_account_name> \
  --sender <your_wallet_address> \
  --broadcast
  --verify
```

---

## 🧾 License

This project is licensed under the MIT License.

---

## 🤝 Contributing

Contributions, issues, and feature requests are welcome!

---

## 👤 Author

Boma Ogolo
Smart Contract Developer | Solidity | Foundry