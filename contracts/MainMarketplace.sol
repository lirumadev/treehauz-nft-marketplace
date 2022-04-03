// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "./TreehauzSingleNFT.sol";
import "./TreehauzGroupNFT.sol";
import "./TreehauzEscrow.sol";

import "hardhat/console.sol";

error InvalidResetRoyalyWithUnclaimedRoyalty(address[] receiver, uint256[] unclaimedAmount);
error InvalidPriceLessThanMinimumPrice(uint256 price);
error InvalidQuantityLessThanMinimumQuantity(uint256 quantity);
error NonExistingListing(uint256 listingId);
error InsufficientListingQuantity(uint256 quantityWanted, uint256 listingQuantity);
error InvalidPurchasePrice(uint256 purchasePrice, uint256 totalListingPrice);
error NonExistingOrCancelledOrRejectedOffer(uint256 listingId, address offeror);
error InvalidAcceptOfferPrice(uint256 acceptedPrice, uint256 offerPrice);

contract MainMarketplace is
    Initializable,
    ReentrancyGuardUpgradeable,
    ContextUpgradeable,
    OwnableUpgradeable
    
{    
    /// @dev Type of the tokens that can be listed for sale.
    enum TokenType {
        ERC1155,
        ERC721
    }

    /**
    * @dev For use in `createListing` as a parameter type.
    *      assetContract is external contract address and relate with tokenId of the external contract 
    *      Total price must be computed by multiplying quantityWanted with pricePerToken
    */
    struct ListingParameters {
        address assetContract;
        uint64 quantityToList;
        uint256 tokenId;
        uint256 buyoutPricePerToken;
    }

    // Listing of marketItem
    struct Listing {
        uint256 tokenId; // 32b
        address tokenOwner; // 20b
        address assetContract; // 20b
        uint64 quantity;
        uint256 buyoutPricePerToken;
        TokenType tokenType;
    }

    /// @dev reserve storage space for Listing
    uint256[10] __reserveAttrUint;
    string[10] __reserveAttrStr;
    address[10] __reserveAttrAddr;

    /**
    * @dev The information related to an offer on a direct listing
    *      Total price must be computed by multiplying quantityWanted with pricePerToken
    */
    struct Offer {
        address offeror;
        uint64 quantityWanted;
        uint256 pricePerToken;
    }

    /// @dev Account info for royalty payment
    struct AccountInfo {
        address owner;
        uint256 unclaimedRoyalty;
        uint256 claimedRoyalty;
    }

    struct TokenRoyaltyInfo {
        uint256 totalAmount;
        // address => address' claimed amount
        mapping(address => uint256) claimedAmount;
    }

    /// @dev Checks whether caller is a royalty account owner.
    modifier onlyAccountOwner() {
        // require(accountClaimedRoyalty[_msgSender()] > 0, "Marketplace: account does not have any royalty.");
        _;
    }

    /// @dev Checks whether caller is a listing creator.
    modifier onlyListingCreator(uint256 _listingId) {
        require(listings[_listingId].tokenOwner == _msgSender(), 
                "Marketplace: caller is not listing owner.");
        _;
    }

    /// @dev Checks whether caller are from Treehauz contracts
    modifier selectedCaller() {
        require(_msgSender() == address(_treehauzNFT) || _msgSender() == address(_treehauzGrpNFT), 
                "Marketplace: caller is not valid");
        _;
    }

    /// Treehauz ERC-721 NFT contract
    TreehauzSingleNFT private _treehauzNFT;

    /// Treehauz ERC-1155 NFT contract
    TreehauzGroupNFT private _treehauzGrpNFT;

    /// Treehauz Escrow contract
    address payable private _escrow;

    /// @dev Total number of listings on market.
    uint256 public totalListings;

    /// @dev The max bps of the contract. So, 100000 == 100 %
    uint64 private constant MAX_BPS = 100000;

    /// @dev The marketplace fee.
    uint64 private marketFeeBps;

    /// @dev The minimum amount of time left in an auction after a new bid is created. Default: 15 minutes.
    uint64 private timeBuffer;

    /// @dev The minimum % increase required from the previous winning bid. Default: 5%.
    uint64 private bidBufferBps;

    /// @dev pausing activity
    bool public paused;

    /// @dev address => pause state
    mapping(address => bool) private sellerPaused;

    /// @dev listingId => listing info.
    mapping(uint256 => Listing) private listings;

    /// @dev tokenId => contract address => listingId
    mapping(uint256 => mapping(address => uint256)) private listingTokenId;

    /// @dev listingId => address => offer info related to offers on a direct listing.
    mapping(uint256 => mapping(address => Offer)) private offers;

    /// @dev listingId => current winning bid in an auction.
    mapping(uint256 => Offer) private winningBid;

    /// @dev address => claim royalty info
    mapping(address => AccountInfo) private accountRoyalty;

    /// @dev tokenId => total royalty amount per token
    mapping(uint256 => uint256) tokenRoyalty;

    /// @dev address => claimed royalty amount per token
    mapping(address => uint256) accountClaimedRoyalty;

    /// @dev address => accumulated unclaimed sales amount
    mapping(address => uint256) accountUnclaimedSales;

    /// @dev tokenId => address

    /**
    * @dev This empty reserved space is put in place to allow future versions to add new
    * variables without shifting down storage in the inheritance chain.
    * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
    */
    uint256[20] private __gap;

    /// @dev Events
    event NewListing(uint256 indexed listingId,
                    address assetContract, 
                    uint256 tokenId,
                    address seller,
                    uint64 quantity,
                    uint256 price
                    );
    
    /**
     * @dev Emitted when a buyer buys from a direct listing, or a lister accepts some
     *      buyer's offer to their direct listing.
     */
    event NewSale(
        address indexed assetContract,
        address indexed seller,
        uint256 indexed listingId,
        address buyer,
        uint64 quantity,
        uint256 totalPrice
    );

    /// @dev Emitted when (1) a new offer is made to a direct listing, or (2) when a new bid is made in an auction.
    event NewOffer(
        uint256 indexed listingId,
        address indexed offeror,
        uint64 quantityWanted,
        uint256 totalOfferAmount
    );

    /// @dev Emitted when the an offer has been cancelled and offer refunded to offerror.
    //       Offer can be cancelled/rejected by offeror and seller
    event OfferCancelled(
        uint256 indexed listingId,
        address indexed sender,
        address indexed offeror,
        uint64 quantity,
        uint256 totalOfferAmount
    );
    
    /// @dev Emitted when the market fee collected on every sale is updated.
    event MarketFeeUpdate(uint64 newFee);

    /// @dev Emitted when the setting up market approval
    event SetApproveMarket(address indexed owner, address indexed to, uint256 price);
    
    /// @dev Emitted when auction buffers are updated.
    event AuctionBuffersUpdated(uint256 timeBuffer, uint256 bidBufferBps);

    /// @dev Emitted when an auction is closed.
    event AuctionClosed(
        uint256 indexed listingId,
        address indexed closer,
        bool indexed cancelled,
        address auctionCreator,
        address winningBidder
    );

    /// @dev Emitted when listing token transferred.
    event ListingTokenTransferred( 
        address indexed from,
        address to,
        address indexed assetContract,
        uint64 quantity,
        uint256 indexed tokenId
    );

    /// @dev Emitted when royalty amount added/claimed
    event UpdateAccountRoyalty( 
        address indexed royaltyReceiver,
        uint256 amount
    );

    /// @dev Emitted when sales claimed
    event SalesClaimed( 
        address indexed seller,
        uint256 amount
    );

    /// @dev Emitted when listing removed
    event ListingRemoved( 
        address indexed sender,
        uint256 listingId
    );

    /// @dev Emitted when token royalty amount reset
    event TokenRoyaltyReset( 
        uint256 indexed tokenId,
        uint256 amountBeforeReset
    );

    /**
    * @dev listingId counter
    */
    using Counters for Counters.Counter;
    Counters.Counter private _listingIds;

    /// @dev Initializer function
    function initialize () initializer public {
        __Ownable_init();
        __ReentrancyGuard_init();
        _listingIds.reset();
        _listingIds.increment(); // listing Id should starts with 1
        marketFeeBps = 2500; // 2.5%
    }

    /// @dev Lets a token owner list tokens for sale
    function createListing(address _assetContract, 
                           address _tokenOwner,
                           uint64 _quantityToList, 
                           uint256 _tokenId, 
                           uint256 _buyoutPricePerToken) external selectedCaller {
        require(!paused, "Marketplace: market activity is paused");
        // price must be equals or more than 0.01 ether
        if (_buyoutPricePerToken < 0.01 ether) {
            revert InvalidPriceLessThanMinimumPrice(_buyoutPricePerToken);
        }
        TokenType tokenTypeOfListing = getTokenType(_assetContract);
        uint64 tokenAmountToList = getSafeQuantity(tokenTypeOfListing, _quantityToList);
        if (tokenAmountToList <= 0) {
            revert InvalidQuantityLessThanMinimumQuantity(tokenAmountToList);
        }

        bool isValid;
        if (tokenTypeOfListing == TokenType.ERC1155) {
            isValid =
                // (IERC1155(_assetContract).balanceOf(_tokenOwner, _tokenId) >= tokenAmountToList) ||
                // (IERC1155Upgradeable(_assetContract).balanceOf(_tokenOwner, _tokenId) >= tokenAmountToList);
                (IERC1155(_assetContract).balanceOf(_tokenOwner, _tokenId) >= tokenAmountToList);
        } else if (tokenTypeOfListing == TokenType.ERC721) {
            isValid =
                // IERC721(_assetContract).ownerOf(_tokenId) == _tokenOwner ||
                // IERC721Upgradeable(_assetContract).ownerOf(_tokenId) == _tokenOwner;
                IERC721(_assetContract).ownerOf(_tokenId) == _tokenOwner;
        }
        require(isValid, "Marketplace: insufficient token balance");

        // bool success;
        // if (tokenTypeOfListing == TokenType.ERC721) {
        //     success = _treehauzNFT.approveMarket(_tokenId, _assetContract);
        // } else if (tokenTypeOfListing == TokenType.ERC1155) {
        //     success = _treehauzNFT.approveMarket(_tokenId, _assetContract);
        // }
        // require(success, "Marketplace: market approval failed");

        // get current listingId
        uint256 listingId = _listingIds.current();

        listings[listingId] = Listing ({
            tokenOwner: _tokenOwner,
            assetContract: _assetContract,
            tokenId: _tokenId,
            quantity: tokenAmountToList,
            buyoutPricePerToken: _buyoutPricePerToken, // sale price
            tokenType: tokenTypeOfListing
        });

        listingTokenId[_tokenId][_assetContract] = listingId;

        // Tokens listed for sale are escrowed in Marketplace.
        transferListingTokens(_tokenOwner, address(this), tokenAmountToList, 
                                listingId, listings[listingId]);
        _listingIds.increment();
        console.log("listingId=", listingId);
        emit NewListing(listingId, _assetContract, _tokenId, _tokenOwner, tokenAmountToList, _buyoutPricePerToken);

    }

    /// @dev Lets a listing's creator edit the listing's parameters.
    function updateListing (
        uint256 _listingId,
        uint64 _quantityToList,
        uint256 _buyoutPricePerToken
    ) external onlyListingCreator(_listingId) nonReentrant {
        require(!paused, "Marketplace: market activity is paused");
        // price must be equals or more than 0.01 ether
        if (_buyoutPricePerToken < 0.01 ether) {
            revert InvalidPriceLessThanMinimumPrice(_buyoutPricePerToken);
        }
        // require(_buyoutPricePerToken >= 0.01 ether, "Marketplace: listing price must equals or more than 0.01");
        Listing memory targetListing = listings[_listingId];
        uint64 safeNewQuantity = getSafeQuantity(targetListing.tokenType, _quantityToList);

        // If the new quantity is 0, remove listing.
        if (safeNewQuantity == 0) {
            removeListing(_listingId, targetListing);
            return;
        }

        if (targetListing.buyoutPricePerToken != _buyoutPricePerToken) {
            listings[_listingId].buyoutPricePerToken = _buyoutPricePerToken;
        }

        // Must validate ownership and approval of the new quantity of tokens for listing.
        // Quantity more than 1 is ERC-1155
        if (targetListing.quantity != safeNewQuantity && targetListing.tokenType == TokenType.ERC1155) {
            // Transfer all escrowed tokens back to the lister, to be reflected in the lister's
            // balance for the upcoming ownership and approval check.
            transferListingTokens(
                address(this),
                targetListing.tokenOwner,
                targetListing.quantity,
                _listingId,
                targetListing
            );

            // validate sufficient new quantity and approval
            validateOwnershipAndApproval(
                targetListing.tokenOwner,
                targetListing.assetContract,
                targetListing.tokenId,
                safeNewQuantity,
                targetListing.tokenType
            );

            listings[_listingId].quantity = safeNewQuantity;
            // Escrow the new quantity of tokens to list in the auction.
            transferListingTokens(targetListing.tokenOwner, address(this), 
                                  safeNewQuantity, _listingId, targetListing);
        }

        emit NewListing(_listingId, targetListing.assetContract, targetListing.tokenId,
                        targetListing.tokenOwner, safeNewQuantity, _buyoutPricePerToken);

    }

    /// @dev Lets an account purchase a given quantity of tokens from a listing.
    function purchase(
        uint256 _listingId,
        uint64 _quantityToBuy
    ) external payable nonReentrant {
        require(!paused, "Marketplace: market activity is paused");
        Listing memory targetListing = listings[_listingId];
        //check for seller pausing activity
        bool primary = getPrimaryOrSecondary(targetListing);
        require(primary && !sellerPaused[targetListing.tokenOwner], "Marketplace: seller paused activity");
        // Check whether listing is exist
        if (listingTokenId[targetListing.tokenId][targetListing.assetContract] == 0) {
            revert NonExistingListing(_listingId);
        }
        // require(listingTokenId[targetListing.tokenId][targetListing.assetContract] != 0, 
        //         "Marketplace: invalid listing");
        require(targetListing.tokenOwner != _msgSender(), "Marketplace: caller is token owner");
        // Check whether listing quantity is enough
        uint64 _quantity = getSafeQuantity(targetListing.tokenType, _quantityToBuy);
        if (targetListing.quantity < _quantity && _quantity < 0) {
            revert InsufficientListingQuantity(_quantity, targetListing.quantity);
        }
        // require(targetListing.quantity >= _quantity && _quantity > 0, "Marketplace: invalid quantity");
        // Check whether price more than 0.01 ether(10000000000000000) and the settled total price are tally.
        if (msg.value < 0.01 ether && 
            msg.value < (targetListing.buyoutPricePerToken * _quantity)) {
            revert InvalidPurchasePrice(msg.value, (targetListing.buyoutPricePerToken * _quantity));
        }
        // require(msg.value >= 0.01 ether && msg.value >= (targetListing.buyoutPricePerToken * _quantity),
        //     "Marketplace: invalid purchase price"
        // );

        // validateOwnershipAndApproval(
        //     targetListing.tokenOwner,
        //     targetListing.assetContract,
        //     targetListing.tokenId,
        //     _quantity,
        //     targetListing.tokenType
        // );

        executeSale(
            _listingId,
            _msgSender(),
            _quantity,
            msg.value, // targetListing.buyoutPricePerToken * _quantity,
            targetListing
        );

    }

    /// @dev Transfers tokens listed for sale in a direct or auction listing.
    function transferListingTokens(
        address _from,
        address _to,
        uint64 _quantity,
        uint256 _listingId,
        Listing memory _listing
    ) internal {
        // if (_listing.tokenType == TokenType.ERC1155 && getContractInterface(_listing.assetContract, TokenType.ERC1155)) {
        //     IERC1155Upgradeable(_listing.assetContract).safeTransferFrom(_from, _to, _listing.tokenId, _quantity, "");
        // } else if (_listing.tokenType == TokenType.ERC721 && getContractInterface(_listing.assetContract, TokenType.ERC721)) {
        //     IERC721Upgradeable(_listing.assetContract).safeTransferFrom(_from, _to, _listing.tokenId, "");
        // } else if (_listing.tokenType == TokenType.ERC1155 && !getContractInterface(_listing.assetContract, TokenType.ERC1155)) {
        //     IERC1155(_listing.assetContract).safeTransferFrom(_from, _to, _listing.tokenId, _quantity, "");
        // } else if (_listing.tokenType == TokenType.ERC721 && !getContractInterface(_listing.assetContract, TokenType.ERC721)) {
        //     IERC721(_listing.assetContract).safeTransferFrom(_from, _to, _listing.tokenId, "");
        // }
        if (_listing.tokenType == TokenType.ERC1155) {
            IERC1155(_listing.assetContract).safeTransferFrom(_from, _to, _listing.tokenId, _quantity, "");
        } else if (_listing.tokenType == TokenType.ERC721) {
            IERC721(_listing.assetContract).safeTransferFrom(_from, _to, _listing.tokenId, "");
        }

        emit ListingTokenTransferred(_from, 
                                     _to, 
                                     _listing.assetContract, 
                                     _quantity, 
                                     _listing.tokenId);
    }

    /// @dev Lets a listing's creator accept an offer for their direct listing.
    function acceptOffer(uint256 _listingId, address _offeror)
        external payable
        onlyListingCreator(_listingId)
    {
        require(!paused, "Marketplace: market activity is paused");
        Offer memory targetOffer = offers[_listingId][_offeror];
        Listing memory targetListing = listings[_listingId];
        // Check whether listing is exist
        if (listingTokenId[targetListing.tokenId][targetListing.assetContract] == 0) {
            revert NonExistingListing(_listingId);
        }
        // checked for cancelled/deleted offer
        if (targetOffer.offeror == address(0)) {
            revert NonExistingOrCancelledOrRejectedOffer(_listingId, _offeror);
        }
        
        if (msg.value != (targetOffer.pricePerToken * targetOffer.quantityWanted)) {
            revert InvalidAcceptOfferPrice(msg.value, (targetOffer.pricePerToken * targetOffer.quantityWanted));
        }
        // delete state variable offers to prevent reentrancy before payout
        if (offers[_listingId][_offeror].quantityWanted != 0) {
            delete offers[_listingId][_offeror];
        }
        
        // delete winningBid[_listingId];
        // offers[_listingId][offeror].offeror = address(0);
        // winningBid[_listingId].offeror = address(0);

        executeSale(
            _listingId,
            targetOffer.offeror,
            targetOffer.quantityWanted,
            targetOffer.pricePerToken * targetOffer.quantityWanted,
            targetListing
        );

    }

    /// @dev Cancel/reject offer, refund to offeror
    //       Does not require to check for existing listing
    //       Offeror(s) need to cancel offer after owner has accepted other offer
    //       or item(s) has been removed from marketplace listing
    function cancelOffer(uint256 _listingId, address _offeror)
        external payable
        nonReentrant
    {
        Offer memory targetOffer = offers[_listingId][_offeror];
        // checked for existance of offer
        if (targetOffer.offeror == address(0)) {
            revert NonExistingOrCancelledOrRejectedOffer(_listingId, _offeror);
        }
        // require(targetOffer.offeror != address(0), "Marketplace: address not exists");
        // allow token owner to reject the offer
        require(_msgSender() == listings[_listingId].tokenOwner
                || _msgSender() == targetOffer.offeror, "Marketplace: address not offeror or owner");

        // update offer before fund transfer - avoid re-entrant
        address payable __offeror = payable(targetOffer.offeror);
        if (offers[_listingId][targetOffer.offeror].quantityWanted != 0) {
            delete offers[_listingId][targetOffer.offeror];
        }

        // refund offeror
        TreehauzEscrow _escrowContract = TreehauzEscrow(_escrow);
        _escrowContract.escrowTransfer(__offeror, targetOffer.pricePerToken * targetOffer.quantityWanted);

        emit OfferCancelled(
            _listingId,
            _msgSender(),
            __offeror,
            targetOffer.quantityWanted,
            targetOffer.pricePerToken * targetOffer.quantityWanted
        );
    }

    /// @dev Lets an account make an offer to a direct listing
    function offer(
        uint256 _listingId,
        uint64 _quantityWanted,
        uint256 _pricePerToken
    ) external payable nonReentrant {
        require(!paused, "Marketplace: market activity is paused");
        Listing memory targetListing = listings[_listingId];
        //check for seller pausing activity
        bool primary = getPrimaryOrSecondary(targetListing);
        require(!sellerPaused[targetListing.tokenOwner] && primary, "Marketplace: seller paused activity");
        // Check whether listing is exist
        require(listingTokenId[targetListing.tokenId][targetListing.assetContract] != 0, "Marketplace: invalid listing");
        uint64 _quantity = getSafeQuantity(targetListing.tokenType, _quantityWanted);
        // Check whether listing quantity is enough
        if (targetListing.quantity < _quantity || _quantity <= 0) {
            revert InsufficientListingQuantity(_quantity, targetListing.quantity);
        }
        // require(targetListing.quantity >= _quantity, "Marketplace: invalid quantity");
        // Check whether caller is owner which cannot do own offering
        // require(_msgSender() != address(0) && 
        //         _msgSender() != targetListing.tokenOwner, "Marketplace: caller is token owner or invalid address");
        // Check whether price more than 0.01 ether
        if (msg.value < 0.01 ether && msg.value < (_quantity * _pricePerToken)) {
            revert InvalidPurchasePrice(msg.value, (_quantity * _pricePerToken));
        }
        // require(msg.value >= (_quantity * _pricePerToken), "Marketplace: invalid offer price");

        // validateOwnershipAndApproval(
        //     targetListing.tokenOwner,
        //     targetListing.assetContract,
        //     targetListing.tokenId,
        //     _quantity,
        //     targetListing.tokenType
        // );

        // new offer
        Offer memory newOffer = Offer({
            offeror: _msgSender(),
            quantityWanted: _quantity,
            pricePerToken: _pricePerToken
        });

        handleOffer(_listingId, newOffer);

    }

    /// @dev Performs a direct listing sale.
    function executeSale(
        uint256 _listingId,
        address _buyer,
        uint64 _quantity,
        uint256 _totalPrice,
        Listing memory _targetListing
    ) internal {
        // validateDirectListingSale(_targetListing, _quantity, _totalPrice);

        unchecked {
            listings[_listingId].quantity -= _quantity;
        }

        transferListingTokens(address(this), _buyer, _quantity, _listingId, _targetListing);
        
        // remove state variable listing before payout to prevent reentrancy
        if (listings[_listingId].quantity == 0) {
            delete listings[_listingId];
            delete listingTokenId[listings[_listingId].tokenId][listings[_listingId].assetContract];
        }
        
        payout(_targetListing.tokenOwner,
               _totalPrice, 
               _targetListing
               );

        emit NewSale(
            _targetListing.assetContract,
            _targetListing.tokenOwner,
            _listingId,
            _buyer,
            _quantity,
            _totalPrice
        );
    }

    /// @dev Process new offer.
    function handleOffer(uint256 _listingId, Offer memory _newOffer) internal {
        
        offers[_listingId][_newOffer.offeror] = _newOffer;

        // Escrow contract to hold payable amount
        (bool escrow, ) = _escrow.call{ value: msg.value }("");
        require(escrow, "Marketplace: fail transfer payment to escrow.");

        emit NewOffer(
            _listingId,
            _newOffer.offeror,
            _newOffer.quantityWanted,
            _newOffer.pricePerToken * _newOffer.quantityWanted
        );
    }    

    /** @notice Pull over push pattern, implement claim method instead of transferring all at once
    *           All sales and royalties has to be claimed, except royalty from external contract address
    *           which will be transferred directly after a successful sales.
    *           Primary market sales for more than one royalty receiver will be treated as royalty payment
    *
    * @dev Distribute royalty to marketplace owner, royalty receiver(s), and token seller
    * 
    */
    function payout(
        address _payee,
        uint256 _totalPayoutAmount,
        Listing memory _listing
    ) internal {

        address payable _marketplaceOwner = payable(owner());
        console.log("_marketplaceOwner=", _marketplaceOwner);

        // Collect market fee
        uint256 marketCut = (_totalPayoutAmount * marketFeeBps) / MAX_BPS;
        console.log("marketCut=", marketCut);
        console.log("msg.value=", msg.value);
        (bool paidMarketplace, ) = _marketplaceOwner.call{ value: marketCut }("");
        require(paidMarketplace, "Marketplace: failed payment transfer to marketplace owner");

        uint256 remainder = _totalPayoutAmount - marketCut;

        // Distribute royalties. ERC-721 and ERC-1155
        try IERC2981Upgradeable(_listing.assetContract).royaltyInfo(_listing.tokenId, _totalPayoutAmount) returns (
            address royaltyFeeRecipient,
            uint256 royaltyFeeAmount
        ) {
            if (royaltyFeeRecipient != address(0) && royaltyFeeAmount > 0) {
                require(
                    royaltyFeeAmount + marketCut <= _totalPayoutAmount,
                    "Marketplace: Total market fees exceed the price."
                );
                
                if (_listing.assetContract == address(_treehauzNFT) || 
                    _listing.assetContract == address(_treehauzGrpNFT)) {
                    remainder = royaltyPayment(remainder, royaltyFeeAmount, _listing);
                // transfer payment to royalty receiver for external contract address
                // do not apply pull over push pattern for external contract royalty
                } else {
                    unchecked {
                        remainder -= royaltyFeeAmount;
                    }
                    (bool paidRoyalty, ) = royaltyFeeRecipient.call{ value: royaltyFeeAmount }("");
                    require(paidRoyalty, "Marketplace: failed payment transfer to royalty receiver"); 
                }
            }
        } catch {}

        if (remainder > 0) {
            unchecked {
                // assign remainder to address unclaimed sales amount
                accountUnclaimedSales[_payee] += remainder;
            }
            // Escrow contract to hold payable sales amount
            (bool escrow, ) = _escrow.call{ value: remainder }("");
            require(escrow, "Marketplace: fail transfer payment to escrow.");
        }
        

        // address payable __payee = payable(_payee);
        // // Distribute price to token owner
        // // Direct transfer if not offer
        // if (remainder > 0 && !_isOffer) {
        //     (bool paidOwner, ) = __payee.call{ value: remainder }("");
        //     require(paidOwner, "Marketplace: failed payment transfer to token owner");
        // // Transfer escrowed fund if offer
        // } else if (remainder > 0 && _isOffer) {
        //     TreehauzEscrow _escrowContract = TreehauzEscrow(_escrow);
        //     _escrowContract.escrowTransfer(__payee, remainder);
        // }
    }

    /** @notice Pull over push pattern, implement claim method instead of transferring all at once
    *
    * @dev Distribute royalty to royalty receiver according to percentage respectively
    * 
    */
    function royaltyPayment(
        uint256 _remainder,
        uint256 _royaltyFeeAmount,
        Listing memory _listing
    ) internal returns (uint256){
        address[] memory receiver;
        uint256[] memory percentage;
        uint32 totalPercentage;
        bool primary;
        // bool _primarySolo;
        // uint256 allocation = MAX_BPS;

        // for ERC-721
        if (_listing.assetContract == address(_treehauzNFT)) {
            (receiver, percentage) = _treehauzNFT.getRoyaltyInfo(_listing.tokenId);
            totalPercentage = _treehauzNFT.getTotalRoyaltyPercentage(_listing.tokenId);
            require(receiver[0] != address(0) && totalPercentage >= 0, "Marketplace: failed to get royalty info");
            primary = _listing.tokenOwner == 
                        _treehauzNFT.getTokenMinter(_listing.tokenId) ? true : false;
        // for ERC-1155
        } else if (_listing.assetContract == address(_treehauzGrpNFT)) { 
            (receiver, percentage) = _treehauzGrpNFT.getRoyaltyInfo(_listing.tokenId);
            totalPercentage = _treehauzGrpNFT.getTotalRoyaltyPercentage(_listing.tokenId);
            require(receiver[0] != address(0) && totalPercentage >= 0, "Marketplace: failed to get royalty info");
            primary = _listing.tokenOwner == 
                        _treehauzGrpNFT.getTokenMinter(_listing.tokenId) ? true : false;
        } else {
            revert ("Marketplace: unable to get royalty info");
        }

        unchecked {
            if (primary && receiver.length == 1) {
                return _remainder;
            } else if (!primary) {
                tokenRoyalty[_listing.tokenId] += _royaltyFeeAmount;
                _remainder -= _royaltyFeeAmount;
            // primary market with more than one royalty receiver
            // is treated as royalty claim
            } else if (primary && receiver.length > 1) {
                tokenRoyalty[_listing.tokenId] += _remainder;
                _remainder = 0;
            } 
        }
        
        return _remainder;

        // // check split remaining for primary/secondary market
        // if (_secondary) {
        //     _remainder -= _royaltyFeeAmount;
        // // if primary solo, return all remainder
        // } else if (!_secondary && receiver.length == 1) {
        //     _primarySolo = true;
        // // if primary collab, zerorise remainder
        // } else if (!_secondary && receiver.length > 1) {
        //     // override EIP-2981 royaltyFeeAmount
        //     _royaltyFeeAmount = _remainder;
        //     _remainder = 0;
        //     allocation = totalPercentage;
        // }
        // // if primary/secondary with royalty receiver more than one
        // if (!_primarySolo) {
        //     // transfer payment to each recepient respectively
        //     for (uint i=0; i < receiver.length; i++) {
        //         setRoyaltyAccount(receiver[i], (percentage[i] * _royaltyFeeAmount) / allocation);
        //     }
        // }
        // // accumulate royalty amount by tokenId
        // tokenRoyalty[_listing.tokenId] += _royaltyFeeAmount;
        // return _remainder;
    }

    /** @notice Pull over push pattern, implement claim method instead of transferring all at once
    *
    * @dev Set or add up accumulated royalty payment
    * 
    */
    function setRoyaltyAccount(
        address _receipient,
        uint256 _amount
    ) internal {
        require(_amount >= 0, "Marketplace: royalty amount must be equals or more than 0");
        if (accountRoyalty[_receipient].owner != address(0)) {
            // Register new account royalty
            accountRoyalty[_receipient] = AccountInfo ({
                                    owner : _receipient,
                                    unclaimedRoyalty : _amount,
                                    claimedRoyalty : 0
                                    });
            
        } else if (accountRoyalty[_receipient].owner == _receipient) {
            accountRoyalty[_receipient].unclaimedRoyalty += _amount;
        }

        emit UpdateAccountRoyalty(_receipient, _amount);
    }

    /// @dev Remove listing from marketplace.
    function removeListing(uint256 _listingId, Listing memory _targetListing) 
    public onlyListingCreator(_listingId) {

        if (listings[_listingId].tokenId != 0) {
            delete listings[_listingId];
            delete listingTokenId[_targetListing.tokenId][_targetListing.assetContract];
        }
        
        transferListingTokens(address(this), _targetListing.tokenOwner, 
                             _targetListing.quantity, _listingId, _targetListing);

        emit ListingRemoved(_msgSender(), _listingId);
    }

    // /// @dev Burn token will delete listing, but the offer will stay to allow offeror refund
    // function burnToken(uint256 _tokenId, uint64 _quantity) external selectedCaller {
    //     uint256 listingId = listingTokenId[_tokenId][_msgSender()];

    //     if (listings[listingId].tokenId != 0) {
    //         delete listings[listingId];
    //         delete listingTokenId[_tokenId][_msgSender()];
    //     }
    // }

    /// @dev Transfer tokens utility.
    function transferTokenUtil(
        address _sender,
        address _recepient,
        address _assetContract,
        uint256 _tokenId,
        uint256 _quantity
    ) public {
        require(_msgSender() != address(0), "Treehauz: Address not valid");
        TokenType utilTokenType = getTokenType(_assetContract);
        address __sender;
        if (_msgSender() == address(_treehauzNFT) || _msgSender() == address(_treehauzGrpNFT)) {
            __sender = _sender;
        } else {
            __sender = _msgSender();
        }
        
        // IERC721(_assetContract).setApprovalForAll(address(this), true);
        // IERC721(_assetContract).approve(address(this), _tokenId);

        if (utilTokenType == TokenType.ERC721) {
            IERC721Upgradeable(_assetContract).safeTransferFrom(__sender, _recepient, _tokenId, "");
        } else if (utilTokenType == TokenType.ERC1155) {
            IERC1155(_assetContract).safeTransferFrom(__sender, _recepient, _tokenId, _quantity, "");
        }

        // if (utilTokenType == TokenType.ERC1155 && getContractInterface(_assetContract, TokenType.ERC1155)) {
        //     IERC1155Upgradeable(_assetContract).safeTransferFrom(_from, _to, _tokenId, _quantity, "");
        // } else if (utilTokenType == TokenType.ERC721 && getContractInterface(_assetContract, TokenType.ERC721)) {
        //     IERC721Upgradeable(_assetContract).safeTransferFrom(_from, _to, _tokenId, "");
        // } else if (utilTokenType == TokenType.ERC1155 && !getContractInterface(_assetContract, TokenType.ERC1155)) {
        //     IERC1155(_assetContract).safeTransferFrom(_from, _to, _tokenId, _quantity, "");
        // } else if (utilTokenType == TokenType.ERC721 && !getContractInterface(_assetContract, TokenType.ERC721)) {
        //     IERC721(_assetContract).safeTransferFrom(_from, _to, _tokenId, "");
        // }

        // uint256 _listingId = listingTokenId[_tokenId].listingId;
        // if (_to != address(this) && _listingId != 0) {
        //     delete listings[_listingId];
        //     delete listingTokenId[_tokenId];
        // }

        // emit TokenTransferredByUtil(_from, _to, _assetContract, _tokenId, _quantity);
    }

    /// @dev Claim all accumulated royalty for royalty receiver
    function claimRoyalty() external nonReentrant {
        uint256 unclaimedRoyalty;
        address payable recepient = payable(_msgSender());

        unclaimedRoyalty = getUnclaimedRoyalty(recepient);
        require(unclaimedRoyalty > 0, "Marketplace: account does not have any unclaimed royalty");
        // update address' tokenId claimed royalty amount
        accountClaimedRoyalty[_msgSender()] += unclaimedRoyalty;

        TreehauzEscrow _escrowContract = TreehauzEscrow(_escrow);
        _escrowContract.escrowTransfer(recepient, unclaimedRoyalty);

        emit UpdateAccountRoyalty(_msgSender(), unclaimedRoyalty);
    }

    /// @dev Claim all accumulated sales include primary and secondary market
    function claimSales() external nonReentrant {
        address payable recepient = payable(_msgSender());

        uint256 unclaimedSales = accountUnclaimedSales[_msgSender()];
        require(unclaimedSales > 0, "Marketplace: account does not have any unclaimed sales");
        // Update state variable to prevent reentrancy
        accountUnclaimedSales[_msgSender()] = 0;

        TreehauzEscrow _escrowContract = TreehauzEscrow(_escrow);
        _escrowContract.escrowTransfer(recepient, unclaimedSales);

        emit SalesClaimed(_msgSender(), unclaimedSales);
    }

    /// @dev Validates that `_tokenOwner` owns and has approved Market to transfer tokens.
    function validateOwnershipAndApproval(
        address _tokenOwner,
        address _assetContract,
        uint256 _tokenId,
        uint256 _quantity,
        TokenType _tokenType
    ) internal view {
        address market = address(this);
        bool isValid;

        if (_tokenType == TokenType.ERC1155) {
             isValid =
                ERC1155Upgradeable(_assetContract).balanceOf(_tokenOwner, _tokenId) >= _quantity &&
                ERC1155Upgradeable(_assetContract).isApprovedForAll(_tokenOwner, market);
        } else if (_tokenType == TokenType.ERC721) {
            isValid =
                ERC721Upgradeable(_assetContract).ownerOf(_tokenId) == _tokenOwner &&
                (ERC721Upgradeable(_assetContract).getApproved(_tokenId) == market ||
                    ERC721Upgradeable(_assetContract).isApprovedForAll(_tokenOwner, market));
        }
        require(isValid, "Marketplace: insufficient token balance or approval.");
    }

    /// @dev Validates conditions of a direct listing sale.
    function validateDirectListingSale(
        Listing memory _listing,
        uint256 _quantityToBuy,
        uint256 settledTotalPrice
    ) internal {
        // Check whether a valid quantity of listed tokens is being bought.
        require(
            _listing.quantity > 0 && _quantityToBuy > 0 && _quantityToBuy <= _listing.quantity,
            "Marketplace: buying invalid amount of tokens."
        );
        require(msg.value >= settledTotalPrice, "Marketplace: insufficient payment amount");
    }

    /// @dev Enforces quantity == 1 if tokenType is TokenType.ERC721.
    function getSafeQuantity(TokenType _tokenType, uint64 _quantityToCheck)
        internal
        pure
        returns (uint64 safeQuantity)
    {
        if (_quantityToCheck == 0) {
            safeQuantity = 0;
        } else {
            safeQuantity = _tokenType == TokenType.ERC721 ? 1 : _quantityToCheck;
        }
    }

    /// @dev Check whether token listing is for primary or secondary market
    function getPrimaryOrSecondary(Listing memory _listing)
    internal view returns (bool _primary) {
        
        // for ERC-721
        if (_listing.assetContract == address(_treehauzNFT)) {
            _primary = _listing.tokenOwner == 
                        _treehauzNFT.getTokenMinter(_listing.tokenId) ? true : false;
        // for ERC-1155
        } else if (_listing.assetContract == address(_treehauzGrpNFT)) { 
            _primary = _listing.tokenOwner == 
                        _treehauzGrpNFT.getTokenMinter(_listing.tokenId) ? true : false;
        } else {
            // always return secondary for external contract address
            return false;
        }
    }

    /// @dev Calculate unclaimed royalty for royalty receiver
    function getUnclaimedRoyalty(address _address) public view returns (uint256) {
        uint256[] memory tokenId;
        uint32[] memory percentage;
        uint256 result;
        uint256 total;
        uint256 unclaimed;

        (tokenId, percentage) = _treehauzNFT.getAddressRoyalty(_address);

        unchecked {
            for (uint64 i=0; i < tokenId.length;) {
                if (tokenId[i] != 0 && percentage[i] > 0) {
                    result = (percentage[i] * tokenRoyalty[tokenId[i]]) / MAX_BPS;
                    total += result;
                    ++i;
                }
            }
            if (accountClaimedRoyalty[_address] < total) {
                unclaimed = total - accountClaimedRoyalty[_address];
            }
        }
        
        return unclaimed; 
    }

    /// @dev Returns the listing of the token id.
    function getListingByTokenId(uint256 _tokenId, address _assetContract) 
    public view returns (uint256 listingId) {
        listingId = listingTokenId[_tokenId][_assetContract];
        return listingId;
    }

    /// @dev Returns the listing of the token id.
    function getListing(uint256 _listingId) public view returns (Listing memory listingInfo) {
        listingInfo = listings[_listingId];
        return listingInfo;
    }

    /// @dev Returns the interface supported from normal/upgradeable contract.
    // call this everytime as one contract may support both ERC-721 and ERC-1155
    function getContractInterface(address _assetContract, TokenType _tokenType) 
    internal view returns (bool support) {

        if (IERC165(_assetContract).supportsInterface(type(IERC721).interfaceId) || 
            IERC165(_assetContract).supportsInterface(type(IERC1155).interfaceId)) {
                return true;
        }

        // if (_tokenType == TokenType.ERC1155) {
        //     if (IERC165Upgradeable(_assetContract).supportsInterface(type(IERC1155Upgradeable).interfaceId)) {
        //         return true;
        //     } else if (IERC165(_assetContract).supportsInterface(type(IERC1155).interfaceId)) {
        //         return false;
        //     } else {
        //         revert("Marketplace: must implement standard interface for ERC 1155.");
        //     }
        // } else if (_tokenType == TokenType.ERC721) {
        //     if (IERC165Upgradeable(_assetContract).supportsInterface(type(IERC721Upgradeable).interfaceId)) {
        //         return true;
        //     } else if (IERC165(_assetContract).supportsInterface(type(IERC721).interfaceId)) {
        //         return false;
        //     } else {
        //         revert("Marketplace: must implement standard interface for ERC 721.");
        //     }
        // } else {
        //     revert("Marketplace: must implement standard interface for ERC 1155 or ERC 721.");
        // }
    }

    /// @dev Returns the interface supported by a contract.
    function getTokenType(address _assetContract) internal view returns (TokenType tokenType) {

        if (IERC165(_assetContract).supportsInterface(type(IERC721).interfaceId)) {
             tokenType = TokenType.ERC721;
        } else if (IERC165(_assetContract).supportsInterface(type(IERC1155).interfaceId)) {
            tokenType = TokenType.ERC1155;
        } else {
            revert("Marketplace: must implement ERC 1155 or ERC 721.");
        }
    }

    /// @dev Returns the listing of the token id.
    function getTokenRoyalty(uint256 _tokenId) public view returns (uint256) {
        return tokenRoyalty[_tokenId];
    }
    

    ///@dev Assign Treehauz Single NFT contract for ERC-721
    function setTreeNFTContract(address _contractAddress) external onlyOwner {
        _treehauzNFT = TreehauzSingleNFT(_contractAddress);
    }

    ///@dev Assign Treehauz Group NFT contract for ERC-1155
    function setTreeGrpNFTContract(address _contractAddress) external onlyOwner {
        _treehauzGrpNFT = TreehauzGroupNFT(_contractAddress);
    }

    ///@dev Assign Treehauz escrow contract.
    function setTreeEscrow(address _escrowAddress) external onlyOwner {
        _escrow = payable(_escrowAddress);
    }

    /// @dev Set marketplace fees.
    // max fee (MAX_BPS) is 100000 which is 100%
    function setMarketplaceFee(uint64 _fee) external onlyOwner {
        require(_fee < MAX_BPS, "Marketplace: invalid marketplace fee percentage.");

        marketFeeBps = _fee;
        emit MarketFeeUpdate(_fee);
    }

    /// @dev Set auction buffers
    function setAuctionBuffers(uint64 _timeBuffer, uint64 _bidBufferBps) external onlyOwner {
        require(_bidBufferBps < MAX_BPS, "Marketplace: invalid BPS.");

        timeBuffer = _timeBuffer;
        bidBufferBps = _bidBufferBps;

        emit AuctionBuffersUpdated(_timeBuffer, _bidBufferBps);
    }


    /// @notice All existing royalty must be claimed first before renewing royalty info
    //          Check for unclaimed royalty
    /// @dev Reset token royalty amount after renew royalty info     
    function resetTokenRoyalty(uint256 _tokenId) external selectedCaller {
        uint256 royaltyBeforeReset = tokenRoyalty[_tokenId];
        address[] memory receiver;
        uint256[] memory percentage;
        uint256 totalPercentage;

        if (_msgSender() == address(_treehauzNFT)) {
            (receiver, percentage) = _treehauzNFT.getRoyaltyInfo(_tokenId);
            require(receiver[0] != address(0) && totalPercentage >= 0, 
                    "Marketplace: failed to get royalty info");
        // for ERC-1155
        } else if (_msgSender() == address(_treehauzGrpNFT)) { 
            (receiver, percentage) = _treehauzGrpNFT.getRoyaltyInfo(_tokenId);
            require(receiver[0] != address(0) && totalPercentage >= 0, 
                    "Marketplace: failed to get royalty info");
        } else {
            revert ("Marketplace: unable to get royalty info");
        }

        unchecked {
            uint256 receiverLength = receiver.length;
            uint256 unclaimed;
            address[] memory unclaimedReceiver;
            uint256[] memory unclaimedAmount;
            uint32 u;
            for (uint256 i=0; i < receiverLength;) {
                unclaimed = getUnclaimedRoyalty(receiver[i]);
                if (unclaimed > 0) {
                    unclaimedReceiver[u] = receiver[i];
                    unclaimedAmount[u] = unclaimed;
                    ++u;
                }
                unclaimed = 0;
                ++i;
            }
            if (unclaimedReceiver.length > 0) {
                revert InvalidResetRoyalyWithUnclaimedRoyalty(unclaimedReceiver, unclaimedAmount);
            }
            tokenRoyalty[_tokenId] = 0;
        }

        emit TokenRoyaltyReset(_tokenId, royaltyBeforeReset);
    }

    /**
    * @dev Approve `operator` to operate on all of `owner` tokens
    *
    * Emits a {SetApproveMarket} event.
    */
    // function approveMarket(uint256 _tokenId, address _assetContract) internal 
    function approveMarket(ListingParameters memory _params) external 
    returns (bool) {
        // require(ERC721Upgradeable(_assetContract)._exists(_tokenId), "Treehauz: nonexistent token");
        address ownerTest = IERC721Upgradeable(_params.assetContract).ownerOf(_params.tokenId);
        address msgSenderTest = _msgSender();
        console.log("_msgSender()=", msgSenderTest);
        console.log("ownerTest=", ownerTest);
        console.log("_assetContract=", _params.assetContract);
        console.log("address(_marketplaceContract)=", address(this));
        require(_msgSender() == ownerTest, "Treehauz: caller to approve market not valid");
        IERC721Upgradeable(_params.assetContract).setApprovalForAll(address(this), true);
        IERC721Upgradeable(_params.assetContract).approve(address(this), _params.tokenId);

        emit SetApproveMarket(_msgSender(), address(this), _params.tokenId);
        return true;
    }

    /**
    * @dev Set pausing activity for marketplace.
    */
    function pause(bool _state) external onlyOwner {
        paused = _state;
    }

    /**
    * @dev Set pausing activity for seller primary market.
    */
    function sellerPause(bool _state) external {
        sellerPaused[_msgSender()] = _state;
    }

    /**
    * @dev Function to receive Ether
    */
    receive() external payable {}

    /**
    * @dev Fallback function is called when msg.data is not empty
    */
    fallback() external payable {}

    /**
    *   ERC 1155 and ERC 721 Receiver functions.
    **/

    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes memory
    ) public virtual returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) public virtual returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

}