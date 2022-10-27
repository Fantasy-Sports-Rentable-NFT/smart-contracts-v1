// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.17;

import "../solmate/tokens/ERC721.sol";
import "../solmate/utils/ReentrancyGuard.sol";
import "../solmate/utils/SafeTransferLib.sol";
import "./IOverCollateralizedAuctionErrors.sol";
import "../interfaces/IOverCollateralizedAuction.sol";

/// @title An on-chain, over-collateralization, sealed-bid, second-price auction
contract OverCollateralizedAuction is
    IOverCollateralizedAuctionErrors,
    ReentrancyGuard,
    IOverCollateralizedAuction
{
    using SafeTransferLib for address;

    /// @notice A mapping storing auction parameters and state, indexed by
    ///         the ERC721 contract address and token ID of the asset being
    ///         auctioned.
    mapping(address => mapping(uint256 => Auction)) public auctions;

    /// @notice A mapping storing bid commitments and records of collateral,
    ///         indexed by: ERC721 contract address, token ID, auction index,
    ///         and bidder address. If the commitment is `bytes20(0)`, either
    ///         no commitment was made or the commitment was opened.
    mapping(address => mapping(uint256 => mapping(uint64 => mapping(address => Bid)))) // ERC721 token contract // ERC721 token ID // Auction index // Bidder
        public bids;

    function createAuction(
        address tokenContract,
        uint256 tokenId,
        uint32 startTime,
        uint32 bidPeriod,
        uint32 revealPeriod,
        uint96 reservePrice
    ) external nonReentrant {
        Auction storage auction = auctions[tokenContract][tokenId];

        if (startTime == 0) {
            startTime = uint32(block.timestamp);
        } else if (startTime < block.timestamp) {
            revert InvalidStartTimeError(startTime);
        }
        if (bidPeriod < 1 hours) {
            revert BidPeriodTooShortError(bidPeriod);
        }
        if (revealPeriod < 1 hours) {
            revert RevealPeriodTooShortError(revealPeriod);
        }

        auction.seller = msg.sender;
        auction.startTime = startTime;
        auction.endOfBiddingPeriod = startTime + bidPeriod;
        auction.endOfRevealPeriod = startTime + bidPeriod + revealPeriod;
        // Reset
        auction.numUnrevealedBids = 0;
        // Both highest and second-highest bid are set to the reserve price.
        // Any winning bid must be at least this price, and the winner will
        // pay at least this price.
        auction.highestBid = reservePrice;
        auction.secondHighestBid = reservePrice;
        // Reset
        auction.highestBidder = address(0);
        // Increment auction index for this item
        auction.index++;

        ERC721(tokenContract).transferFrom(msg.sender, address(this), tokenId);

        emit AuctionCreated(
            tokenContract,
            tokenId,
            msg.sender,
            startTime,
            bidPeriod,
            revealPeriod,
            reservePrice
        );
    }

    function commitBid(
        address tokenContract,
        uint256 tokenId,
        bytes20 commitment
    ) external payable nonReentrant {
        if (commitment == bytes20(0)) {
            revert ZeroCommitmentError();
        }

        Auction storage auction = auctions[tokenContract][tokenId];

        if (
            block.timestamp < auction.startTime ||
            block.timestamp > auction.endOfBiddingPeriod
        ) {
            revert NotInBidPeriodError();
        }

        uint64 auctionIndex = auction.index;
        Bid storage bid = bids[tokenContract][tokenId][auctionIndex][
            msg.sender
        ];
        // If this is the bidder's first commitment, increment `numUnrevealedBids`.
        if (bid.commitment == bytes20(0)) {
            auction.numUnrevealedBids++;
        }
        bid.commitment = commitment;
        if (msg.value != 0) {
            bid.collateral += uint96(msg.value);
        }
    }

    function revealBid(
        address tokenContract,
        uint256 tokenId,
        uint96 bidValue,
        bytes32 nonce
    ) external nonReentrant {
        Auction storage auction = auctions[tokenContract][tokenId];

        if (
            block.timestamp <= auction.endOfBiddingPeriod ||
            block.timestamp > auction.endOfRevealPeriod
        ) {
            revert NotInRevealPeriodError();
        }

        uint64 auctionIndex = auction.index;
        Bid storage bid = bids[tokenContract][tokenId][auctionIndex][
            msg.sender
        ];

        // Check that the opening is valid
        bytes20 bidHash = bytes20(keccak256(abi.encode(nonce, bidValue)));
        if (bidHash != bid.commitment) {
            revert InvalidOpeningError(bidHash, bid.commitment);
        } else {
            // Mark commitment as open
            bid.commitment = bytes20(0);
            auction.numUnrevealedBids--;
        }

        uint96 collateral = bid.collateral;
        if (collateral < bidValue) {
            // Return collateral
            bid.collateral = 0;
            msg.sender.safeTransferETH(collateral);
        } else {
            // Update record of (second-)highest bid as necessary
            uint96 currentHighestBid = auction.highestBid;
            if (bidValue > currentHighestBid) {
                auction.highestBid = bidValue;
                auction.secondHighestBid = currentHighestBid;
                auction.highestBidder = msg.sender;
            } else {
                if (bidValue > auction.secondHighestBid) {
                    auction.secondHighestBid = bidValue;
                }
                // Return collateral
                bid.collateral = 0;
                msg.sender.safeTransferETH(collateral);
            }

            emit BidRevealed(
                tokenContract,
                tokenId,
                bidHash,
                msg.sender,
                nonce,
                bidValue
            );
        }
    }

    function endAuction(address tokenContract, uint256 tokenId)
        external
        nonReentrant
    {
        Auction storage auction = auctions[tokenContract][tokenId];
        if (auction.index == 0) {
            revert InvalidAuctionIndexError(0);
        }

        if (block.timestamp <= auction.endOfBiddingPeriod) {
            revert BidPeriodOngoingError();
        } else if (block.timestamp <= auction.endOfRevealPeriod) {
            if (auction.numUnrevealedBids != 0) {
                // cannot end auction early unless all bids have been revealed
                revert RevealPeriodOngoingError();
            }
        }

        address highestBidder = auction.highestBidder;
        if (highestBidder == address(0)) {
            // No winner, return asset to seller.
            ERC721(tokenContract).safeTransferFrom(
                address(this),
                auction.seller,
                tokenId
            );
        } else {
            // Transfer auctioned asset to highest bidder
            ERC721(tokenContract).safeTransferFrom(
                address(this),
                highestBidder,
                tokenId
            );
            uint96 secondHighestBid = auction.secondHighestBid;
            auction.seller.safeTransferETH(secondHighestBid);

            // Return excess collateral
            Bid storage bid = bids[tokenContract][tokenId][auction.index][
                highestBidder
            ];
            uint96 collateral = bid.collateral;
            bid.collateral = 0;
            if (collateral - secondHighestBid != 0) {
                highestBidder.safeTransferETH(collateral - secondHighestBid);
            }
        }
    }

    function withdrawCollateral(
        address tokenContract,
        uint256 tokenId,
        uint64 auctionIndex
    ) external nonReentrant {
        Auction storage auction = auctions[tokenContract][tokenId];
        uint64 currentAuctionIndex = auction.index;
        if (auctionIndex > currentAuctionIndex) {
            revert InvalidAuctionIndexError(auctionIndex);
        }

        Bid storage bid = bids[tokenContract][tokenId][auctionIndex][
            msg.sender
        ];
        if (bid.commitment != bytes20(0)) {
            revert UnrevealedBidError();
        }

        if (auctionIndex == currentAuctionIndex) {
            // If bidder has revealed their bid and is not currently in the
            // running to win the auction, they can withdraw their collateral.
            if (msg.sender == auction.highestBidder) {
                revert CannotWithdrawError();
            }
        }
        // Return collateral
        uint96 collateral = bid.collateral;
        bid.collateral = 0;
        msg.sender.safeTransferETH(collateral);
    }

    /// @notice Gets the parameters and state of an auction in storage.
    /// @param tokenContract The address of the ERC721 contract for the asset auctioned.
    /// @param tokenId The ERC721 token ID of the asset auctioned.
    function getAuction(address tokenContract, uint256 tokenId)
        external
        view
        returns (Auction memory auction)
    {
        return auctions[tokenContract][tokenId];
    }
}
