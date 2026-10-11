# SwarmShield — Launch Runbook (launch.open, 4 steps)

Total protocol cost: **0.5 $IMD** (paid only at step 4). Steps 1–3 are free pre-flight.
Fill the two placeholders in `launch_open.json` first: `<YOUR_GITHUB>` and `<baseCommit>`.

## Step 1 — Pin the repo (free)

```bash
curl -s -X POST https://api.imd.fun/requests/import \
  -H 'content-type: application/json' \
  -d '{"url":"https://github.com/YOUR_GITHUB/swarmshield","kind":"contracts"}'
```

Response → `source.repoUrl` (canonical) and `source.baseCommit` (40-hex).
Paste both into `launch_open.json`. If `ok:false`, fix what `problems` says
(private repo, missing, oversized) and retry.

## Step 2 — Pre-flight check (free)

```bash
curl -s -X POST https://api.imd.fun/requests/check \
  -H 'content-type: application/json' \
  -d '{"action":"launch.open","input":'"$(cat launch/launch_open.json)"'}'
```

Expect: `judged: true`, `blockers: []`, a plain-words `plan`.
Any blocker → fix → rerun. Do NOT proceed with blockers; a refused launch
after payment is a spent 0.5 IMD.

## Step 3 — Quote (free)

```bash
curl -s -X POST https://api.imd.fun/requests/quote \
  -H 'content-type: application/json' \
  -d '{"action":"launch.open","input":'"$(cat launch/launch_open.json)"'}'
```

Confirms the price (0.5 IMD) and payment params; quote TTL ~600s.

## Step 4 — Fire (costs 0.5 IMD)

Either paste `launch_open.json` into https://explorer.imd.fun/launch (browser flow),
or pay via x402 from code and POST the same body to the launch endpoint.

## After the launch fires

1. Read the launch record: `GET https://api.imd.fun/launches/:id` — token, hook,
   pool addresses + `repoUrl`/manifest of what the swarm actually deployed.
2. Etherscan-verify token + hook; byte-check against the recorded commit.
3. First `verify()` (0.5 $IMD from the payer wallet) → panel investigates →
   `isTrusted()` flips → fees drop 2% → 0.3%. Screenshot everything for X.
4. Post the thread (BRANDING.md), then submit at https://imdradar.site/hackathon
   **before Oct 21**.
