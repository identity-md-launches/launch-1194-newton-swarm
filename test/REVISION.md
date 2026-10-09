# Refund-recipient regression review

Finding `06899bd6b5f4ff744515e25ad21b0c48973d0e760bebcd1a1e9bddcd22cd1f41`
is settled for this revision. The author's fix delivers excess reservation claims directly to
the canonical, nonzero recipient supplied in `hookData`. Empty or malformed data retains the
router fallback. The former edge-test name and comment now identify that legacy case explicitly.

The existing reproduction of a partial exact-output sell still requires IMD settlement, as the
author explicitly stated. It now also verifies that the failed attempt rolls back the input,
allowance, price, accrued fee and refund claim before retrying with IMD funding. This retained
integration constraint is not reported again as an unaddressed refund-recipient defect.

Additional checks cover:

- Independent refund destinations on consecutive buys and sells through the same router,
  including returning to the empty-data fallback.
- A third-party recipient's ownership, redemption without the swap router, and separation from
  treasury sweeps.
- 1,000 noncanonical-address fuzz cases per token sort order, comparing fees, refund, balances
  and price against the identical empty-data trade.
- Direct refunds to randomly selected actors mixed into the existing handler's legacy swaps,
  claim redemption, gifts, liquidity changes, time changes and sweeps. The nine conservation,
  backing, fee and supply invariants still apply to both token sort orders.
- Redemption of both reserved-side refunds against the real Robinhood PoolManager and IMD,
  after sweeping the hook's fees.

Validation: `forge build` and the default `forge test`; the fork suite additionally runs with
`ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com`. The default offline run intentionally
skips fork setup when that variable is absent. Build outputs, caches and local logs are directed
to `test/scratch/` with `FOUNDRY_OUT` and `FOUNDRY_CACHE_PATH`; they are not deliverables.

Results on 2026-10-09: build succeeded; default suite 169 passed, 0 failed, 1 skipped (fork setup);
all 9 live fork tests passed. The invariant campaign ran 128 sequences of depth 40, with 5,120
calls and zero reverts. No new finding is raised by this scoped regression review.
