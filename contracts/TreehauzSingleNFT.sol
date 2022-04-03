// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Counters.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721URIStorageUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./MainMarketplace.sol";

import "hardhat/console.sol";

contract TreehauzSingleNFT is 
    Initializable, 
    OwnableUpgradeable,
    IERC2981Upgradeable,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable,
    ERC721URIStorageUpgradeable,
    ERC721BurnableUpgradeable
    {

    struct SingleItem {
        address tokenMinter; // primary owner
        uint32[] royaltyPercentage; // list of percentage
        address[] royaltyReceiver; // list of receiver
        string tokenIPFSURI; // IPFS CID
    }

    struct AccountRoyaltyInfo {
        uint256[] tokenId; // list of token Id attached to an account address
    }

    /**
    * @dev Declare contract admin address
    */
    address private _admin;

    /**
    * @dev Base token uri prefix.
    */
    string private _baseTokenURI;

        /**
    * @dev Declare marketplace contract 
    */
    MainMarketplace private _marketplaceContract;

    /// @dev tokenId => single token info
    mapping(uint256 => SingleItem) private _tokenItems;

    /// @dev address => account royalty info
    mapping(address => AccountRoyaltyInfo) private _accountRoyalty;

    /// @dev address => tokenId => approval info
    // approval for update royalty
    mapping(address => mapping(uint256 => bool)) private _tokenOwnerApproval;

    /**
    * @dev This empty reserved space is put in place to allow future versions to add new
    * variables without shifting down storage in the inheritance chain.
    * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
    */
    uint256[50] private __gap;


    /// @dev Checks whether caller is admin or owner.
    modifier onlyAdminOrOwner() {
        require(_msgSender() == _admin || _msgSender() == owner(), "Treehauz: Caller is not admin or owner.");
        _;
    }

    /// @dev Checks whether caller is token primary owner.
    modifier onlyTokenPrimaryOwner(uint256 _tokenId) {
        require(_msgSender() == _tokenItems[_tokenId].tokenMinter, "Treehauz: Caller is not token minter or primary token owner.");
        _;
    }

    /**
    * @dev events
    */
    event RoyaltyInfoUpdated(uint256 tokenId, address[] sender, uint32[] royaltyPercentage);

    /// @dev Treehauz tokenId counter
    using Counters for Counters.Counter;
    Counters.Counter private _singleTokenIds;


    // initialize contract
    function initialize (
        string memory name,
        string memory symbol,
        string memory baseURI
    ) 
    initializer public payable {
        __ERC721_init(name, symbol);
        __ERC721Enumerable_init();
        __ERC721URIStorage_init();
        __ERC721Burnable_init();
        __Ownable_init();

        _baseTokenURI = baseURI;
        _singleTokenIds.reset();
    }

    /**
    * @dev Approve marketplace contract as `operator` to operate on all of `owner` tokens
    *
    */
    function approveMarket(uint256 _tokenId, uint256 _salePrice) external 
    returns (bool) {
        require(_exists(_tokenId), "Treehauz: nonexistent token");
        setApprovalForAll(address(_marketplaceContract), true);
        // approve(address(_marketplaceContract), _tokenId);        
        _marketplaceContract.createListing(address(this),
                                           _msgSender(),
                                           1, // enforce quantity=1 for ERC-721
                                           _tokenId,
                                           _salePrice // sale price per token
                                           );
                                           
        return true;
    }

    // Safe mint ERC721, assign singleItem info
    function singleMint(
                        uint32 _totalRoyalty,
                        uint32[] memory _royaltyPercentage,
                        address[] memory _royaltyReceiver,
                        string memory _tokenURI
                        )
    external {
        require(_royaltyReceiver[0] != address(0), "Treehauz : invalid royalty receiver address");
        require(_royaltyPercentage[0] >= 0, "Treehauz : Royalty percentage less than 0 is not valid");
        require(_totalRoyalty < 90000, "Treehauz: Total royalty cannot exceed 90%");

        uint256 newItemId = _singleTokenIds.current();
        
        _tokenItems[newItemId] = SingleItem ({
            tokenMinter : _msgSender(), // token minter or primary owner
            royaltyPercentage : _royaltyPercentage, // list of royalty percentage
            royaltyReceiver : _royaltyReceiver, // list of royalty receiver
            tokenIPFSURI : _tokenURI // IPFS content identifier
        });        

        _safeMint(_msgSender(), newItemId);
        // _setTokenURI(newItemId, tokenURI(newItemId));

        _singleTokenIds.increment();
    }

    /**
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 tokenId) public view virtual 
    override (ERC721Upgradeable, ERC721URIStorageUpgradeable) 
    returns (string memory) {
        require(_exists(tokenId), "ERC721URIStorage: URI query for nonexistent token");

        string memory _tokenURI = _tokenItems[tokenId].tokenIPFSURI;
        string memory base = _baseURI();

        // If there is no base URI, return the token URI.
        if (bytes(base).length == 0) {
            return _tokenURI;
        }
        // If both are set, concatenate the baseURI and tokenURI (via abi.encodePacked).
        if (bytes(_tokenURI).length > 0) {
            return string(abi.encodePacked(base, _tokenURI));
        }
        return super.tokenURI(tokenId);
    }

    /**
    * @dev Destroys `tokenId`.
    * The approval is cleared when the token is burned.
    *
    * Requirements:
    *
    * - `tokenId` must exist.
    *
    * Emits a {Transfer} event.
    */
    function burnSingleToken(uint256 _tokenId) public {
        require(_exists(_tokenId), "Treehauz: nonexistent token");
        require(_msgSender() == _tokenItems[_tokenId].tokenMinter, "Treehauz : Must be primary minter");
        require(_msgSender() == ownerOf(_tokenId), "Treehauz : Must be token owner");
        
        // delete listing on marketplace
        // _marketplaceContract.burnToken(_tokenId, 1);
        _burn(_tokenId);
        
        if (bytes(_tokenItems[_tokenId].tokenIPFSURI).length != 0) {
            delete _tokenItems[_tokenId];
        }
    }

    function _burn(uint256 _tokenId) 
    internal virtual override (ERC721Upgradeable, ERC721URIStorageUpgradeable) { 
        super._burn(_tokenId);
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) 
    internal override (ERC721Upgradeable, ERC721EnumerableUpgradeable) {
        super._beforeTokenTransfer(from, to, tokenId);
    }

    /// @dev get token information
    function getTokenInfo(uint256 _tokenId) 
    public view returns (SingleItem memory getSingleItem) {
            getSingleItem = _tokenItems[_tokenId];
            return getSingleItem;
    }

    /// @dev get list of tokens and its royalty percentage for an address
    function getAddressRoyalty(address _address) 
    public view returns (uint256[] memory _tokenId, 
                        uint32[] memory _percentage) {
        unchecked 
        {
            uint256 royaltyLength = _accountRoyalty[_address].tokenId.length;
            
            for (uint256 i=0; i < royaltyLength;) {
                _percentage[i] = _tokenItems[_accountRoyalty[_address].tokenId[i]].royaltyPercentage[i];
                ++i;
            }
        }
        return (_accountRoyalty[_address].tokenId, _percentage);
    }
    
    /// @dev get info primary/secondary market by tokenId
    function getTokenMinter(uint256 _tokenId) 
    public view returns (address) {
        return _tokenItems[_tokenId].tokenMinter;
    }

    /// @dev get total royalty percentage by tokenId
    function getTotalRoyaltyPercentage(uint256 _tokenId) 
    public view returns (uint32) {
        uint32 totalPercentage;
        unchecked {
            uint256 royaltyLength = _tokenItems[_tokenId].royaltyReceiver.length;
            for (uint256 i=0; i < royaltyLength;) {
                totalPercentage += _tokenItems[_tokenId].royaltyPercentage[i];
                ++i;
            }
        }
        return totalPercentage;
    }

    /** @notice Called with the total sale price to determine how much royalty
    *          is owed and to whom.
    * @param tokenId - the NFT asset queried for royalty information
    * @param salePrice - the total sale price of the NFT asset specified by _tokenId
    * @return receiver - address of who should be sent the royalty payment
    * @return royaltyAmount - the royalty payment amount for salePrice
    */
    function royaltyInfo(uint256 tokenId, uint256 salePrice)
    external view returns (
        address receiver,
        uint256 royaltyAmount) {
        require(_exists(tokenId), "Treehauz: nonexistent token");
        require(salePrice > 0, "Treehauz : Sale price must be more than 0");
        // receiver = _tokenRoyalty[_tokenId].royaltyReceiver[0]; // set return only for primary receiver
        receiver = _tokenItems[tokenId].royaltyReceiver[0]; // set return only for primary receiver
        uint32 totalPercentage = getTotalRoyaltyPercentage(tokenId);
        // calculate royaltyAmount based on percentage, 100000 = 100%
        royaltyAmount = (salePrice / 100000) * totalPercentage; // set return for total royalty
    }

    /// @param _tokenId - the NFT asset queried for royalty information
    function getRoyaltyInfo(uint256 _tokenId) 
    external view returns (
        address[] memory, uint256[] memory) {
        require(_exists(_tokenId), "Treehauz: nonexistent token");
        address[] memory __receiver = new address[](_tokenItems[_tokenId].royaltyReceiver.length);
        uint256[] memory __percentage = new uint256[](_tokenItems[_tokenId].royaltyReceiver.length);
        
        unchecked 
        {
            uint256 receiverLength = _tokenItems[_tokenId].royaltyReceiver.length;
            for (uint256 i=0; i < receiverLength;) {
                __receiver[i] = address(_tokenItems[_tokenId].royaltyReceiver[i]);
                __percentage[i] = _tokenItems[_tokenId].royaltyPercentage[i];
                    ++i;
            }
        }
        return (__receiver, __percentage);
    }

    /**
    * @dev Set royalty info.
    * Permission: Only allowed for token minter or primary owner.
    *             Must be assigned by admin by calling setApprovalUpdateRoyalty
    * @param _tokenId NFT asset.
    * @param _address Royalty receiver.
    * @param _royaltyPercentage Royalty percentage of each receiver.
    * @param _totalRoyalty Combined total royalty.
    */
    function setRoyaltyInfo(uint256 _tokenId, 
                            address[] memory _address, 
                            uint32[] memory _royaltyPercentage, 
                            uint32 _totalRoyalty) 
    external onlyTokenPrimaryOwner(_tokenId) {
        require(_exists(_tokenId), "Treehauz: nonexistent token");
        require(_tokenOwnerApproval[_tokenItems[_tokenId].tokenMinter][_tokenId] == true, 
                "Treehauz: require approval from admin for update royalty");
        require(_totalRoyalty < 90000, "Treehauz: Total royalty must less than 90%");
        require(_address[0] != address(0), "Treehauz: invalid primary royalty receiver address");
        require(_royaltyPercentage[0] >= 0, "Treehauz: Royalty percentage less than 0 is not valid");
        console.log("debug1");

        // delete existing addresses that mapped with the token Id
        uint256 currentReceiver = _tokenItems[_tokenId].royaltyReceiver.length;
        for (uint256 i=0; i < currentReceiver;) {
            if (_accountRoyalty[_tokenItems[_tokenId].royaltyReceiver[i]].tokenId[i] == _tokenId) {
                delete _accountRoyalty[_tokenItems[_tokenId].royaltyReceiver[i]].tokenId[i];
            }
            unchecked {++i;}
        }
        if (_tokenItems[_tokenId].royaltyReceiver[0] != address(0)) {
            delete _tokenItems[_tokenId].royaltyReceiver;
            delete _tokenItems[_tokenId].royaltyPercentage;
        }

        _marketplaceContract.resetTokenRoyalty(_tokenId);

        for (uint256 j=0; j < _address.length;) {
            if (_address[j] != address(0)) {
                _tokenItems[_tokenId].royaltyReceiver.push(_address[j]);
                if (_royaltyPercentage[j] > 0) {
                    _tokenItems[_tokenId].royaltyPercentage.push(_royaltyPercentage[j]);
                    _accountRoyalty[_address[j]].tokenId.push(_tokenId);
                }
            }
            unchecked {++j;}
        }

        _tokenOwnerApproval[_tokenItems[_tokenId].tokenMinter][_tokenId] = false;
        emit RoyaltyInfoUpdated(_tokenId, _address, _royaltyPercentage);
    }

    /**
    * @dev Set token approval for primary owner for updating royalty purpose.
    * Permission: Only admin or owner.
    * @param _tokenMinter token minter or primary owner.
    * @param _tokenId token Id.
    */
    function setApprovalUpdateRoyalty(address _tokenMinter, uint256 _tokenId) external onlyAdminOrOwner {
        _tokenOwnerApproval[_tokenMinter][_tokenId] = true;
    }

    /**
    * @dev Set marketplace contract.
    * Permission: Only owner.
    * @param _marketplaceAddress MainMarketplace contract address.
    */
    function setMarketplaceContract(address payable _marketplaceAddress) external onlyOwner {
        _marketplaceContract = MainMarketplace(_marketplaceAddress);
    }

    /**
    * @dev Set admin address.
    * Permission: Only owner.
    * @param _adminAddress admin address.
    */
    function setAdmin(address _adminAddress) external onlyOwner {
        _admin = _adminAddress;
    }

    /**
    * @dev Get base URI.
    */
    function _baseURI() internal view virtual override returns (string memory) {
        return _baseTokenURI;
    }

    /**
    * @dev Set token IPFS base URI.
    * Permission: Only owner.
    * @param _base IPFS base URI.
    */
    function setBaseURI(string memory _base) external onlyOwner {
        _baseTokenURI = _base;
    }

    /**
    * @dev Reset token IPFS base URI.
    * Permission: Only owner.
    */
    function resetBaseURI() external onlyOwner {
        _baseTokenURI = "";
    }

    /**
    * @dev See {IERC165-supportsInterface}.
    */
    function supportsInterface(bytes4 interfaceId) public view virtual 
    override(IERC165Upgradeable, ERC721Upgradeable, ERC721EnumerableUpgradeable) 
    returns (bool) {
        return
        interfaceId == type(IERC2981Upgradeable).interfaceId ||
        super.supportsInterface(interfaceId);
    }

    // transfer single item
    function singleTransfer(address _assetContract,
                            address _recepient,
                            uint256 _tokenId) 
    external {
        require(_msgSender() != address(0), "Treehauz: Address not valid");
        // IERC721(_assetContract).setApprovalForAll(address(_marketplaceContract), true);
        // IERC721(_assetContract).approve(address(_marketplaceContract), _tokenId);
        _marketplaceContract.transferTokenUtil(_msgSender(), _recepient, _assetContract, _tokenId, 1);

        // IERC721(_assetContract).safeTransferFrom(_msgSender(), _recepient, _tokenId, "");
    }

}