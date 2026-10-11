# SwarmShield 🛡️

**The swarm-verified liquidity guard — a Uniswap v4 hook that prices swarm trust into a pool.**

Built for the first Identity MD Hackathon (Oct 7–21, 2026). Launched through the IMD protocol
(`univ4_hook`, Ethereum mainnet). The pool starts in *protected* mode and only earns *trusted*
terms when a quorum of independent IMD agents — paid through the IdentityMD oracle, verified
with an EIP-712 attestation — confirms the project is authentic and not another copycat.

## Why

IMD Radar already flags **17+ copycats and fake tokens**. Trust is the ecosystem's #1 problem,
and today it lives in a website table. SwarmShield moves it on-chain, into the pool itself:

- **Unverified pools are expensive to trade** (2% LP fee + 1% surcharge that burns) — LPs are
  compensated for the risk they take.
- **Verified pools are cheap** (0.30% LP fee, no surcharge) — the swarm's verdict saves
  everyone money, every swap.
- **Nobody can rug fast** — LP removals are capped at 10% of in-range liquidity per day,
  deployer included.

The verification is permissionless to trigger: anyone can pay the 0.5 $IMD oracle fee and ask
the swarm. The question is fixed at deployment; the answer must be a quorum-signed EIP-712
attestation delivered by the Intake contract for a request this contract paid for.

## Mechanics (v1)

| Mechanic | Where | Detail |
|---|---|---|
| Trust-priced LP fee | `beforeSwap` (dynamic-fee pools) | Returns `fee \| OVERRIDE_FLAG`: `20000` (2%) unverified → `3000` (0.30%) trusted. Ignored by static-fee pools (graceful). |
| Protection surcharge | `beforeSwap` + `beforeSwapReturnDelta` | While unverified, takes `surchargeBps` (1%) of the specified currency via a positive hook delta, pulled immediately with `poolManager.take` inside the swap's lock. Clamped to the PoolManager's real balance — a swap can never brick. |
| Rug shield | `beforeRemoveLiquidity` | `removedThisBucket + delta ≤ rugShieldBps × current in-range liquidity` per UTC-day bucket. Geometric decay: every day you can take at most 10% of what is left. Adds and fee collects (`liquidityDelta == 0`) are never blocked. |
| Surcharge sink | `flush(currency)` | Permissionless; sends accumulated surcharges to `flushTo` (`0xdEaD` by default): an unverified pool bleeds to the burn address. |
| Swarm verification | `verify()` / `onOracleResult` / `onOracleFailure` / `submit` | Pays 0.5 $IMD to Intake v2 (`0xa43e…de82`, action `oracle.request@oracle-1`), callback delivers `OracleAttestation` + signature; verified EIP-712 (domain `"IdentityMD Oracle"` v2, verifyingContract = hook). `agreed ≥ quorum` required; bool answers only; failures are unsigned and never grant trust. Verdict TTL: 30 days. |

No owner. No admin. No upgrades. The oracle body is immutable after construction.

## Repository

```
src/SwarmShieldHook.sol        the hook
src/OracleAttestation.sol      EIP-712 attestation verification (IdentityMD Oracle v2)
src/interfaces/IIntake.sol     Intake v2 interface
script/DeploySepolia.s.sol     CREATE2-mined deployment (flags 0x288)
test/SwarmShieldHook.t.sol     18 tests (all passing)
test/mocks/MockERC20.sol       test token
LAUNCH_SPEC.md                 everything the swarm needs to launch this
launch/launch_open.json        paste-ready launch.open body (fill 2 placeholders)
launch/RUNBOOK.md              4-step launch runbook (import -> check -> quote -> fire)
```

## Run

```bash
forge install        # restores pinned deps from foundry.lock
forge test           # 18 passing tests (via-ir, solc 0.8.26, cancun)
```

Dependencies (pinned in `foundry.lock`, installed automatically by `forge install`):

| Package | Pin |
|---|---|
| `Uniswap/v4-core` | tag `v4.0.0` (`e50237c`) |
| `foundry-rs/forge-std` | tag `v1.17.0` (`f3dae6e`) |
| `transmissions11/solmate` | rev `89365b8` |

`foundry.toml` sets `bytecode_hash = "none"` and `cbor_metadata = false` per the IMD launch
requirement for imported Foundry repositories (deterministic bytecode for the audit panel).

## Tests cover

- Surcharge on ERC20 and native ETH paths, exactIn and static/dynamic pools
- LP fee override applied only on dynamic-fee pools (read from the Swap event: 20000 → 3000)
- Verdict flow end-to-end with a real EIP-712 signature from a test oracle key
- Reverts: wrong signer, weak panel, replayed attestation, non-bool answer, wrong pool,
  non-PoolManager callers
- Failure hook clears pending without granting trust
- Rug shield caps, bucket rollover, geometric decay
- Flush to burn address

## Judging criteria mapping

| Criterion | How SwarmShield meets it |
|---|---|
| 1. Launch through the IMD protocol during the build period | `launch.open` kind `univ4_hook` on Ethereum mainnet (LAUNCH_SPEC.md) |
| 2. V4 hook or custom contract with meaningful functionality beyond a token | A v4 hook with three on-chain mechanics + a live oracle consumer — no token required to understand the value, but the launch provides one |
| 3. Dedicated X account | @SwarmShieldIMD |
| 4. Submit via IMD Radar before the deadline | Yes |

## Differentiation

- vs **static fee lists / manual "verified" badges**: the verdict is signed, quorum-based,
  expires, and is enforced by the pool itself.
- vs **pay-to-mint reputation tokens** (user tipping): SwarmShield is *evidence-based* — an
  agent panel investigates the deployer, registry and X presence; users cannot buy a verdict.
- vs **LP locks**: locks are binary and gameable; a rate-limited withdrawal with geometric
  decay still lets LPs exit while making a rug a 10-days-minimum affair.

## Status

- [x] Contracts + tests green (`forge test`: 18/18)
- [x] Oracle question validated live against `POST /requests/check` (judged: true, blockers: [])
- [ ] Launch via explorer.imd.fun/launch (univ4_hook, chainId 1)
- [ ] First `verify()` → trusted flip (screenshot chain for X)
