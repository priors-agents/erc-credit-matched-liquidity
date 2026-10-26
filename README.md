# Credit-Matched Liquidity (draft ERC)

> **Not audited. Never deploy without an external audit.** The contracts in `src/` are a reference for a draft
> interface, written against mocks. Nobody outside their authors has reviewed them, and they must not hold real funds.

A lender supplies the quote side of a concentrated-liquidity position (Uniswap v3 or v4 ticks) that a holder pairs with
base tokens it owns, such as a tokenized stock. The position sits in an escrow the holder cannot withdraw from. Fees in
the quote token pay the lender first. The holder closes by repaying and gets the position back. Anyone may unwind it
once the price feed the escrow names for the pool, never the pool's own price, says it no longer covers the loan, or
once it is due. A price set while the stock's market was closed is never used, and a stock token's transfer registry
cannot strand a position: the lender's share goes to a fallback address it names, and the holder's share waits in the
position token.

**Status: draft, submitted as [ethereum/ERCs#2109](https://github.com/ethereum/ERCs/pull/2109).** The text is in
[`ERCS/erc-draft_credit_matched_liquidity.md`](ERCS/erc-draft_credit_matched_liquidity.md). Its `eip: 99908` is a
placeholder until the ERC editors assign a number. Discussion: [Ethereum
Magicians](https://ethereum-magicians.org/t/erc-tba-credit-matched-liquidity/30039). The second revision (2026-10-21)
takes in the review there by Zealynx: a timed hand-over to the lender when no price comes past the due date, a trading
status that tells a session break from a halt and from a delisting or a redemption, and a fix so that a position whose
fees repaid it in full is never unwound. The third revision (2026-10-22) takes in Zealynx's follow-up there: the 14-day
floor on the hand-over delay is a MUST, as the reference already enforced, and a terminal status hands a position over
only a day (`TERMINAL_GRACE`) after the `since` its source reports, so that a holder who is watching can still close,
which needs no price, and keep its part. The fourth revision (2026-10-26) takes in his next point: a hand-over whose
quote covers what is owed gives the position token to the holder, not to the lender.

## Why

Lending against pool positions and leveraged liquidity exist as products (Revert Lend lends against Uniswap v3
positions, Extra Finance offers leveraged liquidity, EulerSwap borrows the output side of a swap just in time), each with
its own contracts and events, and none is a proposed standard. This draft fixes one interface for the case where the
loan funds the position itself, and three rules where such lending has gone wrong:

- **Value from a feed, never from the pool.** Lenders that priced pool shares from the pool's own reserves have been
  drained by flash loans that moved those reserves.
- **No stranded positions.** Tokenized stocks carry a transfer registry that can block an address. A thread on Ethereum
  Magicians (https://ethereum-magicians.org/t/29769) warns that a pool position quoted in stock tokens that can only be
  withdrawn one way can be bricked by it; here no base token passes through the escrow at closing or unwinding.
- **No price from a closed market.** Stock feeds keep Friday's price through the weekend, and Monday's open can gap past
  it. The escrow uses a stock's price only while its reference market is in session and only if the price was set after
  the session opened, and a new position must survive a stated gap.

The open draft "Asset Status Interface for Tokenized Assets" (ethereum/ERCs pull request
https://github.com/ethereum/ERCs/pull/1964, numbered ERC-8392 in its thread https://ethereum-magicians.org/t/29489 and
8391 in the pull request's file) adds token-level views of a reference market's session, its halts and how stale the
asset's valuation is. A conforming escrow MAY derive its status source from such a status; the reference
implementation reads a reduced trading-status interface, `ITradingStatus`, that an adapter over it can provide.

## What is here

| Path | What |
|---|---|
| `ERCS/erc-draft_credit_matched_liquidity.md` | The ERC text, in the ethereum/ERCs template |
| `src/ICreditMatchedLiquidity.sol` | The interface |
| `src/CreditMatchedLiquidity.sol` | A reference escrow and lender, one lender per contract (not audited; never deploy without an external audit) |
| `test/CreditMatchedLiquidity.t.sol` | Foundry tests of the reference against the specification, including manipulated pool prices, stale and closed-market prices, halts, delistings and hand-overs, blocked transfers, a quote token that charges on transfer, token and feed decimals from 0 to 18, and prices at the bounds |
| `test/mocks/Mocks.sol` | Mocks (not audited; never deploy): a v3-style position manager, a price feed, a trading-status source, ERC-20 tokens with a transfer registry and an optional transfer fee, an identity registry |
| `scripts/lint-erc.sh` | Lints the ERC text with eipw the way the ethereum/ERCs CI does |
| `eipw.toml` | The ethereum/ERCs repository's eipw configuration, copied as is |

## Checks

```bash
forge fmt --check
forge build
forge test
scripts/lint-erc.sh   # needs eipw: cargo install eipw --version 0.11.0 --locked
```

CI runs all four on every push (`.github/workflows/ci.yml`).

## Related drafts

- Agent Credit Lines: one interface to borrow, repay and default against any lender to agent identities
  (github.com/priors-agents/erc-agent-credit-lines). A position here is a secured loan; its opening, closing and
  unwinding are the same life a credit line's events record.
- Liquidity Locks: one interface for any contract that locks pool liquidity
  (github.com/priors-agents/erc-liquidity-locks). An escrowed position here is a lock the holder cannot open, with a way
  out for its lender.

## Licence

CC0 1.0 ([LICENSE.md](LICENSE.md)), as the ERC process requires.
