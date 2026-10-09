# Newton Swarm (SNEWT) — Uniswap v4 hooked launch on Robinhood Chain

Newton Swarm is a fixed-supply ERC-20 launched through IMD's Uniswap v4 hook factory, paired with
IMD on Robinhood Chain (chain id 4663). This repository holds the two deployed contracts, their
tests, the launch manifest, and the logo deliverables from the earlier assignment (see
[Logo options](#logo-options) at the end).

| Item | Value |
| --- | --- |
| Token | `SNEWT`, "Newton Swarm", 18 decimals, 1,000,000,000 tokens (1e27 units) minted once to its deployer |
| Hook | `SNEWTHook`, immutable, no owner, CREATE2-mined address with mask `0x20CC` |
| Pool | SNEWT / IMD, LP fee 12500 (1.25%, static), tick spacing 60 |
| Paired currency | IMD, `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` (verified on chain: symbol `IMD`, 18 decimals) |
| PoolManager | `0x8366a39cc670b4001a1121b8f6a443a643e40951` (verified on chain, passed as `$poolManager`) |
| Treasury | `0x5f948c351eb9f0734c28b605bbeee9ab9d04318e`, compile-time constant in the hook |
| Compiler | solc 0.8.26, EVM cancun, optimizer on (200 runs), `bytecode_hash = "none"` |

## Contracts

### `src/SNEWT.sol`

A plain ERC-20: `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `allowance`, `approve`,
`transfer`, `transferFrom`, the two standard events and custom errors. The constructor takes no
arguments and mints the entire supply to `msg.sender`, which at launch is the IMD factory. There is
no mint, burn, owner, pause, blocklist, fee or upgrade function, and the runtime contains no
`DELEGATECALL` or `SELFDESTRUCT`.

What the brief asks for that the token does **not** do, by design of the launch: it does not
reserve or send the swarm's 10% itself. The factory receives the full 1e27 units, sends 10% to the
launch's Merkle distributor, seeds the pool with the other 90%, and forwards any remainder. There is
no developer allocation anywhere in this repository.

### `src/SNEWTHook.sol`

The hook of the launch pool. Configuration in the Wizard's canonical shape:

```json
{
  "hook": "BaseHook",
  "name": "SNEWTHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": false,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true, "afterInitialize": false,
    "beforeAddLiquidity": false, "afterAddLiquidity": false,
    "beforeRemoveLiquidity": false, "afterRemoveLiquidity": false,
    "beforeSwap": true, "afterSwap": true,
    "beforeDonate": false, "afterDonate": false,
    "beforeSwapReturnDelta": true, "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false, "afterRemoveLiquidityReturnDelta": false
  },
  "access": "none (immutable, no owner)",
  "info": { "license": "MIT" }
}
```

It is written directly against the v4-core `IHooks` interface rather than inheriting a periphery
base contract, so every import resolves inside this repository. The constructor stores the
PoolManager and the launch token, makes no external call, and reverts with
`Hooks.HookAddressNotValid` unless its own address carries exactly the five flags above.

**Constructor arguments** (manifest: `["$poolManager", "$token"]`):

| Argument | Meaning |
| --- | --- |
| `IPoolManager manager` | The chain's Uniswap v4 PoolManager. Never hardcoded. |
| `address launchToken` | The SNEWT token, deployed by the factory just before the hook. |

**Permission bits**: `beforeInitialize` (1<<13), `beforeSwap` (1<<7), `afterSwap` (1<<6),
`beforeSwapReturnDelta` (1<<3), `afterSwapReturnDelta` (1<<2). The deployer mines a CREATE2 salt so
that `address & 0x3FFF == 0x20CC`. `HookMiner` in `test/utils/` shows the loop.

**beforeInitialize** accepts exactly one pool: it must contain the launch token, use LP fee 12500 and
tick spacing 60, and no pool may have been opened before (`AlreadyOpened`). It records the paired
currency (the key's other currency, IMD at launch), the pool id and `openedAt = block.timestamp`.
Anything else reverts with `NotLaunchPool`. The caller of `initialize` and the paired token address
are not checked. **Deployment and initialization must be atomic in the factory transaction**, with
the manifest's IMD address. If deployment and initialization are split across transactions, anyone
can initialize SNEWT against a different currency first and permanently bind the hook to that pool.
The initialization callback prevents initializing the pool before the hook has code; it does not
protect a deployed but uninitialized hook.

### The hook fee (M1)

On every swap the hook takes a fee in the paired currency, IMD, on top of the pool's static 1.25% LP
fee. The LP fee is never dynamic and never overridden.

| Time since `openedAt` | `feeNow()` |
| --- | --- |
| 0 s | 4000 bps (40.00%) |
| 15 min | 3075 bps |
| 30 min | 2150 bps |
| 45 min | 1225 bps |
| 59 min 59 s | 302 bps |
| 60 min and forever after | 300 bps (3.00%) |

`feeNow() = 4000 - 3700 * elapsed / 3600` (integer division) during the first hour. The constants
`OPENING_FEE_BPS`, `STANDING_FEE_BPS` and `DECAY_SECONDS` are compile-time constants.

**Definition.** The fee is `feeNow()` basis points of the IMD that actually moved through the pool
in that swap: what the pool received on a buy, what the pool paid out on a sell, subject to integer
rounding. Unspecified-side fees round down. Specified-side reservations round up and are then
scaled down on partial fills; the kept fee can exceed `floor(moved*bps/10000)` by up to two wei of
IMD. For example, a two-wei exact-input buy at opening pays one wei to the pool and one wei in fees.

| Swap | Specified side | How the fee is taken |
| --- | --- | --- |
| Buy, exact input | IMD (input) | `beforeSwap` reserves `fee = x - x*10000/(10000+bps)` so the pool swaps `x - fee`; `afterSwap` reconciles |
| Buy, exact output | SNEWT (output) | `afterSwap` returns `fee = moved*bps/10000` on the unspecified IMD side; the swapper pays `moved + fee` |
| Sell, exact input | SNEWT (input) | `afterSwap` returns `fee = moved*bps/10000`; the swapper receives `moved - fee` |
| Sell, exact output | IMD (output) | `beforeSwap` reserves `fee = ceil(x*bps/(10000-bps))` so the pool pays `x + fee`; `afterSwap` reconciles |

**Reconciliation.** When the fee had to be reserved in `beforeSwap` (specified side is IMD), it is
sized for a full fill. `afterSwap` reads the pool's real `BalanceDelta` on IMD; if less filled than
reserved for, the fee kept is `reserved * moved / expected`. The difference is minted as an ERC-6909
claim on the PoolManager. Partial fills happen at price limits **and at exhausted liquidity bands,
even with the full price limit**, including a launch pool seeded only with SNEWT.

**Refund recipient.** Pass `hookData = abi.encode(refundRecipient)` (one 32-byte, nonzero ABI address)
to mint the claim directly to the swapper or their chosen recipient. The swap router then needs no
ERC-6909 handling to deliver that refund. Empty data, an encoded zero address, a noncanonical
address word, or any other length falls back to `sender`, the PoolManager's caller, usually the
router. This fallback preserves existing integrations; a delta-only router using it can strand
refunds in its own balance. Use the explicit recipient with delta-only routers. The hook trusts the
router to forward the intended destination; this data grants no permission over existing claims or
other swaps. `FeeTaken.sender` remains the router, and `isBuy` follows the requested swap direction
even if nothing fills.

The fee bound counts the recipient's ERC-6909 claim as part of the refund and includes the rounding
dust above. A claim is not an automatic ERC-20 payment. Its holder may transfer it, or approve a
claim redeemer that unlocks the manager, burns the claim and takes IMD to the holder. The regression
suite tests redemption independently of the swap router.

**Exact-output sell settlement.** If the IMD fill is below the reservation, the returned IMD delta
is `moved - reserved < 0`, even with an explicit refund recipient. The net result including the
claim is `moved - kept`, but the seller must front IMD and the router must settle that negative delta
in the same transaction, or use an authorized claim-burning settlement flow. A seller with no IMD
using a delta-only router, or a router that only accepts a positive output delta (`TAKE_ALL` style),
cannot complete this partial sell. This can occur with a close price limit or exhausted liquidity,
including limited IMD liquidity early in launch. An exact-input sell charges on the actual IMD
output in `afterSwap` and has no reservation or IMD pre-funding requirement.

**Where the fee lives.** `afterSwap` mints the fee to the hook as an ERC-6909 claim
(`poolManager.mint`). This needs no token balance in the manager, so the very first buy on the
launch pool, seeded with SNEWT only, works (tested). `pending()` is that claim balance, `collected()`
the lifetime total taken from swaps, `swept()` the lifetime total delivered.

**sweep().** Anyone may call it. It unlocks the PoolManager, burns the hook's whole IMD claim and
`take`s the tokens to `TREASURY`. It reverts with `NothingToSweep` when the claim balance is zero.
Any IMD claims transferred to the hook by third parties are swept too. If IMD ever refused a transfer
to the treasury, `sweep()` would revert but swaps would be unaffected: fees keep accruing as claims.
The fee is deliberately kept in IMD, the pair currency, as the brief specifies; it is not converted
to ETH.

**Large-request limitation.** The retained reservation mechanism rejects a specified IMD
amount that cannot be represented with the full-fill fee in v4's 128-bit deltas: an absolute amount above
`type(uint128).max`, or a reserved fee or expected pool amount above `type(int128).max` (for example
`type(int256).max` or `type(int256).min`). Those revert with `UnrepresentableFee`, including requests
that a hookless pool could partially fill. This is stricter than the brief's int256-only overflow
exception; changing it requires changing how specified-side fees are reserved. A one-wei swap is
never turned into a zero-amount swap: if the net would be zero the fee is zero.

### Properties

- No `selfdestruct`, no `delegatecall`, no proxy, no owner, no setter. Every library call is
  `internal`, so the bytecode has no link placeholders.
- Every callback checks `msg.sender == poolManager`, including `unlockCallback`. Callbacks whose
  flags are off revert `HookNotImplemented` even for the PoolManager.
- `sweep()` follows checks-effects-interactions and cannot run inside another unlock (the
  PoolManager refuses nested unlocks).
- Runtime code 6,583 bytes; initcode including both constructor words 7,586 bytes: far under
  EIP-170 and EIP-3860.

## Deployment parameters and operational responsibilities

The IMD launch factory deploys both contracts from the bytecode built here and writes the final
manifest. `launch.json` in this repository carries the values the brief fixes:

- `token.contract = "SNEWT"`, name "Newton Swarm", symbol "SNEWT", 18 decimals;
- `hook.contract = "SNEWTHook"`, `constructorArgs = ["$poolManager", "$token"]`,
  `permissions = ["beforeInitialize", "beforeSwap", "afterSwap", "beforeSwapReturnDelta", "afterSwapReturnDelta"]`;
- `pool.pairedCurrency = 0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, `fee = 12500`,
  `tickSpacing = 60`, `initialPrice = "79228162514264337593543950336"` (provenance only; the factory
  sets the opening price from the 2,500 IMD opening market cap and the token's address).

Operational notes:

- **Nothing to configure after launch.** The hook has no owner and no setter. The treasury, fee
  schedule, pool fee and tick spacing are fixed in code; the PoolManager and token are immutables.
- **CREATE2 salt.** Mine against the revised creation bytecode and the actual constructor arguments;
  a salt calculated for earlier bytecode does not establish the new hook's permission bits.
- **Sweeping** is permissionless. Someone (the treasury, a keeper, anyone) should call `sweep()`
  periodically; until then fees sit as the hook's ERC-6909 claim on the PoolManager, backed by the
  IMD swappers settled. Check `pending()` first to avoid a `NothingToSweep` revert.
- **Opening window.** `openedAt` is set by the factory's `initialize` call, so the 60-minute decay
  starts at launch, not at hook deployment.
- **Routers.** Forward `abi.encode(refundRecipient)` for exact-input buys and exact-output sells,
  or explicitly handle and forward the fallback refund claims. A full price limit does not guarantee
  a full fill. Exact-output sells additionally require a router that can settle IMD in the same
  transaction when the reservation exceeds the fill; choosing a recipient does not remove this
  requirement. See the settlement constraints above.
- **Swap gas.** Measured locally against a hookless pool with the same liquidity, a swap through
  the hook costs about 33k–42k gas more (two hook calls, one or two ERC-6909 mints and the fee
  arithmetic): 148k vs 113k for an exact-input buy, 154k vs 113k for an exact-output sell.

## Tests

```sh
forge build
forge test
forge fmt --check
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-contract SNEWTHookForkTest
```

- `test/SNEWT.t.sol`: metadata, whole supply to the deployer, transfer/approve/transferFrom success
  and failure paths, absence of mint/admin selectors, opcode scan, supply-conservation fuzz.
- `test/SNEWTHook.t.sol`: runs the whole suite twice, with SNEWT as currency0 and as currency1,
  because the token's sort order against IMD is unknown before launch. It covers: permission bits vs.
  the mined address (and that a plain CREATE is refused), constructor zero checks, EIP-3860 size,
  opcode scan, every callback refusing non-PoolManager callers, initialization by the factory and
  refusal of wrong fee / dynamic fee / wrong tick spacing / foreign pool / second pool, the fee
  schedule at fixed points and by fuzz, the four swap shapes at opening, mid-decay and standing fee
  (exact values and fuzzed amounts/times), partial fills with a price limit for all four shapes (the
  two reserved shapes refund claims), a launch-like SNEWT-only pool on a fresh manager, sweep
  success/empty/repeat/reentrancy/gifted claims, the `UnrepresentableFee` domain, the LP fee never
  changing, and a fuzzed random swap sequence checking `pending == collected - swept` and that claims
  are always backed by IMD in the manager.
- `test/SNEWTHook.fork.t.sol`: the same deployment against the real PoolManager and real IMD on a
  Robinhood Chain fork: permission bits, initialize, the four swap shapes, partial-fill refunds and a
  sweep to the real treasury address. It skips cleanly (never passes silently) unless
  `ROBINHOOD_RPC_URL` is set, because the verifier runs offline. All nine fork tests, including the
  new direct-refund regression, passed against the public Robinhood RPC during this revision.
- Refund regressions in `test/SNEWTHook.t.sol` cover full-limit exhaustion of a SNEWT-only band,
  direct claims and their redemption without the swap router, fuzzed price-limited buys/sells at
  different fees, a separate recipient, malformed-data fallback, all four zero-fill event
  directions, and the remaining IMD settlement requirement on partial exact-output sells. They run
  for both token sort orders. The fork suite also checks direct refunds through a delta-only router.

Local test fixtures (`test/utils/`): a mintable `MockERC20` standing in for IMD, `HookMiner`, and
minimal `SwapRouter` / `LiquidityRouter` contracts that settle with the PoolManager and forward any
ERC-6909 claims to the user.

The pinned protected checks (`.imd/reads/protected/univ4_hook/*.protected.t.sol`) were read and the
contracts are written to satisfy them: initialization callback present, permissions equal to the
address flags, no `DELEGATECALL`/`CALLCODE`/`SELFDESTRUCT`, callbacks refusing other callers, the
factory able to initialize the launch pool at fee 12500 / spacing 60, and the token minting the whole
policy supply to its deployer with exact transfers.

## Dependencies

`foundry.toml` is the project's protected configuration (`libs = []`, no remappings, `offline`), so
every dependency is vendored as ordinary files and imported by relative path:

| Path | Source | Commit |
| --- | --- | --- |
| `vendor/v4-core/src` | github.com/Uniswap/v4-core `src/` without `src/test/` | `vendor/v4-core/COMMIT` |
| `vendor/forge-std/src` | github.com/foundry-rs/forge-std `src/` | `vendor/forge-std/COMMIT` |
| `vendor/solmate/src/auth/Owned.sol` | github.com/transmissions11/solmate (needed by v4-core's `ProtocolFees`) | `vendor/solmate/COMMIT` |

The only edit to vendored code is the import path of `Owned` in `vendor/v4-core/src/ProtocolFees.sol`
(from the `solmate/` remapping to a relative path); `forge fmt` was run over the vendored tree.
Licenses are kept next to each copy. Only `SNEWT` and `SNEWTHook` are deployed; v4-core's
`PoolManager` is compiled here for tests only.

## Assumptions and open points

- The hook identifies the paired currency from the pool key rather than hardcoding IMD, so the same
  bytecode would serve on any chain; the factory must deploy and initialize it with IMD atomically.
- The fee basis is the IMD leg of the pool's own delta. The brief says "same pattern as live launch
  #909" without giving its arithmetic; the definition above is the one implemented and tested.
- `beforeInitialize` pins fee 12500 and tick spacing 60 because the brief fixes both. If the policy
  changed either, the hook would need a rebuild (there is intentionally no setter).
- Tests are not an audit. The hook holds swap fees in claims on the PoolManager and should get an
  independent adversarial review before launch, as the IMD process requires.

## Logo options

Five distinct 1024×1024, opaque RGB PNGs are in [logos/](logos/README.md), in the requested order: mascot, geometric icon, ticker lettermark, coin emblem, and meme illustration. The selected primary image is [artifacts/logo.png](artifacts/logo.png), an exact copy of option 2.

The creator's [reference image](https://fxumiqjngmabtgvruvka.supabase.co/storage/v1/object/public/forum-attachments/posts/mv125ia6-cuvk4b.png) supplied the green amphibian scholar, white curled wig, purple accents, cobalt blue and gold palette. Each variation was drawn by OpenAI's built-in image generation tool (`image_gen.imagegen`), using that reference. Five drafts were generated, one per approach; all five designs are retained in the final logo files and none were rejected. There were no redraws. The downloaded reference is `artifacts/reference.png`. Redundant 1254×1254 intermediate renders were removed to keep the source bundle below the 8 MiB upload limit.

The generator returned 1254×1254 renders. FFmpeg performed only Lanczos resampling to the required 1024×1024 size and RGB PNG encoding. The final files were then losslessly re-encoded with mixed PNG prediction and compression level 9; every decoded RGB byte was compared before and after and remained identical. This preserves the full color depth and image detail. [artifacts/compression.json](artifacts/compression.json) records the byte savings and decoded pixel hashes. No script, vector or code drew the logo artwork, and no typography was added afterward. Only option 3 contains text: `SNEWT`.

I inspected every image and the [size-check sheet](artifacts/size-check.png). Columns are options 1–5. Rows show 160-pixel squares, 64-pixel squares on light, 64-pixel squares on dark, and pairs of actual 32-pixel circular crops on light and dark. The primary has a full-square blue background, one dominant face-and-wig mark, and no text, frame or outer border. Its face, eyes and white wig remain readable at 32 pixels.

Option 2 was selected for its simple shapes. The other drafts remain useful alternatives: option 1 has more portrait detail, option 3 intentionally contains lettering, option 4 intentionally has a coin rim, and option 5 has a busier comic treatment. Those distinctions make them less suitable than option 2 for the primary's strict borderless, text-free, 32-pixel requirement.

### Logo verification

`src/LogoPng.sol` validates PNG headers, dimensions and chunk bounds; it is an asset-checking library, not a launch contract. `test/LogoAssets.t.sol` verifies all six output files, distinct options, the primary copy, and rejection of malformed or incorrectly sized files. `python3 scripts/check_logos.py` (standard library only) verifies chunk CRCs, complete compressed image data, 1024×1024 dimensions, RGB opacity, unique hashes, and the selected copy; its recorded result is [artifacts/validation.json](artifacts/validation.json). `python3 scripts/preview_logos.py` recreates the inspection sheet with the system FFmpeg.
