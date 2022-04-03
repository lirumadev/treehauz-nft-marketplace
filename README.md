# Treehauz NFT Marketplace
This is a project for me to showcase my smart contract knowledge in order for me to get a full time professional job in web3 space. This NFT marketplace allow user to **mint and trade NFTs across different platforms' smart contracts** in the same chain network (EVM-compatible only). It supports **ERC-721** and **ERC-1155**.

# Factory contracts
TreehauzSingleNFT.sol implements ERC-721 token and TreehauzGroupNFT.sol implements ERC-1155 token. Both factory contracts allow users to mint and burn tokens. **Special features** are both contracts allowing users to **set and update multiple royalty receivers for each tokens**.

# Marketplace contract
MainMarketplace.sol is the marketplace contract. This contract allow users to list or delist, make or accept offer, and purchase NFTs. All sales transactions will be handled by this contract including **splitting of royalty payments**. This contract implements **pull-over-push pattern** where every sales and royalties are being accumulated and need to be claimed by seller and royalty receivers. This approach is to **minimize direct interaction with external contracts** for security reasons and it also **saves a lot of gas fees** especially when the tokens has long list of royalty receivers. This contract **act as an escrow contract for holding NFTs** that being listed on the martketplace. It will handle marketplace earning by transferring the marketplace transactions fees to the marketplace owner (best to use Gnosis Safe multisig wallet).

# Escrow custodial contract
TreehauzEscrow.sol is the escrow contract. This contract will **hold Ethers from all transactions** (except marketplace earning which will direct transfer to marketplace owner). Marketplace contract will interact with this contract by sending Ethers retrieved from sales and offers, and sending Ethers for claiming sales and royalties.

# Development notes
This NFT marketplace project implements **multiple best practices smart contract development patterns and methods** that you can discover in the codes.
* Upgradeable proxy contract
* Factory pattern
* Check-effect-interactions pattern
* Pull-over-push pattern
* Emergency stop to pause all marketplace or creator activities
* Modifier as access restrictions
* Tight variable packing for gas optimization

# Security test
All smart contracts has been tested and fuzzed using **Slither**. First ever test of all contracts only found one critical issue where marketplace contract should not use .call() for external contract royalty payment which can cause reentrancy. This should not be a real issue as this contract implement nonReentrant modifier to avoid recursive function call until it is fully executed.
