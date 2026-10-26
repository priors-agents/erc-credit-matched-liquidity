// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Credit-Matched Liquidity (draft ERC)
/// @notice A lender supplies the quote side of a concentrated-liquidity position that a holder pairs with base tokens it
///         owns. The position stays in escrow; quote fees pay the lender first; the holder closes by repaying; anyone
///         unwinds it once the price feed `oracleOf(pool)` names, never the pool's own price, says it no longer covers
///         the loan. A price set while the base's reference market was closed is never used. When no price comes for
///         the hand-over delay past the due date, or a day after the base stopped trading for good, anyone hands the
///         position over to the lender without a price. Not audited: never deploy without an external audit.
/// @dev The ERC-165 identifier is `type(ICreditMatchedLiquidity).interfaceId`.
/// @custom:security Not audited. Never deploy without an external audit.
interface ICreditMatchedLiquidity {
    enum Status {
        None,
        Open,
        Closed,
        Unwound,
        HandedOver
    }

    struct Position {
        address holder; // who opened it and may close it
        uint256 agentId; // the holder's identity in `identityRegistry()`, or 0
        address pool;
        address positionManager; // the ERC-721 contract of the position token
        uint256 tokenId; // the position token, held by this contract while open
        address priceFeed; // the feed of `oracleOf(pool)` at open
        address statusSource; // where the base's trading status is read (ITradingStatus); 0 if it trades continuously
        uint32 maxPriceAge; // seconds after which the feed's answer is not used
        uint16 unwindBps; // unwindable when value * 10000 < owed * unwindBps
        uint16 gapBps; // the price fall a new position had to survive without becoming unwindable
        uint64 openedAt;
        uint64 dueAt; // unwindable from this time on; 0 for no due date
        uint32 handoverDelay; // seconds past dueAt after which a position without a price is handed over; >= 14 days
        uint256 baseIn; // base the position took
        uint256 quoteLent; // quote the position took
        uint256 owed; // quote that `close` takes now
        Status status;
    }

    event PositionOpened(
        uint256 indexed positionId,
        address indexed holder,
        uint256 indexed agentId,
        address pool,
        uint256 baseIn,
        uint256 quoteLent
    );
    event FeesApplied(uint256 indexed positionId, uint256 toLender, uint256 toHolder);
    event PositionClosed(uint256 indexed positionId, uint256 repaid);
    event PositionUnwound(uint256 indexed positionId, uint256 recovered, uint256 shortfall);
    event PositionHandedOver(uint256 indexed positionId, uint256 recovered, uint256 outstanding);

    /// @notice The ERC-20 token lent and repaid. Never changes.
    function quoteToken() external view returns (address);

    /// @notice The ERC-721 identity registry `agentId` values refer to, or the zero address.
    function identityRegistry() external view returns (address);

    /// @notice Where the lender takes the base token, and the position token when the base cannot be withdrawn.
    function lenderFallback() external view returns (address);

    /// @notice The price feed for new positions in `pool`, or the zero address for a pool not supported.
    function oracleOf(address pool) external view returns (address priceFeed);

    /// @notice The most quote `open` would lend now against `baseIn`, from the feed's price. 0 when it would lend none.
    function quoteLimit(address pool, uint256 baseIn) external view returns (uint256);

    /// @notice Opens a position: takes `baseIn`, lends at most `quoteToBorrow`, adds both between the ticks and keeps the
    ///         position token in escrow. Returns the position's id (never 0).
    function open(
        address pool,
        uint256 baseIn,
        uint256 quoteToBorrow,
        int24 tickLower,
        int24 tickUpper,
        uint256 agentId
    ) external returns (uint256 positionId);

    /// @notice The position `positionId`, zero-valued with status None when it was never opened.
    function position(uint256 positionId) external view returns (Position memory);

    /// @notice The position's value at the feed's price, what it owes, and whether anyone may unwind it now.
    function health(uint256 positionId) external view returns (uint256 valueInQuote, uint256 owed, bool unwindable);

    /// @notice Collects the position's quote fees and pays the lender first, up to what is owed. Anyone.
    function applyFees(uint256 positionId) external returns (uint256 toLender, uint256 toHolder);

    /// @notice Repays what is owed and returns the position token to the holder. The holder only.
    function close(uint256 positionId) external;

    /// @notice Withdraws the position and settles it at the feed's price, the lender first. Anyone, once unwindable.
    ///         Without a usable price, once a hand-over is due, it gives the lender the quote, up to what is owed, and
    ///         the position token if that quote falls short; otherwise the holder gets the position token. Never for a
    ///         position with nothing owed.
    function unwind(uint256 positionId) external;
}
