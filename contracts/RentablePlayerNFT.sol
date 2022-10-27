// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "./interfaces/IERC4907.sol";
import "./interfaces/IOverCollateralizedAuction.sol";

error InvalidCaller();
error PlayerMaxCap(uint256 capAmount);
error CannotAuctionRentedNFT();

contract ERC4907 is ERC721, IERC4907, ERC721URIStorage {
    address admin;
    IOverCollateralizedAuction public auction;
    uint256 public currTokenId;

    struct UserInfo {
        address user; // address of user role
        uint64 expires; // unix timestamp, user expires
    }

    struct PlayerData {
        uint32 countMinted; // current number of this player minted
        uint32 maxMintable; // maximum amount of cards minted for this player
        uint16[] percentStarted; // out of 1000 (e.g. 807 = 80.7%)
        uint16[] percentOwned; // out of 1000 (e.g. 807 = 80.7%)
        /**
         * price of the auctions first 216 bits,
         * timestamp ended 32 bits,
         * type (0 for buy 1 for rent) 1 bit,
         * maybe add later other info/flags
         */
        uint256[] auctionResults;
    }

    mapping(uint256 => UserInfo) internal _users; // tokenId => UserInfo

    mapping(string => PlayerData) internal players; // player uuid => Player Info

    constructor(
        string memory name_,
        string memory symbol_,
        address _auctionAddr
    ) ERC721(name_, symbol_) {
        admin = msg.sender;
        auction = IOverCollateralizedAuction(_auctionAddr);
    }

    /// @notice set the user and expires of a NFT
    /// @dev The zero address indicates there is no user
    /// Throws if `tokenId` is not valid NFT
    /// @param user  The new user of the NFT
    /// @param expires  UNIX timestamp, The new user could use the NFT before expires
    function setUser(
        uint256 tokenId,
        address user,
        uint64 expires
    ) public virtual {
        require(
            _isApprovedOrOwner(msg.sender, tokenId),
            "ERC721: transfer caller is not owner nor approved"
        );
        UserInfo storage info = _users[tokenId];
        info.user = user;
        info.expires = expires;
        emit UpdateUser(tokenId, user, expires);
    }

    /// @notice Get the user address of an NFT
    /// @dev The zero address indicates that there is no user or the user is expired
    /// @param tokenId The NFT to get the user address for
    /// @return The user address for this NFT
    function userOf(uint256 tokenId) public view virtual returns (address) {
        if (uint256(_users[tokenId].expires) >= block.timestamp) {
            return _users[tokenId].user;
        } else {
            return address(0);
        }
    }

    /// @notice Get the user expires of an NFT
    /// @dev The zero value indicates that there is no user
    /// @param tokenId The NFT to get the user expires for
    /// @return The user expires for this NFT
    function userExpires(uint256 tokenId)
        public
        view
        virtual
        returns (uint256)
    {
        return _users[tokenId].expires;
    }

    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override
        returns (bool)
    {
        return
            interfaceId == type(IERC4907).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 tokenId
    ) internal virtual override {
        super._beforeTokenTransfer(from, to, tokenId);

        if (from != to && _users[tokenId].user != address(0)) {
            delete _users[tokenId];
            emit UpdateUser(tokenId, address(0), 0);
        }
    }

    function _burn(uint256 tokenId)
        internal
        override(ERC721, ERC721URIStorage)
    {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function mint(string calldata identifier) external {
        if (msg.sender != admin) revert InvalidCaller();
        if (players[identifier].maxMintable <= players[identifier].countMinted)
            revert PlayerMaxCap(players[identifier].maxMintable);
        _mint(msg.sender, ++currTokenId);
        players[identifier].countMinted++;
    }

    function createAuction(
        uint256 tokenId,
        uint32 delayToStart,
        uint32 bidPeriod,
        uint32 revealPeriod,
        uint96 reservePrice
    ) external {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner) revert InvalidCaller();
        if (
            _users[tokenId].user != address(0) &&
            _users[tokenId].expires < block.timestamp + 1
        ) revert CannotAuctionRentedNFT();
        // add check if already up for auction in auction contract?
        auction.createAuction(
            address(this),
            tokenId,
            uint32(block.timestamp) + delayToStart,
            bidPeriod,
            revealPeriod,
            reservePrice
        );
    }
}
