// SPDX-License-Identifier: MIT OR Apache 2.0
pragma solidity ^0.8.10;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

import "hardhat/console.sol";

// Escrow contract for marketplace
contract TreehauzEscrow is
  Initializable,
  ContextUpgradeable,
  OwnableUpgradeable,
  ReentrancyGuardUpgradeable
{
    /**
    * @dev Marketplace address
    */
    address private _marketplace;

    function initialize() public initializer {
      __Ownable_init();
      __ReentrancyGuard_init();
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
    * @dev Get total currency balance of escrow currently holding
    */
    function getBalance() public view returns (uint256) {
      return address(this).balance;
    }

    /**
    * @dev Assign marketplace contract address.
    * Permission: Contract owner.
    * @param marketplace contract address.
    */
    function setMarketplaceContract(address marketplace) external onlyOwner {
        _marketplace = marketplace;
    }

    /**
    * @dev Escrow transfer currency to receiver
    * @param _to receiver contract address.
    * @param _amount transfer amount.
    */
    function escrowTransfer(address payable _to, uint256 _amount) external nonReentrant {
        require(address(this).balance > _amount, "Escrow: not enough escrow contract fund");
        require(_marketplace == _msgSender(), "Escrow: invalid caller");

        (bool success, ) = _to.call{ value: _amount }("");
        require(success, "Escrow: transfer currency failed");
    }

}