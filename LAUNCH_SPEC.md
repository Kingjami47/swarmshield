# SwarmShield — Launch Specification

Everything the IMD swarm needs to take this repo from code to a live, guarded Uniswap v4 pool.
Target: **launch.open, kind `univ4_hook`, Ethereum mainnet (chainId 1)**, submitted at
https://explorer.imd.fun/launch during the hackathon build window (Oct 7–21).

**Repository (fill in after the GitHub push):** `https://github.com/<YOUR_GITHUB>/swarmshield`
— pass this as `repoUrl` (with the commit SHA of HEAD as `baseCommit`) whenever the launch flow
asks for the project repository.

---

## 1. What the swarm builds

One hook contract, deployed from this repo (Foundry):

- `src/SwarmShieldHook.sol` — the hook (see README for mechanics)
- `src/OracleAttestation.sol` — EIP-712 attestation verification (IdentityMD Oracle domain v2)
- `src/interfaces/IIntake.sol` — Intake v2 interface

Launch flow (standard `univ4_hook`): the LaunchFactory deploys the token, the hook is deployed
beside it, and the pool is seeded with the hook attached.

### Hook permission flags (v4-core, Jan 2025 layout)

```
beforeRemoveLiquidity (1<<9) | beforeSwap (1<<7) | beforeSwapReturnDelta (1<<3) = 0x288
```

The deployer must mine a CREATE2 salt so the hook address ends with these bits
(`script/DeploySepolia.s.sol` contains a reference miner). If the IMD pipeline deploys via its
own factory, the same flag constraint applies to whatever address it produces.

### Pool fee mode

- **Dynamic-fee pool** (`fee = 0x800000`): the hook overrides the LP fee per swap —
  2% (20000) while unverified, 0.30% (3000) once a positive quorum verdict is stored.
- **Static-fee pool** (policy 1.25%): the override is ignored by v4-core and the hook degrades
  gracefully — trust pricing still applies through the 1% surcharge (below).

Either mode satisfies the product. If the factory supports it, prefer the dynamic fee.

### Constructor arguments (in order)

| # | Arg | Value |
|---|-----|-------|
| 1 | `_poolManager` | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` (IMD launch PoolManager — same on all chains per docs) |
| 2 | `_token` | `$token` — the token the factory deploys for this launch |
| 3 | `_intake` | `0xa43e6F75ee006411F79Ac1C84120606C2330DE82` (Intake v2, same on every chain) |
| 4 | `_imd` | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` (IMD, Ethereum mainnet) |
| 5 | `_oraclePrice` | `500000000000000000` (0.5 IMD) |
| 6 | `_oracleSigner` | The current `oracle-1` signer — fetch `GET https://api.imd.fun/oracle/requests?status=attested&limit=1` and read `.requests[0].signer` at deploy time (was `0x5598aa9146215bc13eb26f2c692ad1461fd32982`) |
| 7 | `_oracleBody` | The final question body from §3, with `$token` and `$hook` substituted, as compact UTF-8 bytes |
| 8 | `_flushTo` | `0x000000000000000000000000000000000000dEaD` |
| 9 | `_surchargeBps` | `100` (1%) |
| 10 | `_protectedLpFee` | `20000` (2%) |
| 11 | `_trustedLpFee` | `3000` (0.30%) |
| 12 | `_rugShieldBps` | `1000` (10% of in-range liquidity per 24h bucket) |
| 13 | `_verdictTtl` | `2592000` (30 days) |

No owner role is required by the hook (it is ownerless); `$owner` may be the paying wallet if
the pipeline requires one.

---

## 2. Launch fields (paste into the launch flow)

```
onchain:        univ4_hook
chainId:        1
pairWith:       eth
token name:     SwarmShield
token symbol:   SHIELD
economics:      { "poolBps": 9000, "remainderTo": "<paying wallet>" }
```

`request` (paste-ready):

> Deploy the SwarmShield hook from this Foundry repo as a Uniswap v4 hook launch: build and
> test the contracts (forge test must pass — 18 tests), run the adversarial review, then deploy
> the token (name SwarmShield, symbol SHIELD) with the hook beside it and seed the pool with
> the hook attached. The hook is ownerless. Use the constructor arguments in LAUNCH_SPEC.md §1,
> substituting the deployed token address into the oracle body. The hook address must carry the
> permission flags 0x288 (beforeSwap, beforeSwapReturnDelta, beforeRemoveLiquidity) in its low
> 14 bits — mine the deploy salt accordingly. If the pool can be created with the dynamic fee
> (0x800000), use it; otherwise the policy fee works and trust pricing falls back to the
> hook's surcharge. Pin the site to IPFS with the launch.

---

## 3. The oracle question (validated against the live control plane)

Verified via `POST https://api.imd.fun/requests/check` — **judged: true, blockers: []**.

Substitute the real token address for the placeholder before deploying the hook.

```json
{
  "v": 1,
  "question": "At the closing block, do the IMD launch registry at explorer.imd.fun and the X account @SwarmShieldIMD publicly identify the same deployer wallet for token 0x$TOKEN (SwarmShield), and is there any credible public evidence that this deployment impersonates another Identity MD ecosystem project? Answer true if the registry and the X account match on the deployer wallet and no impersonation evidence exists, false otherwise.",
  "chainId": 1,
  "window": { "hours": 24 },
  "answerType": "bool",
  "evidence": "panel",
  "panelSize": 7,
  "quorum": 5,
  "validForSeconds": 2592000,
  "definitions": {
    "deployer_wallet": "The wallet recorded as the paying/deploying wallet of the launch in the IMD launch registry (explorer.imd.fun launch page for 0x$TOKEN).",
    "impersonation": "A deployment that borrows another project's name, ticker, site, or identity within the IMD ecosystem, or claims a team affiliation that cannot be verified."
  },
  "guards": { "min": "0", "max": "1" }
}
```

`validForSeconds` 2592000 (30 days) matches the hook's `verdictTtl`: re-verify monthly to stay
trusted.

Pre-flight (free): run both
`POST /requests/check` (shape above, minus v/window/quorum/validForSeconds/definitions/guards)
and `POST /requests/quote` on the final body. A refused body is a spent payment.

---

## 4. Post-launch checklist

1. Etherscan verification of token + hook (source is in the repo; byte-checked against the
   launch's recorded commit).
2. First `verify()` run: fund the hook's payer wallet with ≥0.5 $IMD, call `verify()` → the
   Intake event appears → panel investigates → attestation arrives → `hook.isTrusted()` flips
   (fees 0.3%, no surcharge). Screenshot the whole chain for the X thread.
3. Rug-shield demo: attempt a >10%/day LP removal from a fresh wallet — expect the revert.
4. Publish the launch + hook addresses on X and in the IMD Radar hackathon entry
   (contract address = token, deployer receives the prize).
5. Re-verify every ~29 days to keep trusted terms.

## 5. Risks the swarm's audit should confirm

- Surcharge never reverts swaps: the cut is clamped to the PoolManager's actual balance
  (`take` cannot overdraw) and to int128.
- Hook deltas settle inside the swap's lock (take happens inside `beforeSwap`) — no
  `CurrencyNotSettled` bricking.
- `onOracleResult` fits the 200k callback gas budget (decode + ecrecover + one slot write).
- The rug shield caps removals per 24h bucket with geometric decay (10% of remaining), does
  not block adds or fee collects (`liquidityDelta == 0` passes).
- No owner, no upgradeability, no admin paths; the oracle body is fixed at construction.
