// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {ICreditMatchedLiquidity} from "./ICreditMatchedLiquidity.sol";

/// @notice The ERC-20 functions the reference uses. Not audited: never deploy without an external audit.
/// @custom:security Not audited. Never deploy without an external audit.
interface IERC20Like {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice The two functions of the widely deployed aggregator interface a price feed must expose. The answer is the
///         price of one whole base token in whole quote tokens, scaled by 10^decimals. Not audited: never deploy without
///         an external audit.
/// @custom:security Not audited. Never deploy without an external audit.
interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice The trading status of a base token in its reference market, and since when it holds. `Trading`: in session
///         and trading, since the session opened or trading resumed. `SessionBreak`: closed between sessions on the
///         market's schedule, since the break began. `Halted`: stopped outside the schedule with no set time to resume,
///         reported across scheduled breaks until trading resumes, since the halt began. `Terminal`: it will not trade
///         there again, as after a delisting or a redemption. `Unknown` is zero, so that an unset source never reads as
///         trading. An adapter can derive it from an asset status interface on the token, a feed's market-status report
///         or an issuer's pause flag. Not audited: never deploy without an external audit.
/// @custom:security Not audited. Never deploy without an external audit.
interface ITradingStatus {
    enum TradingStatus {
        Unknown,
        Trading,
        SessionBreak,
        Halted,
        Terminal
    }

    function tradingStatus() external view returns (TradingStatus status, uint64 since);
}

/// @notice A v3-style position manager reduced to what the reference needs, with amounts named base and quote rather
///         than token0 and token1. Withdrawn amounts and fees stay owed to the position token until collected.
///         `amountsAt` returns the amounts the position's liquidity holds at a given price, which against a Uniswap v3
///         manager an implementation computes with its tick and liquidity math libraries. Prices are quote units per
///         1e18 base units. Not audited: never deploy without an external audit.
/// @custom:security Not audited. Never deploy without an external audit.
interface IPositionManagerLike {
    function mint(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 baseDesired,
        uint256 quoteDesired,
        address recipient
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 baseUsed, uint256 quoteUsed);
    function decreaseLiquidity(uint256 tokenId, uint128 liquidity) external returns (uint256 base, uint256 quote);
    function collect(uint256 tokenId, address recipient, uint256 baseMax, uint256 quoteMax)
        external
        returns (uint256 base, uint256 quote);
    function positions(uint256 tokenId)
        external
        view
        returns (address pool, int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 owedBase, uint256 owedQuote);
    function amountsAt(uint256 tokenId, uint256 price) external view returns (uint256 base, uint256 quote);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice The ERC-721 function used to check that a holder owns the identity it names. Not audited: never deploy
///         without an external audit.
/// @custom:security Not audited. Never deploy without an external audit.
interface IERC721OwnerOf {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice ERC-165. Not audited: never deploy without an external audit.
/// @custom:security Not audited. Never deploy without an external audit.
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

/// @title CreditMatchedLiquidity
/// @notice Reference implementation of the Credit-Matched Liquidity draft. One lender per contract: its quote balance
///         is what it lends. The lender lists each pool with a price feed, a trading-status source for a base token
///         traded in sessions, and terms; a position's owed amount is the quote it took plus a charge fixed at open,
///         and never grows. A price set before the current session opened, or read while the base is not trading, is
///         not used. Fees in the quote token pay the lender first; fees in the base token stay in the position.
///         Unwinding settles at the feed's price and never sends the base token through this contract, so a transfer
///         registry that blocks it cannot strand a position. When no price has come for the hand-over delay past the
///         due date, or a day after the base stopped trading for good, the position is handed over without a price:
///         the lender takes the quote, up to what is owed, and the position token if that quote falls short; if it
///         does not, the position token goes to the holder. A position with nothing owed is never unwound or handed
///         over. Prices are bounded by `MAX_PRICE` and every product of a price and an amount is computed in 512 bits;
///         every movement of the quote token is counted by the balance that changed, not the amount requested.
/// @dev Not audited. A reference for the interface, written against mocks. Never deploy without an external audit.
/// @custom:security Not audited. Never deploy without an external audit.
contract CreditMatchedLiquidity is ICreditMatchedLiquidity, IERC165 {
    /// @notice A pool's terms, set by the lender. A position copies the feed and its limits at open.
    struct PoolTerms {
        address base; // the pool's other token; fixed once listed
        address priceFeed; // prices one whole base token in whole quote tokens
        address statusSource; // ITradingStatus for a base traded in sessions; 0 for one traded continuously
        uint32 maxPriceAge; // seconds
        uint16 limitBps; // quoteLimit = value of baseIn at the feed's price * limitBps / 10000
        uint16 unwindBps; // above 10000
        uint16 gapBps; // open requires the position to stay not unwindable after a price fall of gapBps
        uint16 chargeBps; // owed = quoteLent + quoteLent * chargeBps / 10000, rounded up
        uint32 term; // seconds from open to dueAt
        uint32 handoverDelay; // seconds past dueAt after which a position without a price is handed over
        uint8 baseDecimals;
    }

    uint256 private constant BPS = 10_000;
    uint256 private constant PRICE_UNIT = 1e18; // prices are quote units per 1e18 base units
    /// @notice The highest price used, in quote units per 1e18 base units. A higher answer is not usable, so that no
    ///         valuation, threshold or settlement can overflow for amounts up to 2**128.
    uint256 public constant MAX_PRICE = 1e48;
    uint256 private constant MAX_AMOUNT = type(uint128).max;
    /// @notice The shortest hand-over delay the lender may list, the floor the draft requires: longer than the
    ///         longest scheduled closure of a major stock market, so that a feed that does not answer while its market
    ///         is closed is not taken for dead when it reopens, and longer than the halts that end with trading
    ///         resuming. `listPool` reverts with `BadTerms` below it, so no position records a shorter delay.
    uint32 public constant MIN_HANDOVER_DELAY = 14 days;
    /// @notice How long after the `since` of a terminal status a position is handed over for it: a day in which the
    ///         holder can still close, which needs no price, and keep its part.
    uint32 public constant TERMINAL_GRACE = 1 days;

    IERC20Like private immutable _quote;
    uint8 private immutable _quoteDecimals;
    IPositionManagerLike private immutable _manager;
    address private immutable _registry;
    address public immutable lender;

    address private _fallback;
    uint256 private _count;
    bool private _locked;
    mapping(address => PoolTerms) private _terms;
    mapping(uint256 => Position) private _positions;

    event PoolListed(address indexed pool, PoolTerms terms);
    event LenderFallbackSet(address indexed fallbackAddress);

    error NotLender();
    error BadTerms();
    error ZeroAddress();
    error ZeroAmount();
    error AboveQuoteLimit();
    error NotAgentOwner();
    error UnwindableAtOpen();
    error NotOpen();
    error NotHolder();
    error NotUnwindable();
    error PriceUnusable();
    error TransferFailed();
    error ShortPayment(uint256 received, uint256 owed);
    error Reentrant();

    modifier lock() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyLender() {
        if (msg.sender != lender) revert NotLender();
        _;
    }

    constructor(address quote_, address manager_, address registry_, address lender_, address fallback_) {
        if (quote_ == address(0) || manager_ == address(0) || lender_ == address(0) || fallback_ == address(0)) {
            revert ZeroAddress();
        }
        uint8 d = IERC20Like(quote_).decimals();
        if (d > 18) revert BadTerms();
        _quote = IERC20Like(quote_);
        _quoteDecimals = d;
        _manager = IPositionManagerLike(manager_);
        _registry = registry_;
        lender = lender_;
        _fallback = fallback_;
    }

    // ---------------------------------------------------------------- lender

    /// @notice Lists `pool`, or changes its terms for positions opened from now on.
    function listPool(address pool, PoolTerms calldata terms) external onlyLender {
        PoolTerms storage t = _terms[pool];
        if (pool == address(0) || terms.base == address(0) || terms.priceFeed == address(0)) revert ZeroAddress();
        if (t.base != address(0) && t.base != terms.base) revert BadTerms();
        if (
            terms.unwindBps <= BPS || terms.gapBps >= BPS || terms.limitBps == 0 || terms.maxPriceAge == 0
                || terms.term == 0 || terms.handoverDelay < MIN_HANDOVER_DELAY
        ) revert BadTerms();
        if (terms.baseDecimals != IERC20Like(terms.base).decimals() || terms.baseDecimals > 18) revert BadTerms();
        // The feed's decimals and its current answer must give a price within bounds.
        (, int256 answer,,,) = IPriceFeed(terms.priceFeed).latestRoundData();
        if (answer <= 0 || answer > type(int128).max) revert BadTerms();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 a = uint256(answer); // 0 < answer <= type(int128).max, checked above
        if (_normalize(a, IPriceFeed(terms.priceFeed).decimals(), terms.baseDecimals) == 0) revert BadTerms();
        _terms[pool] = terms;
        emit PoolListed(pool, terms);
    }

    function setLenderFallback(address fallback_) external onlyLender {
        if (fallback_ == address(0)) revert ZeroAddress();
        _fallback = fallback_;
        emit LenderFallbackSet(fallback_);
    }

    /// @notice Takes quote the contract is not lending.
    function withdraw(address to, uint256 amount) external onlyLender {
        _send(_quote, to, amount);
    }

    // ---------------------------------------------------------------- views

    function quoteToken() external view returns (address) {
        return address(_quote);
    }

    function identityRegistry() external view returns (address) {
        return _registry;
    }

    function lenderFallback() external view returns (address) {
        return _fallback;
    }

    function oracleOf(address pool) external view returns (address) {
        return _terms[pool].priceFeed;
    }

    function termsOf(address pool) external view returns (PoolTerms memory) {
        return _terms[pool];
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ICreditMatchedLiquidity).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function quoteLimit(address pool, uint256 baseIn) public view returns (uint256 limit) {
        PoolTerms storage t = _terms[pool];
        if (t.priceFeed == address(0)) return 0;
        uint256 price = _readPrice(t.priceFeed, t.statusSource, t.maxPriceAge, t.baseDecimals);
        if (price == 0) return 0;
        if (baseIn > MAX_AMOUNT) baseIn = MAX_AMOUNT; // more than any supply; keeps the arithmetic in range
        limit = MulDiv.mulDiv(MulDiv.mulDiv(baseIn, price, PRICE_UNIT), t.limitBps, BPS);
        uint256 available = _quote.balanceOf(address(this));
        if (limit > available) limit = available;
    }

    function position(uint256 positionId) external view returns (Position memory) {
        return _positions[positionId];
    }

    function health(uint256 positionId) external view returns (uint256 valueInQuote, uint256 owed, bool unwindable) {
        Position storage p = _positions[positionId];
        if (p.status != Status.Open) return (0, 0, false);
        valueInQuote = _value(p, _price(p));
        owed = p.owed;
        unwindable = _unwindable(p, valueInQuote);
    }

    // ---------------------------------------------------------------- open

    function open(
        address pool,
        uint256 baseIn,
        uint256 quoteToBorrow,
        int24 tickLower,
        int24 tickUpper,
        uint256 agentId
    ) external lock returns (uint256 positionId) {
        if (baseIn == 0 || quoteToBorrow == 0) revert ZeroAmount();
        if (quoteToBorrow > quoteLimit(pool, baseIn)) revert AboveQuoteLimit();
        if (agentId != 0 && (_registry == address(0) || IERC721OwnerOf(_registry).ownerOf(agentId) != msg.sender)) {
            revert NotAgentOwner();
        }
        PoolTerms memory t = _terms[pool];
        (uint256 tokenId, uint256 baseUsed, uint256 quoteUsed) =
            _mint(pool, IERC20Like(t.base), baseIn, quoteToBorrow, tickLower, tickUpper);

        positionId = ++_count;
        Position storage p = _positions[positionId];
        p.holder = msg.sender;
        p.agentId = agentId;
        p.pool = pool;
        p.positionManager = address(_manager);
        p.tokenId = tokenId;
        p.priceFeed = t.priceFeed;
        p.statusSource = t.statusSource;
        p.maxPriceAge = t.maxPriceAge;
        p.unwindBps = t.unwindBps;
        p.gapBps = t.gapBps;
        p.openedAt = uint64(block.timestamp);
        p.dueAt = uint64(block.timestamp) + t.term;
        p.handoverDelay = t.handoverDelay;
        p.baseIn = baseUsed;
        p.quoteLent = quoteUsed;
        p.owed = quoteUsed + MulDiv.mulDivUp(quoteUsed, t.chargeBps, BPS);
        p.status = Status.Open;

        // The position must survive a gap of gapBps in the price, as across a weekend, without becoming unwindable.
        if (_unwindable(p, _value(p, MulDiv.mulDiv(_price(p), BPS - t.gapBps, BPS)))) revert UnwindableAtOpen();
        emit PositionOpened(positionId, msg.sender, agentId, pool, baseUsed, quoteUsed);
    }

    /// @dev Takes `baseIn` from the holder, mints with what arrived and at most `quoteToBorrow` of the lender's quote,
    ///      and returns the base the position did not take. Quote it did not take stays with the lender. Amounts are
    ///      measured by balance: `quoteUsed` is what left the lender, `baseUsed` what left this contract.
    function _mint(
        address pool,
        IERC20Like base,
        uint256 baseIn,
        uint256 quoteToBorrow,
        int24 tickLower,
        int24 tickUpper
    ) private returns (uint256 tokenId, uint256 baseUsed, uint256 quoteUsed) {
        uint256 baseBefore = base.balanceOf(address(this));
        uint256 baseHere = _take(base, msg.sender, baseIn);
        uint256 quoteBefore = _quote.balanceOf(address(this));
        _approve(base, baseHere);
        _approve(_quote, quoteToBorrow);
        (tokenId,,,) = _manager.mint(pool, tickLower, tickUpper, baseHere, quoteToBorrow, address(this));
        _approve(base, 0);
        _approve(_quote, 0);
        quoteUsed = quoteBefore - _quote.balanceOf(address(this));
        uint256 baseLeft = base.balanceOf(address(this)) - baseBefore;
        baseUsed = baseHere - baseLeft;
        if (baseLeft > 0) _send(base, msg.sender, baseLeft);
    }

    // ---------------------------------------------------------------- fees

    /// @dev Reads no price. Only the quote fees are collected. Base fees stay owed to the position token, so they go to
    ///      the holder with the token at close and are settled with the rest of the position at unwind.
    function applyFees(uint256 positionId) external lock returns (uint256 toLender, uint256 toHolder) {
        Position storage p = _positions[positionId];
        if (p.status != Status.Open) revert NotOpen();
        uint256 owed = p.owed;
        if (owed > 0) {
            toLender = _collectQuote(p.tokenId, address(this), owed);
            owed -= toLender < owed ? toLender : owed;
            p.owed = owed;
        }
        if (owed == 0) {
            toHolder = _collectQuote(p.tokenId, p.holder, type(uint256).max);
        }
        emit FeesApplied(positionId, toLender, toHolder);
    }

    // ---------------------------------------------------------------- close

    /// @dev Reads no price and moves no base token: the holder gets the position token back, liquidity and fees in it.
    function close(uint256 positionId) external lock {
        Position storage p = _positions[positionId];
        if (p.status != Status.Open) revert NotOpen();
        if (msg.sender != p.holder) revert NotHolder();
        uint256 owed = p.owed;
        p.owed = 0;
        p.status = Status.Closed;
        uint256 repaid;
        if (owed > 0) {
            repaid = _take(_quote, msg.sender, owed);
            if (repaid < owed) revert ShortPayment(repaid, owed);
        }
        _manager.transferFrom(address(this), msg.sender, p.tokenId);
        emit PositionClosed(positionId, repaid);
    }

    // ---------------------------------------------------------------- unwind

    /// @dev Every amount goes from the position manager straight to its recipient: the quote to this contract, the
    ///      lender's base to the fallback address, and the holder's part stays owed to the position token, which goes
    ///      to the holder. If the base cannot reach the fallback address, the position token goes there instead.
    ///      Without a usable price, the position is handed over once a hand-over is due, and the call reverts before.
    function unwind(uint256 positionId) external lock {
        Position storage p = _positions[positionId];
        if (p.status != Status.Open) revert NotOpen();
        if (p.owed == 0) revert NotUnwindable(); // nothing owed: only the holder's close ends it
        uint256 price = _readPrice(p.priceFeed, p.statusSource, p.maxPriceAge, _terms[p.pool].baseDecimals);
        if (price == 0) {
            if (!_handoverDue(p)) revert PriceUnusable();
            _handOver(positionId, p);
            return;
        }
        if (!_unwindable(p, _value(p, price))) revert NotUnwindable();

        uint256 owed = p.owed;
        uint256 tokenId = p.tokenId;
        p.owed = 0;
        p.status = Status.Unwound;

        (uint256 recovered, uint256 baseHeld) = _withdrawQuote(tokenId, owed);
        address tokenTo = p.holder;
        uint256 rest = owed - recovered;
        if (rest > 0 && baseHeld > 0) {
            uint256 baseForRest = MulDiv.mulDivUp(rest, PRICE_UNIT, price);
            if (baseForRest > baseHeld) baseForRest = baseHeld;
            IERC20Like base = IERC20Like(_terms[p.pool].base);
            uint256 before = base.balanceOf(_fallback);
            try _manager.collect(tokenId, _fallback, baseForRest, 0) {
                uint256 worth = MulDiv.mulDiv(base.balanceOf(_fallback) - before, price, PRICE_UNIT);
                recovered += worth < rest ? worth : rest;
            } catch {
                tokenTo = _fallback; // the base cannot leave the pool now: the lender keeps the claim on it
            }
        }
        _manager.transferFrom(address(this), tokenTo, tokenId);
        emit PositionUnwound(positionId, recovered, owed - recovered);
    }

    /// @dev Settles without a price: the lender takes the quote, up to what is owed. If that covers what is owed, the
    ///      rest is the holder's, which needs no price to tell, and the position token goes to the holder, as after an
    ///      unwind at a price. If not, the base cannot be split without a price, and the lender takes the position
    ///      token at its fallback address, with all the base still owed to it, the holder's part included. No base
    ///      token moves.
    function _handOver(uint256 positionId, Position storage p) private {
        uint256 owed = p.owed;
        uint256 tokenId = p.tokenId;
        p.owed = 0;
        p.status = Status.HandedOver;
        (uint256 recovered,) = _withdrawQuote(tokenId, owed);
        _manager.transferFrom(address(this), recovered == owed ? p.holder : _fallback, tokenId);
        emit PositionHandedOver(positionId, recovered, owed - recovered);
    }

    /// @dev Removes all of the position's liquidity and collects its quote, up to `owed`, to this contract. Returns
    ///      what arrived, at most `owed`, and the base left owed to the position token. Reads no price.
    function _withdrawQuote(uint256 tokenId, uint256 owed) private returns (uint256 recovered, uint256 baseHeld) {
        (,,, uint128 liquidity,,) = _manager.positions(tokenId);
        if (liquidity > 0) _manager.decreaseLiquidity(tokenId, liquidity);
        uint256 quoteHeld;
        (,,,, baseHeld, quoteHeld) = _manager.positions(tokenId);
        if (quoteHeld > 0 && owed > 0) {
            recovered = _collectQuote(tokenId, address(this), owed);
            if (recovered > owed) recovered = owed;
        }
    }

    // ---------------------------------------------------------------- internals

    /// @dev Due dates, delays and price ages are measured in hours and days; the seconds a block producer can shift a
    ///      timestamp by do not matter at that scale, so the timestamp comparisons below are deliberate.
    function _unwindable(Position storage p, uint256 value) private view returns (bool) {
        if (p.owed == 0) return false; // repaid in full: never unwindable, at the due date or after it
        // forge-lint: disable-next-line(block-timestamp)
        if (p.dueAt != 0 && block.timestamp >= p.dueAt) return true;
        return value < MulDiv.mulDivUp(p.owed, p.unwindBps, BPS); // value * 10000 < owed * unwindBps, exactly
    }

    /// @dev The position's liquidity at the feed's price, plus what is already owed to the position token.
    function _value(Position storage p, uint256 price) private view returns (uint256) {
        (uint256 base, uint256 quote) = _manager.amountsAt(p.tokenId, price);
        (,,,, uint256 owedBase, uint256 owedQuote) = _manager.positions(p.tokenId);
        return quote + owedQuote + MulDiv.mulDiv(base + owedBase, price, PRICE_UNIT);
    }

    function _price(Position storage p) private view returns (uint256 price) {
        price = _readPrice(p.priceFeed, p.statusSource, p.maxPriceAge, _terms[p.pool].baseDecimals);
        if (price == 0) revert PriceUnusable();
    }

    /// @dev Called when no price is usable. A hand-over is due, whatever the due date, once `TERMINAL_GRACE` has
    ///      passed since the base stopped trading for good, as its status source reports: a terminal status whose
    ///      `since` is ahead of the block has begun no grace. Otherwise it is due from `handoverDelay` past the due
    ///      date, once no price has come for that long: the base halted for longer than the delay, or, while it trades,
    ///      while its status is unknown or while a terminal status is in its grace, the feed silent for longer than the
    ///      delay, no answer of that time giving a price, the session aside. An unknown status, which a failing source
    ///      also gives, counts only with a silent feed, whatever its `since`, so that a source failing for a moment
    ///      cannot stand in for a price missing for the delay. A feed that is late but not silent, as when a session
    ///      has just opened, is waited for, and so is the end of a session break, however long.
    function _handoverDue(Position storage p) private view returns (bool) {
        (ITradingStatus.TradingStatus status, uint64 since) = _status(p.statusSource);
        // Delisted or redeemed: no price will come, and the holder has had a day to close.
        // forge-lint: disable-next-line(block-timestamp)
        if (status == ITradingStatus.TradingStatus.Terminal && block.timestamp >= uint256(since) + TERMINAL_GRACE) {
            return true;
        }
        // forge-lint: disable-next-line(block-timestamp)
        if (p.dueAt == 0 || block.timestamp < uint256(p.dueAt) + p.handoverDelay) return false;
        if (status == ITradingStatus.TradingStatus.SessionBreak) return false; // the reopening price will come
        if (status == ITradingStatus.TradingStatus.Halted) {
            // forge-lint: disable-next-line(block-timestamp)
            return block.timestamp > uint256(since) + p.handoverDelay; // halted for longer than the delay
        }
        // Trading, Unknown, or Terminal in its grace: only a feed silent for the whole delay shows that no price has
        // come, and a terminal status in its grace does not hold back the hand-over that such a feed makes due.
        return _feedPrice(p.priceFeed, p.handoverDelay, 0, _terms[p.pool].baseDecimals) == 0;
    }

    /// @dev The base's trading status and since when; trading since 0 for a base with no status source, which trades
    ///      continuously. A source that fails, has no code or answers outside the enumeration reads as unknown since 0,
    ///      so that it can neither make a call revert nor read as trading.
    function _status(address source) private view returns (ITradingStatus.TradingStatus, uint64) {
        if (source == address(0)) return (ITradingStatus.TradingStatus.Trading, 0);
        (bool ok, bytes memory data) = source.staticcall(abi.encodeCall(ITradingStatus.tradingStatus, ()));
        if (!ok || data.length < 64) return (ITradingStatus.TradingStatus.Unknown, 0);
        (uint256 status, uint256 since) = abi.decode(data, (uint256, uint256));
        if (status > uint256(type(ITradingStatus.TradingStatus).max) || since > type(uint64).max) {
            return (ITradingStatus.TradingStatus.Unknown, 0);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return (ITradingStatus.TradingStatus(status), uint64(since)); // both in range, checked above
    }

    /// @dev Quote units per 1e18 base units, or 0 when no price is usable. For a base traded in sessions, a price
    ///      counts only while the base trades, and only if it was set after the current session opened or trading
    ///      resumed: a feed keeps its last answer through a weekend and may refresh its time without a new price, so
    ///      its age alone cannot show that the price still holds.
    function _readPrice(address feed, address source, uint32 maxAge, uint8 baseDecimals)
        private
        view
        returns (uint256)
    {
        (ITradingStatus.TradingStatus status, uint64 since) = _status(source);
        if (status != ITradingStatus.TradingStatus.Trading) return 0;
        return _feedPrice(feed, maxAge, since, baseDecimals);
    }

    /// @dev The feed's answer as quote units per 1e18 base units, or 0 when the answer is not usable by itself (see
    ///      `_answer` and `_normalize`) or was set before `notBefore`.
    function _feedPrice(address feed, uint32 maxAge, uint256 notBefore, uint8 baseDecimals)
        private
        view
        returns (uint256)
    {
        (uint256 answer, uint256 updatedAt) = _answer(feed, maxAge);
        if (answer == 0 || updatedAt < notBefore) return 0;
        try IPriceFeed(feed).decimals() returns (uint8 feedDecimals) {
            return _normalize(answer, feedDecimals, baseDecimals);
        } catch {
            return 0;
        }
    }

    /// @dev An answer of the feed, the price of one whole base token in whole quote tokens times 10^feedDecimals, as
    ///      quote units per 1e18 base units; 0 when the feed has more than 18 decimals or the price is out of bounds.
    function _normalize(uint256 answer, uint8 feedDecimals, uint8 baseDecimals) private view returns (uint256 price) {
        if (feedDecimals > 18) return 0;
        price = MulDiv.mulDiv(
            answer, 10 ** (18 + uint256(_quoteDecimals)), 10 ** (uint256(feedDecimals) + uint256(baseDecimals))
        );
        if (price > MAX_PRICE) return 0;
    }

    /// @dev The feed's answer and its time, or a zero answer when it is not above zero, implausibly large, never
    ///      updated, from the future, or older than `maxAge`, or when the feed cannot answer.
    function _answer(address feed, uint32 maxAge) private view returns (uint256, uint256) {
        try IPriceFeed(feed).latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            if (answer <= 0 || answer > type(int128).max) return (0, 0);
            // forge-lint: disable-next-line(block-timestamp)
            if (updatedAt == 0 || updatedAt > block.timestamp || block.timestamp - updatedAt > maxAge) return (0, 0);
            // forge-lint: disable-next-line(unsafe-typecast)
            return (uint256(answer), updatedAt); // 0 < answer <= type(int128).max, checked above
        } catch {
            return (0, 0);
        }
    }

    /// @dev Collects up to `max` of the position's quote to `to`, and returns what arrived there.
    function _collectQuote(uint256 tokenId, address to, uint256 max) private returns (uint256) {
        uint256 before = _quote.balanceOf(to);
        _manager.collect(tokenId, to, 0, max);
        return _quote.balanceOf(to) - before;
    }

    /// @dev Pulls `amount` from `from` and returns what arrived, which a token with a transfer fee makes smaller.
    function _take(IERC20Like token, address from, uint256 amount) private returns (uint256) {
        uint256 before = token.balanceOf(address(this));
        if (!token.transferFrom(from, address(this), amount)) revert TransferFailed();
        return token.balanceOf(address(this)) - before;
    }

    function _send(IERC20Like token, address to, uint256 amount) private {
        if (!token.transfer(to, amount)) revert TransferFailed();
    }

    function _approve(IERC20Like token, uint256 amount) private {
        if (!token.approve(address(_manager), amount)) revert TransferFailed();
    }
}

/// @title MulDiv
/// @notice Full-precision `a * b / denominator`: the product is kept in 512 bits, so only a result that does not fit in
///         256 bits reverts. Not audited: never deploy without an external audit.
/// @dev The method of Remco Bloemen's "Mathematics in Solidity", as used by the Uniswap v3 FullMath library.
/// @custom:security Not audited. Never deploy without an external audit.
library MulDiv {
    error MulDivOverflow();

    function mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0; // low 256 bits of a * b
            uint256 prod1; // high 256 bits of a * b
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (denominator <= prod1) revert MulDivOverflow(); // also covers a zero denominator
            if (prod1 == 0) return prod0 / denominator;

            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (0 - denominator); // largest power of two dividing the denominator
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inverse = (3 * denominator) ^ 2; // inverse of the odd denominator modulo 2**4
            inverse *= 2 - denominator * inverse; // modulo 2**8
            inverse *= 2 - denominator * inverse; // 2**16
            inverse *= 2 - denominator * inverse; // 2**32
            inverse *= 2 - denominator * inverse; // 2**64
            inverse *= 2 - denominator * inverse; // 2**128
            inverse *= 2 - denominator * inverse; // 2**256
            result = prod0 * inverse;
        }
    }

    function mulDivUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        result = mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) > 0) {
            if (result == type(uint256).max) revert MulDivOverflow();
            result += 1;
        }
    }
}
