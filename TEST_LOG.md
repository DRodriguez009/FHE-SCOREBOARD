# TEST_LOG.md

## Fix + Verify — 2026-08-17 (a mis-settled line, and anon could mint coins)

### Result: PASS

Started from a report that "Albert beat Tommy on Friday but Tamayo lost his bet."

**The mis-settlement.** The 2026-08-14 `Albert vs Thomas` line auto-settled Monday 07:30 ET
as Thomas winning on commission totals of *Albert 220 vs Thomas 365*. Albert's real Friday
total was **570** — his second Friday deal (350) was still pending when the settler ran, and
was approved afterwards. Since `20260813160000` approval stamps `approved_at = created_at`
(so a sale counts on the day it was made — correct, and it stays), that late approval landed
back on Friday and changed the verdict of an already-closed line. Every bet on the line was
on Albert, so seven bets were wrongly marked lost and nobody was paid.

Neither `settle_bet_line` nor `cancel_bet_line` accepts a closed line, and the admin screen
rendered no buttons for one, so the correction had to be hand-written SQL. That is the second
time a disputed bet couldn't be settled from the screen (see the 2026-08-04 note in
`index.html`). Fixed properly in `20260817150000`.

| Check | Result | Notes |
|-------|--------|-------|
| Friday's line corrected | PASS | `winning_side` b→a; all 7 Albert bets `won`; Tamayo +320, Bryan Sequeira +752 (709/22/11/5/3/2) |
| Payouts are gross, not profit | PASS | stakes were debited at `place_bet`, so a win credits `round(amount × odds)` — matches every prior settled bet |
| Corrections are attributable | PASS | all 7 `coin_ledger` rows carry `reason` + `actor` via `app.coin_reason`/`app.coin_actor`; every historical row has those null |
| `sb_resettle_line` reverse+re-apply | PASS | throwaway admin/agents/line/bets: wrong settle → 800/660, correct to a → 1120/400, void → 1000/500 (stakes back), all rolled back, 0 residue |
| Refuses an open line | PASS | `line is open, not settled — use settle_bet_line or cancel_bet_line` |
| Settler defers a day with pending sales | PASS | synthetic past-day line with one pending sale stayed `open` instead of settling on partial data |
| Settler settles once approved | PASS | same line, after approval (600 vs 200) → settled, side a |
| Settler self-corrects a late approval | PASS | reproduced Friday exactly: settled as b, then a late approval landed → next run flipped it to a with an explanatory note |
| A `[manual]` verdict survives the settler | PASS | admin correction marked `[manual]` was **not** overridden — human decision outranks the commission math |
| Live dry run on real data | PASS | the new settler would touch **0** current lines — nothing else is mis-settled |
| Cron now runs twice a weekday | PASS | `30 11,20 * * 1-5` — 07:30 ET was before the pending queue is worked, which caused this |
| Admin screen can correct a closed line | PASS | browser-verified: settled lines show "Correct → X won" + "Void & refund"; the tie-cancelled line offers both sides; open lines unchanged |
| Restored PIN works end-to-end | PASS | signed in as Derrick Rodriguez on the real login → "full admin access" (session revoked after) |
| JS syntax | PASS | `node --check` on the extracted script |

**🔴 Found while reading the grants: anon could mint unlimited coins.**
`credit_wallet(type, id, delta)` adds coins to any wallet, takes **no credential**, and was
executable by `anon`. Verified live from a real anon REST call with the publishable key that
ships in `index.html`: **HTTP 200**, and it returns the new balance. Agent UUIDs are public on
the board, so anyone could credit themselves any amount — or drain a rival with a negative
delta. `auto_settle_daily_matchups()` and `read_wallet()` were in the same state.

The 2026-07-31 migration *tried* to close the settler with
`revoke execute ... from anon, authenticated` — but a new function's EXECUTE belongs to
**PUBLIC**, which anon inherits, so the ACL still read `=X/postgres` and the revoke was a
no-op. Any revoke must name `public` too.

| Check | Result | Notes |
|-------|--------|-------|
| `credit_wallet` before | **FAIL (hole confirmed)** | anon REST call → HTTP 200 + balance returned |
| `credit_wallet` after | PASS | `42501 permission denied for function credit_wallet` |
| `auto_settle_daily_matchups` after | PASS | `42501` (first probe was inconclusive — wrong arg shape returned PGRST202, retested with `{}`) |
| `read_wallet` after | PASS | `42501` |
| `sb_resettle_line` (internal) | PASS | `42501` — server-only, no auth of its own |
| `admin_resettle_bet_line` reachable but gated | PASS | anon call with junk credentials → `P0001 invalid admin credentials` |
| Nothing legitimate broke | PASS | neither function is referenced in `index.html` or `scripts/`; real callers are SECURITY DEFINER (run as owner) or pg_cron (runs as postgres) |

### Blockers / Follow-ups:
- [ ] This project has never had a full function-level audit like `goal-leaderboard` got on
  2026-08-14. `credit_wallet` was found by accident. `scripts/audit-guard-probe.py` in
  `fhe-command-center` takes a project ref as `argv[1]` — point it here.
- [ ] A clawback can leave a wallet negative if the winnings were already spent. Allowed on
  purpose (refusing would recreate the un-correctable hole) and reported in the RPC's return,
  but `place_bet` will block that person until they earn it back.

## Fix + Verify — 2026-08-05 (day bucketing was UTC, not Eastern)

### Result: PASS

Surfaced by a question about a number on screen: Albert Gonzalez's best day read **$2,490**
on Jun 30. $760 of that was approved at **8:20 PM ET on Jun 29** — 00:20 UTC on Jun 30 —
so UTC bucketing folded it into the next day.

`calcStreak` and `calcPersonalBest` took the date via `approved_at.slice(0,10)`, which is
the UTC date, and `get_agent_streaks()` used `at time zone 'UTC'`. Everything else on the
board (Today/Week/Month filters) already used the viewer's local time, i.e. Eastern — so
the two disagreed for anything approved after 8 PM ET (7 PM in winter). This office sells
into the evening, so that is not an edge case.

All three now bucket in `America/New_York`. Client date maths steps on a UTC-anchored
calendar (`shiftDayKey` / `weekStartKey`) so a DST change cannot skip or repeat a day.

| Check | Result | Notes |
|-------|--------|-------|
| Streaks unchanged today | PASS | all 15 identical before/after — no current run crosses a boundary |
| Personal bests recomputed | PASS | 10 of 17 agents were inflated; see below |
| Phantom record day removed | PASS | 8 agents "peaked" on 2026-06-30 UTC, which was the Jun 29 evening backfill |
| Albert Gonzalez | PASS | $2,490 Jun 30 → **$1,815 Jul 31** (the actual best day) |
| Unaffected agents stay put | PASS | 7 agents identical — bests already sat mid-day |
| JS syntax | PASS | `node --check` on the extracted script |

Agents whose best day changed: Aaron Matthews ($1,780→$1,265), Abraham Canales
($1,405→$845), Aidan Mueller ($1,725→$1,230), Albert Gonzalez ($2,490→$1,815), Arturo
Perez ($745→$690), Daniel Ramirez ($1,130→$690), Marlon Ramirez ($1,255→$875), Nelson
Santos ($740→$545), Nicolas Fuentes ($1,085→$685), Robert Medio ($1,415→$915).

Note the numbers go DOWN because the old ones were double-counted days, not because
anything was taken away. Worth saying out loud to the floor if anyone notices their record
dropped.

### Blockers / Follow-ups:
- [ ] The Jun 29 evening backfill is still a single lump — every historical sale was
      approved in one sitting, so Jun 29 ET remains an artificially large day for a few
      agents (Aaron, Daniel, Robert now peak there). That is a data-history artifact, not
      a timezone bug; those approvals genuinely happened that evening.
- [ ] Timezone is hardcoded to America/New_York in three places. Fine while there is one
      office; would need config if that ever changes.

## Build — 2026-08-05 (canary + coin audit trail)

### Result: PASS

Two things built off the day's post-mortem: a watchdog for the failure mode that started
it, and an audit trail for the manual ledger edit it ended with.

**1. Silent-truncation canary** — `scripts/canary.mjs`. **Not yet scheduled**: the
workflow that runs it (`.github/workflows/canary.yml`, 09:00 ET weekdays) could not be
pushed, because writing to `.github/workflows/` requires `workflow` scope and the stored
GitHub token has only `gist, read:org, repo`. The file exists locally and has to be added
through the GitHub web UI or after granting the scope. **Until that happens the canary
only runs when someone runs it by hand, which means it is not yet watching anything.**
For every anon-reachable RPC it asks PostgREST how many rows actually matched
(`Prefer: count=exact`) and compares that to how many came back. Divergence = data being
dropped silently, which is precisely what nobody noticed for days. Reads the Supabase URL
and anon key out of index.html so there is one source of truth. Alerts Slack if
`SLACK_WEBHOOK_URL` is set; otherwise the job just fails and GitHub emails.

**2. `get_public_commission_feed` bounded** — the canary's first real run failed on it:
1000 returned / 1030 matched. It has no callers left, so nothing was visibly broken, but
it was a live trap for whoever wrote the next one. Now `limit 1000` explicitly, so the
contract is an honest "most recent 1000" instead of "all of them, except silently not".

**3. `coin_ledger` + trigger** — every Mike Coins movement is now recorded. Implemented as
a trigger on the balance column rather than logging inside `credit_wallet()`, because
coins move by two routes: betting/settlement/house-credit go through the helper, but
`admin_approve_commission` / `admin_bulk_approve_commissions` / `admin_add_commission`
write `set coins = coins + 10` directly. Helper-only logging would have missed every
commission award. A trigger catches all routes including raw operator SQL.

| Check | Result | Notes |
|-------|--------|-------|
| Canary detects real truncation | PASS | first run caught feed 1000/1030 and exited 1 |
| Canary passes when healthy | PASS | 8 endpoints + 2 invariants green, exit 0 |
| Canary negative test | PASS | injected a nonexistent RPC → failure reported, exit 1 |
| No false positive on bounded feed | PASS | `bounded` flag suppresses the growth warning |
| Invariant is a real cross-check | PASS | board per-agent sums vs `get_commission_stats`, counted by a different query path (no join/group) — 1030 rows / $152,800 both match |
| Coin trigger fires | PASS | self-test in an aborting txn: delta=7, balance_after captured, reason+actor captured |
| Self-test left no residue | PASS | RAISE rolled it back — ledger back to 1 row, agent coins back to 410 |
| Ledger not anon-readable | PASS | table read → 42501; `admin_coin_ledger` → P0001 without admin creds |
| Javier correction backfilled | PASS | 1495 delta, balance_after 2247, actor `derrick`, stamped at the real time |

### Blockers / Follow-ups:
- [ ] **The canary is not scheduled yet** — `.github/workflows/canary.yml` exists locally
      but could not be pushed without `workflow` token scope. Add it via the GitHub web UI
      (Actions → New workflow → paste) or re-auth the token with `workflow`. Nothing is
      being watched automatically until then.
- [ ] `SLACK_WEBHOOK_URL` is not set as a repo secret, so once scheduled the canary would
      alert only via GitHub's failure email. Add in repo Settings → Secrets.
- [ ] The canary covers the scoreboard's public surface only. Authenticated endpoints
      (`get_all_commissions_admin`, the command-center NIPR route) are unchecked because
      they need credentials.
- [ ] `reason`/`actor` on coin_ledger are populated only when a caller sets the
      `app.coin_reason` / `app.coin_actor` GUCs. Existing functions don't, so routine
      movements log with a null reason — delta + timestamp still reconcile against
      commissions and bets. Worth setting in the approval and settlement paths later.
- [ ] No UI for the ledger. `admin_coin_ledger(username, password, wallet_id, limit)`
      exists and is admin-gated; nothing renders it yet.

## Fix + Verify — 2026-08-05 (approved deals not reaching the scoreboard)

### Feature Under Test: Commission feed completeness / 1000-row API cap
### Result: PASS

**Root cause:** not the approval path. Supabase's PostgREST caps every response at the
project's `Max rows` (1000) and truncates with an HTTP **206, not an error** — so
supabase-js set no `error` and the client aggregated a short list in silence.
`get_public_commission_feed` had crossed the cap (1018 rows), and because the function has
no `ORDER BY`, Postgres returned heap order. Approving a commission is an `UPDATE`, which
rewrites the row to the end of the heap — so the rows past the cut were exactly the
freshly-approved ones. Today's board showed **1** sale against **21** actually approved.

Same cap hit `get_all_commissions_admin` (all statuses, so also >1000). The Pending tab
filters that list client-side, so pending deals could vanish from the approval queue
outright — deals that could not be approved at all, not merely mis-displayed.

**Fix:** `rpcAll()` in index.html pages through with an explicit deterministic sort
(`approved_at,agent_id,amount` for the feed; `id` for admin). Client-only — no DB change
and no dashboard change, so it did not wait on the blocked Supabase MCP grant.

| Check | Result | Notes |
|-------|--------|-------|
| Cap confirmed | PASS | `content-range: 0-999/1018` — function emits 1018, API returns 1000 |
| Newest-rows-dropped theory | PASS | server-side filter `approved_at=gte.2026-08-05` → 21 rows; unfiltered feed → 1 |
| Pagination completeness | PASS | 2 pages → 1020/1020 rows, ordering verified ascending |
| rpcAll via supabase-js | PASS | verbatim function vs live project: 1000 → 1020 rows |
| Today's board | PASS | 1 sale/$170 → 21 sales/$2,470 |
| All-time total | PASS | $149,145 → $151,445 |
| Admin `id.asc` order valid | PASS | bogus-token probe returns P0001 auth raise, not 42703 — column exists |
| JS syntax | PASS | `node --check` on extracted inline script |
| Deploy | PASS | main `0c214a4` → Vercel prod Ready; fhe-scoreboard.vercel.app serves rpcAll |

### Addendum — DB access restored a different way (same day)

The Supabase **MCP** grant is still dead, but the **`supabase` CLI holds a separate token
that never broke**. `supabase db query --linked` goes through the Management API and
connects as `postgres` — full read *and* DDL. The Aug 1 handoff's "DB work is blocked"
was too broad: only the MCP path was blocked. Check the CLI first next time.

| Check | Result | Notes |
|-------|--------|-------|
| CLI auth intact | PASS | `supabase projects list` → all 12 FHE projects |
| Query via Management API | PASS | `current_user` = `postgres`; commissions 1022 approved / 1024 total |
| DDL permitted | PASS | create + drop probe function succeeded |
| **`get_advisors` finally run** | PASS | the one open task from the 2026-08-01 handoff |
| Advisor findings | PASS | 85 total, **all WARN, zero ERROR** |
| ↳ 84 × security_definer_executable | EXPECTED | 42 functions × anon/authenticated; by design — this app has no Supabase auth provider, every RPC guards itself. Consistent with the Aug 1 black-box audit |
| ↳ 1 × function_search_path_mutable | FIXED | `public.odds_for_pair` — a real miss, added by the sportsbook work after the auth pass |
| search_path remediation | PASS | 0 functions in `public` with null proconfig after the ALTER |

Recorded at supabase/migrations/20260805190000_fix_odds_for_pair_search_path.sql.

### Durable fixes — same day, once CLI access was found

All four follow-ups below were closed in one pass. Migration:
supabase/migrations/20260805200000_server_side_board_aggregation.sql

| Check | Result | Notes |
|-------|--------|-------|
| Board aggregates in Postgres | PASS | new `get_scoreboard_totals(p_since)` + `get_agent_streaks()`; loadBoard fetches ~18 rows, not ~1024 |
| **Aggregates match old client math** | PASS | all / today / week / month totals AND sale counts equal per agent — compared against the fully-paginated feed |
| **Streaks match old calcStreak** | PASS | all 17 agents equal; gaps-and-islands in SQL reproduces the UTC-date, ends-yesterday-still-counts semantics |
| Payload per refresh | PASS | 146,953 B (truncated) → 2,934 B — 50× smaller, and no longer truncatable |
| Feed ordering | PASS | `order by approved_at desc` added; newest-first confirmed live |
| get_my_bets signature | PASS | bad-credential probe returns P0001, so the client call shape still resolves after DROP + CREATE |
| Bet history labels | PASS | renders "Picked: Nelson Santos", and derives the matchup from agent columns not the free-text title |
| Board render (deployed logic) | PASS | today = 11 agents / $2,740 / 23 sales, streaks present |
| APP_VERSION bumped | PASS | `2026-08-05-server-side-aggregation-002` live |

**Sibling audit (the shared project `eawpwwctsifzcclrwvww`):** only one real exposure.
`fhe-command-center` `/api/nipr/licenses` did an unbounded select on `nipr_licenses`
(859 rows) then joined in JS — ~141 rows from silently dropping licences out of a
compliance view. Fixed by paging, ordered by `id`; tsc + production build clean; shipped
as `6c8c060` in that repo. Found safe: goal-tracker reads the `gt_agent_overall` view
(48 rows), and `carrier_list` / `carrier_category_summary` aggregate in SQL rather than
returning `carrier_states` (756) or `carrier_appointments` (648) row by row.

### Ledger correction — Javier Hernandez, bet 3b89ba66 (2026-08-05, by Derrick's call)

Derrick declined a refund and instead ruled the bet had been recorded on the wrong side.
Switched it to Gabriel Tamayo, which is the side that won, so it settles as a win.

| Field | Before | After |
|-------|--------|-------|
| side | `b` (Nelson Santos) | `a` (Gabriel Tamayo) |
| status | lost | won |
| payout | 0 | 1495 (712 × 2.1, same rounding as auto_settle) |
| Javier's coins | 742 | 2247 |

Applied in a single `DO` block that re-reads the row `for update` and aborts unless it is
still `side=b / status=lost / amount=712`, so a re-run cannot double-credit. Wallet moved
via `credit_wallet()` — the same path auto-settlement uses — rather than a raw coins update.

Balance is 2247, not the predicted 2237: a $165 sale of his was approved at 20:12 UTC
mid-operation, which awards +10 Mike Coins. Independently confirms the approval → coins
path is live after the row-cap fix.

Note for the record: the evidence still says the bet was *recorded* as placed — the line was
auto-generated (title order matches agent_a/agent_b) and the confirm modal spells the side
out in words. This was an operator judgement call in the agent's favour, not a proven
system error. The genuine defect was that bet history displayed a bare `Side: B`, which is
what made the claim impossible to disprove; that is now fixed.

### Blockers / Follow-ups:
- [ ] Browser smoke test still not run — Playwright MCP was locked by another session for
      the whole run. Every check above is API-level or headless; no human or browser has
      actually looked at the rendered board or the new bet-history rows.
- [ ] `get_public_commission_feed` now has no client callers at all. Left in place as a
      public RPC; consider retiring it.
- [ ] Supabase MCP is still unauthenticated. Not blocking — the CLI covers it — but MCP
      tooling stays unavailable until `/mcp` is re-run against the FHE org.

## Fix + Verify — 2026-07-31 (sportsbook payouts not landing)

### Feature Under Test: Daily sportsbook auto-settlement + backfill of unpaid bets
### Result: PASS

**Root cause:** the daily switch (2026-07-23) auto-generated + locked matchups but never
settled them — settlement was manual and no manager ever did it. Result: 13 bets sat
`pending` (coins debited at bet time, never resolved) across Jul 24-30; winners unpaid.

**Fix:** added `auto_settle_daily_matchups()` (+ `admin_` wrapper) + `pg_cron` job
`auto-settle-matchups` (`30 11 * * 1-5`, runs before the 8 AM generation). Winner =
higher approved commission on the matchup day (same metric as the board's Today view).
Tie => refund + cancel. Idempotent / self-healing. Ran it once to backfill.

| Check | Result | Notes |
|-------|--------|-------|
| Backfill run | PASS | `auto_settle_daily_matchups()` returned 19 lines settled (12 with bets + 7 stale bet-less) |
| Bets resolved | PASS | 13 pending → 14 won / 3 lost; 0 pending remain |
| Payouts credited | PASS | Albert 1035→1309 (+274), Arturo 520→578 (+58), Javier 435→1344 (+909), Nelson 440→470 (+30) = 1,271 coins, matches predicted |
| Open h2h lines | PASS | 0 remaining (all resolved) |
| Winner logic | PASS | Every stuck line had a clear commission winner; matched hand-computed table |
| cron registered | PASS | `auto-settle-matchups` active, ordered before `daily-matchups` (12/13 UTC) |

### Notes:
- Server-side only (DB functions + cron). No `index.html` / client change; the app already
  renders settled/won states, so no Vercel deploy or APP_VERSION bump needed.
- Migration recorded at supabase/migrations/20260731130000_sportsbook_auto_settle_daily_matchups.sql.
- Managers retain the manual settle buttons as an override if a commission correction changes a winner.

## Smoke — 2026-07-03 17:24

### URL: https://fhe-scoreboard.vercel.app
### Surface: headless
### Overall: PASS

| Check | Result | Details |
|-------|--------|---------|
| Route: / | PASS | 0 console errors, 0 failed requests |

### Notes:
- Ran ad hoc (no smoke.config.json existed for this project — a minimal one was created covering the single static route `/`, since this app has no server-side routing).
- Verified against production after the recent Vercel git-integration fix + PR #3 merge: leaderboard rendered correctly with live data (16 agents) via the security-hardened RPCs, nav (Scoreboard / Agent Portal / Sportsbook / Admin) present, no errors.
- Login/admin/sportsbook flows were not exercised (would require real credentials) — visual/route check only.

## Smoke — 2026-07-03 (login flows)

### URL: https://fhe-scoreboard.vercel.app
### Surface: headless (custom script — see below)
### Overall: PASS

| Check | Result | Details |
|-------|--------|---------|
| Flow: loginAgent (Daniel Ramirez) | PASS | 0 console errors, 0 failed requests, portal rendered ("Welcome, Daniel Ramirez") |
| Flow: loginAdmin (admin) | PASS | 0 console errors, 0 failed requests, panel rendered ("Welcome, Admin! You have full admin access.") |

### Notes:
- Added `flows.loginAgent` / `flows.loginAdmin` to `smoke.config.json` (proper /smoke skill flow format, forward-compatible with the Chrome-MCP interactive path).
- The shared /smoke skill's headless runner can't execute these: it hands off from a login context to a fresh route-check context via Playwright's `storageState()`, which does not capture `sessionStorage` — and this app stores its session in `sessionStorage`, not cookies/localStorage. A fresh context would just see the login screen again.
- Added `scripts/smoke-login-check.mjs` (project-local) to run a named flow start-to-finish in one persistent page/context instead, so the app's real session state survives through the final screenshot. Reuses the Playwright install already bundled with the `/smoke` skill rather than adding a dependency to this static-HTML repo.
- Credentials are passed as env vars only (`SMOKE_AGENT_NAME`/`SMOKE_AGENT_PIN`, `SMOKE_ADMIN_USER`/`SMOKE_ADMIN_PASS`) — never written to `smoke.config.json` or committed anywhere.
- Confirmed via code read (`agentLogin()`/`adminLogin()`) that both call read-only `verify_*_login` RPCs — no lockout counters, no shared/global session state — so this check is safe to run anytime without affecting real users.
- Usage: `SMOKE_AGENT_NAME="..." SMOKE_AGENT_PIN="..." node scripts/smoke-login-check.mjs loginAgent` (swap for `SMOKE_ADMIN_USER`/`SMOKE_ADMIN_PASS` + `loginAdmin`).

## Smoke — 2026-07-03 (re-run after PR #4 merge)

### URL: https://fhe-scoreboard.vercel.app
### Surface: headless
### Overall: PASS

| Check | Result | Details |
|-------|--------|---------|
| Route: / | PASS | 0 console errors, 0 failed requests |
| Flow: loginAgent (Daniel Ramirez) | PASS | 0 console errors, 0 failed requests |
| Flow: loginAdmin (admin) | PASS | 0 console errors, 0 failed requests |

### Notes:
- Full re-run of both the route check and the two login flows against production after merging PR #4 to main — everything still green, no regressions from the merge.

## Smoke — 2026-07-22 18:13

### URL: https://fhe-scoreboard.vercel.app/
### Surface: headless (Playwright MCP)
### Feature Under Test: Month to date board period
### Overall: PASS

| Check | Result | Details |
|-------|--------|---------|
| Deploy landed | PASS | live APP_VERSION = 2026-07-22-month-to-date-001 |
| Route: / | PASS | only console error = favicon.ico 404 (pre-existing, benign) |
| 4 period pills render | PASS | Today / Week to date / Month to date / All time, in order |
| Click Month to date | PASS | #pb-month activates; TV pill → "Month to date" |
| Stat tiles relabel | PASS | "This month total $77,105", "This month sales 545", 17 agents |
| Subtitle follows period | PASS | agent rows show "Month to date: $X (N sales)" |

### Notes:
- Bonus: daily motivation quote now visible in banner (stale admin announcement was cleared).
- Screenshot: ../smoke-scoreboard-month-prod-2026-07-22.png

## Smoke — 2026-07-22 18:24

### URL: https://fhe-scoreboard.vercel.app/
### Surface: headless (Playwright MCP)
### Feature Under Test: Sportsbook monthly bet-line option
### Overall: PASS

| Check | Result | Details |
|-------|--------|---------|
| Deploy landed | PASS | live APP_VERSION = 2026-07-22-sportsbook-month-line-001 |
| Route: / | PASS | only console error = favicon.ico 404 (pre-existing, benign) |
| #sbl-period options | PASS | week / month / today render in order on prod |

### Notes:
- Settle-label map verified locally (month→"month-to-date", unknown→"week-to-date" fallback); same
  deployed bundle confirmed via version match. No prod bet line created (schema is unconstrained text).

## Smoke — 2026-07-23 18:49

### URL: https://fhe-scoreboard.vercel.app/#sportsbook
### Surface: headless (Playwright MCP) + SQL (Supabase MCP)
### Feature Under Test: Daily sportsbook matchups + 10:20 AM ET betting lock
### Overall: PASS

| Check | Result | Details |
|-------|--------|---------|
| Deploy landed | PASS | live APP_VERSION = 2026-07-23-sportsbook-daily-lock-001 |
| Generation logic | PASS | generate_daily_matchups(true) created 9 h2h lines; odds/shortnames match JS port (e.g. Albert 14640 vs Owen 10125 -> 1.7/2.4; two Gabriels -> "Gabriel H."/"Gabriel T."; 0/0 -> 2.0/2.0) |
| closes_at timezone | PASS | closes_at rendered exactly 2026-07-23 10:20 America/New_York (DST-aware) |
| Server lock ordering | PASS | place_bet on past-deadline line -> "line closed"; future-deadline line -> reaches "invalid side" (lock passed, no coins moved) |
| closes_at exposed | PASS | column present on bet_lines; get_open_lines/get_all_lines_admin use SELECT * |
| Open-line UI (prod) | PASS | OPEN -> "Book closes 10:20 AM ET" + bet buttons; CLOSED -> "Betting closed at 10:20 AM ET" + locked message, buttons hidden |
| Route: /#sportsbook | PASS | only console error = favicon.ico 404 (pre-existing, benign) |
| pg_cron scheduled | PASS | job 'daily-matchups' active, schedule '0 12,13 * * 1-5' |
| Weekly cleanup | PASS | 14 open weekly lines cancelled, 13 pending bets refunded; 0 open lines remain |

### Notes:
- 10:20 lock enforced server-side in place_bet (closes_at check) so it can't be bypassed client-side.
- cron fires 12:00 & 13:00 UTC Mon-Fri; function no-ops unless it's the 8 AM NY hour -> exactly one 8 AM run under both EDT and EST.
- UI states verified with mock data via loadOpenLines (no prod bet lines created). Screenshot: ../smoke-scoreboard-daily-lock-2026-07-23.png
- First real auto-generated board arrives Fri 2026-07-24 at 8:00 AM ET.

## Security hardening — 2026-08-01

### Feature Under Test: session-token auth, hashed agent PINs, brute-force lockout
### Result: PASS

| Test | Result | Notes |
|------|--------|-------|
| Admin login (Derrick / correct PIN) | PASS | returns 64-char token; sessionStorage holds `{token}` only, no password |
| `get_agents_admin` with TOKEN | PASS | returns roster, `has_pin` boolean, no plaintext PIN |
| `get_agents_admin` with RAW PASSWORD | PASS | rejected — the pre-fix brute-force pivot is closed |
| `admin_approve_commission` with TOKEN | PASS | authorizes (bogus id no-ops, no auth error) |
| `admin_approve_commission` with RAW PASSWORD | PASS | rejected |
| Cross-account token misuse | PASS | Derrick's token sent as `jordankyles` → rejected |
| Brute force: 10 bad logins on a dummy identity | PASS | counter caps at 8, 15-min lock set, tries 9–10 short-circuit |
| Lockout indistinguishable from bad PIN | PASS | both return `[]` — no lock-vs-badpin oracle |
| Agent login (Aaron Matthews / sheet PIN) | PASS | works against bcrypt `pin_hash`; hashing lost nothing |
| Admin → Agents tab | PASS | PINs render as `••••`, Reset PIN button present, no plaintext |
| Reload persistence | PASS | restores via `sb_session_whoami`, never replays the secret |
| Sign-out revokes token server-side | PASS | *after* a fix — see below |
| Console errors | PASS | 0 (bar a pre-existing favicon 404) |

### Bug found and fixed during verification:
- `agentLogout`/`adminLogout` read the token from in-memory state and fired the revoke
  without awaiting. Verified against prod that a sign-out left the token **live for 12h** —
  "signed out" only meant the browser forgot it. Fixed to read from sessionStorage and
  await the revoke; re-verified `sb_session_whoami` returns empty after sign-out.

### Known gaps / follow-ups:
- [ ] `list_admin_names()` is anon-callable and enumerates admin usernames. Low value to
      hide (names are on a wall-mounted board) but it is what makes targeted guessing easy.
- [ ] Pin-only / shared-password RPCs in the *other* FHE apps remain unguarded — see the
      Phase 4 login-unification work.

## Black-box security audit — 2026-08-01 (post org-transfer)

Supabase MCP access was lost when the project moved to the FHE org, so `get_advisors`
could not run. Verified externally instead, using the anon key published in this public
repo — i.e. from the attacker's actual position. Arguably a stronger check than the
linter for the auth changes.

| Lint / attack | Result |
|---|---|
| anon direct read of any table (9 tables incl. new `auth_sessions`, `login_attempts`) | PASS — all 42501 insufficient_privilege |
| internal SECURITY DEFINER helpers callable by anon (5 fns) | PASS — all revoked; Postgres' default grant to PUBLIC was correctly stripped |
| intentionally-public RPCs still reachable (4 fns) | PASS |
| agent token used on an admin endpoint | PASS — rejected |
| agent token used as a `manager` bettor | PASS — false |
| agent A's token reading agent B's commissions (horizontal escalation) | PASS — rejected |
| null token as a bypass | PASS — false, not NULL; confirms the `coalesce(...,false)` in `verify_bettor` is load-bearing |
| cross-account token misuse (Derrick's token sent as `jordankyles`) | PASS — rejected |

### Not externally verifiable — outstanding:
- `function_search_path_mutable`: every function in these migrations sets an explicit
  `search_path`, confirmed in the applied migration text, but not independently linted.
- Performance advisors (indexes etc.) — not security, not urgent.
- Re-run `get_advisors` once the Supabase MCP grant is re-authorized against the FHE org.

## Session — 2026-08-25

### Feature Under Test: deferred sportsbook lines explain themselves + settle on approval
### Result: PASS

**The incident.** The Aug-24 line "Gabriel T. vs Bryan" sat `open` while all seven other
Aug-24 lines settled at 07:30 ET. Gabriel Tamayo had 794 coins on himself and won the day
745 vs 555, but his bet showed a bare PENDING badge — no reason, no payout.

Cause: the pending-sales guard from `20260817150000` is correct, but it was a bare
`continue`. Nothing was written to the line, nobody was told, and the only retry was the
next cron tick (up to 9h later). It was also close to undiagnosable after the fact —
approval stamps `approved_at = created_at`, so the sale that was pending at 07:30 now
looks like it was approved on Aug 24 with the other six.

| Test | Result | Notes |
|---|---|---|
| Dry-run: scope of a settler pass over the last 3 days | PASS | Exactly 1 line would change; phase 2 would correct nothing else |
| Rewrite of `auto_settle_daily_matchups` is drift-free | PASS | Diffed new body vs live `prosrc` — only the 11 added lines differ |
| Migration applies | PASS | All 4 functions replaced; ACLs verified post-`drop`/`create` |
| `get_my_bets` keeps anon/authenticated EXECUTE after drop+create | PASS | Re-granted explicitly; verified in `proacl` |
| `auto_settle_daily_matchups` still NOT anon-reachable | PASS | `postgres=X \| service_role=X` only |
| Tamayo paid out | PASS | Bet `won`, payout 1,588, wallet 3,500 → 5,088 |
| Payout carries an audit reason | PASS | `coin_ledger` row has reason + actor (was null on every historical row) |
| Defer branch writes a reason | PASS | "Awaiting sale approvals: 1 sale still pending for Aug 24 — settles as soon as they are approved"; line stayed `open`, bet stayed `pending` |
| Approving the last pending sale settles immediately | PASS | open → `settled` in the same call; totals 995 vs 555; bet `won`, payout 200 |
| Test harness left no residue | PASS | 0 test lines, 0 test sessions, wallet unchanged at 5,088 |

Both behavioural tests ran as atomic `DO` blocks ending in a deliberate `raise`, so the
test line, the throwaway admin session and the coin movements all rolled back together.
Verified afterwards that nothing persisted.

**Also closed:** commission approvals now set `app.coin_reason` / `app.coin_actor`, so the
+10 award stops landing in `coin_ledger` with a null reason — an open item since
`20260805210000`.

### Blockers / follow-ups:
- [ ] **Not verified in a browser.** The two UI changes (reason under a pending bet; admin
      line card showing the note for `open` lines) are untested visually. Reproducing a
      deferred line in the UI needs a real pending sale on a past day.
- [ ] No alert when a line defers. The Slack webhook exists but rides the canary workflow,
      which still cannot be pushed (gh token lacks `workflow` scope).
- [ ] Deferral is still capped at 2 days, after which a line settles on whatever is
      approved. That is deliberate, but it is now silent in a second way: the note says
      "settles as soon as they are approved" without mentioning the backstop.

### Follow-up same session: internal-helper revokes + canary scheduled
| Test | Result | Notes |
|---|---|---|
| Anon-reachable surface audited (43 SECURITY DEFINER fns) | PASS | Only `log_coin_change` + `assert_admin` violated the convention; the rest are credential-taking or intentionally-public reads |
| `credit_wallet` still revoked (2026-08-17 hole) | PASS | `postgres \| service_role` only |
| `verify_bettor` is not a PIN brute-force oracle | PASS | Resolves 256-bit session tokens via `sb_resolve_session`, not PINs |
| Revoke `assert_admin` / `log_coin_change` from public+anon+authenticated | PASS | Both now `postgres \| service_role` only |
| Regression after revoke: approval + coin trigger | PASS | Commission approved, coins 5,088 → 5,098, ledger row written with the new `commission approved (+10)` reason |
| Canary runs locally | PASS | 8 endpoints, both invariants hold (1,506 rows, $218,990) |
| Canary runs in GitHub Actions | PASS | Run 32862308653, success in 18s — first time this has ever executed in CI |
| PostgREST `max_rows` | **STILL 1000** | Every caller aggregates server-side now and the canary watches, but the cap is still armed for the next query anyone writes |

### Follow-up: migration bookkeeping + row-cap is org-wide
| Check | Result | Notes |
|---|---|---|
| Local migrations declared in `schema_migrations` | **WAS 0 of 14** | Every file in `supabase/migrations/` read as un-applied |
| What `supabase db push` would have done | **FAILED mid-run** | Replayed all 14; hard error on `create trigger trg_log_coin_change` (20260805210000, unguarded). Most other non-idempotent lines are `update`s *inside* function bodies — harmless on replay |
| After backfill | PASS | `supabase migration list --linked` shows all 14 local↔remote paired, nothing pending |
| PostgREST `max_rows` across all FHE Supabase projects | **1000 everywhere** | goal-leaderboard, streamline, fhe-wiki, FHE-MRKT, echo-orchestrator, twin-state, n8n, openbrain-course and both `FHE` projects. The trap that broke this board on Aug 5 is armed in all of them |

**Workflow gotcha, now recorded:** this repo applies migrations with
`supabase db query --linked -f <file>`, which does NOT write to
`supabase_migrations.schema_migrations`. The 25 pre-existing rows were dashboard changes
ending 2026-08-01. If you keep using `db query -f`, the history table needs backfilling or
`db push` becomes a landmine. Only the scoreboard was checked — the sibling repos likely
have the same drift.

### Follow-up: queue worked through
| Item | Result | Notes |
|---|---|---|
| Backfill shared-DB migration history (53 versions) | DONE | 65 → 118 rows; all 54 files across the 4 repos now declared, 0 pending. `db push` is no longer a landmine |
| Raise `max_rows` to 5000 | **BLOCKED** | Management API returns "account does not have the necessary privileges" on both FHE projects — member, not admin, since the org migration. Needs an org owner (or the dashboard, if that role allows it) |
| Canary: alert on stuck / held lines | DONE | `get_open_lines` is `SETOF bet_lines` so it already carries `settlement_note` — no new RPC. Held → Slack warning, exit 0. Silent → hard failure, exit 1 |
| Canary new check catches both branches | PASS | Verified by stubbing only the data source and keeping the real logic. The silent case is the Tamayo bug exactly — it would have fired at 09:00 ET |
| Production loads clean after deploy | PASS | Only the known `favicon.ico` 404; no new console errors. Sportsbook tab renders |
| All three UI edits shipped and parse | PASS | `APP_VERSION=2026-08-25-deferred-line-reason-001`; `loadMyBets`/`betLineLabel` defined (so the script parsed past every edit); `heldNote`, `b.line_note`, `b.line_status` present; admin note un-gated and the old `isClosed`-gated form gone |

**Still not visually confirmed:** the deferred-note row itself. No line is currently deferred
(zero past-day open lines), and the sportsbook requires sign-in, so there is nothing to
photograph. It will render naturally the first morning a sale is still pending at 07:30 ET —
and the canary now announces exactly that in Slack, which is the more useful signal anyway.

---

## Session 2026-08-25 (evening) — Lunch punch in the scoreboard nav

### Feature Under Test: cross-project lunch button (`#tn-lunch`, next to Sportsbook)
### Result: PASS

The punch targets a **different Supabase project** (`eawpwwctsifzcclrwvww`, the shared FHE
database) than the scoreboard's own (`sralgaskfktcynpdxjhj`). No migrations were written —
`tct_lunch_punch(uuid,text,text)` and `tct_contractor_lunch_today(uuid,text,text)` were
already granted to `anon`. What they needed was a *time-clock* session token, so the agent
login now performs a second, invisible login against the time clock while the PIN is in hand.

Verified with a disposable `Zzz Smoke Test` contractor (created, exercised, deleted
child-rows-first; `auth_sessions` row revoked). All leftovers confirmed 0.

| Test | Result | Notes |
|---|---|---|
| `tct_*` reachable with the anon key from a foreign origin | PASS | CORS preflight from `https://fhe-scoreboard.vercel.app` returns 200 |
| Guard rejects a bogus token | PASS | `42501 not authorised` |
| Guard rejects *someone else's* contractor id with a valid token | PASS | `42501` — `tct_actor_is_self_or_admin` holds across projects |
| `tct_contractor_login_token` over anon REST | PASS | Returns `{id, team, contractor_name, token}`, token 64 hex |
| Punch 1 → start | PASS | `{"action":"started","minutes_allowed":60}` |
| Punch 2 → close and score | PASS | `{"action":"ended","minutes_over":0,"points_assessed":0}` |
| Punch 3 → refused | PASS | `{"lunch_already_taken":true}` |
| Exempt agent (`clock_in_exempt=true`) | PASS | `lunch_today` returns `exempt:true`; renders dimmed `🍔 Lunch · Not Required` (was: hidden — changed, see below) |
| Exempt button is genuinely inert | PASS | Clicking fires no confirm, no RPC, no alert; label unchanged |
| Non-exempt path after the exempt change | PASS | Flipped the flag back and re-ran all three states — `lunch-exempt` class gone, countdown works |
| Button hidden when logged out | PASS | `display:none` until both a scoreboard *and* a time-clock session exist |
| Nav order | PASS | scoreboard → agent → **lunch** → sportsbook…, `tn-lunch` sits directly after `tn-sportsbook` |
| Three label states, in a real browser | PASS | `🍔 Lunch` → `🍔 Back from Lunch · 47m left` (amber) → `🍔 Lunch Taken` (dimmed) |
| Countdown flips to over-time | PASS | Past the allowance the button reads `· 12m OVER` and turns red (`.lunch-over`); reverts correctly when the clock is restored |
| Due-back time shown before and after starting | PASS | Confirm says "due back by 7:52 PM"; the receipt repeats it. Tooltip carries start + due-back at all times |
| Dead time-clock token degrades safely | PASS | On `42501` the bridge session is dropped and the button hides; **the scoreboard agent stays logged in** |
| Page loads clean | PASS | Only the known `favicon.ico` 404 — no new console errors |

### Blockers / Follow-ups:
- [ ] Not yet exercised by a **real** agent through the actual login form — that needs a live
      PIN. Watch the first agent who signs in and confirm the button appears for them.
- [ ] The second login feeds the time clock's brute-force counter. It is capped at **one
      attempt per tab** (`fhe-scoreboard-tct-skip`), so a PIN that diverges between the two
      apps costs one failure, not eight. If PINs are ever rotated in one app only, this is
      the thing that breaks — and it breaks quietly, as a missing button.
- [x] Exempt staff on the scoreboard today: **Mark Caraher** only. Originally the button was
      hidden for him, which reads as a broken feature rather than an intentional one. Now shows
      a dimmed, inert `🍔 Lunch · Not Required`. Note this differs from having no time-clock
      session at all, which still hides the control — there is nothing true to say in that case.
- [x] Verified by a real login through the PRODUCTION form (disposable agent created in BOTH
      databases with the same PIN, driven through `agentLogin()`, both deleted after). One PIN,
      two logins, 64-char time-clock token minted, button rendered. This closes the "not yet
      exercised by a real agent" follow-up.

---

## Session 2026-08-26 — "Currently On Lunch" in the scoreboard admin panel

### Feature Under Test: `#admin-lunch-card`, fed by `tct_admin_open_lunches` across projects
### Result: PASS

Same cross-project bridge as the agent lunch button, but for an admin read. The scoreboard
password is replayed once against the time clock's login RPC at sign-in; one attempt per tab
(`fhe-scoreboard-tct-admin-skip`), because the time clock throttles logins and a retry loop
could lock a manager out of the real clock.

Verified with a disposable time-clock admin (`Zzz Smoke Admin`, is_admin) plus an agent
backdated 71 minutes into a lunch. Both removed afterward, child-rows-first.

| Test | Result | Notes |
|---|---|---|
| Bridge mints a time-clock admin token | PASS | 64-hex from `tct_contractor_login_token` |
| Populated card | PASS | "ZZZ SMOKE ONLUNCH · Derrick Team · started 8:58 AM · **71 min** / over 60", red |
| Empty state | PASS | "Nobody is on lunch right now." — card still rendered, not hidden |
| No bridge (not a time-clock admin, or divergent credentials) | PASS | Explains itself + links to Time Clock → Admin. Never blank |
| Dead time-clock token | PASS | Falls back to the no-bridge message; **scoreboard admin stays signed in** |
| Recovery after the token returns | PASS | Card repopulates without a reload |
| Panel cannot delay the admin load | PASS | `loadAdminLunch()` is fired, not awaited, inside `loadAdmin()` |
| Production after deploy | PASS | `APP_VERSION=2026-08-26-admin-lunch-panel-001`, card + all four bridge fns present, no console errors |

### Credential-parity audit (2026-08-26) — both unknowns now CLOSED
Every person's PIN from the master sheet was replayed against **both** apps' login RPCs, and for
admins the resulting time-clock token was pushed through `tct_admin_open_lunches` to prove it
passes `tct_actor_is_admin`. All 49 sessions minted by the audit were revoked. No PIN was written
to disk or to any commit.

**Agents — 17 of 17 non-exempt will see the lunch button. Zero broken.**
PINs are identical across both apps for every agent on the scoreboard. Mark Caraher is exempt
(n/a by design).

**Admins — 5 of 7 get the live card**, exactly as predicted:

| Admin | Scoreboard | Time clock | Admin guard | Card shows |
|---|---|---|---|---|
| Derrick Rodriguez | ok | ok | ok | lunches |
| Jordan Kyles | ok | ok | ok | lunches |
| Joshua Diaz | ok | ok | ok | lunches |
| Michael Sanguily | ok | ok | ok | lunches |
| Yamill Julian | ok | ok | ok | lunches |
| Mark Caraher | ok | ok | **FAIL** | link to Time Clock — signs in, but is not a time-clock admin |
| Michael Bregio | ok | **FAIL** | FAIL | link to Time Clock — no time-clock account at all |

### Blockers / Follow-ups:
- [x] ~~Unknown whether scoreboard passwords match time-clock PINs~~ — audited, they all match.
- [x] ~~Mark Caraher / Michael Bregio get the link version~~ — confirmed empirically, not assumed.
- [ ] Still nobody has punched a lunch in production. Every piece is verified, but only with
      disposable data plus this credential audit. The first real lunch remains the live test.
- [ ] Parity is a snapshot, not a guarantee. Rotating a PIN in one app and not the other silently
      removes that person's lunch button — see [[project_pin_rotation_handoff_gap]] for the last
      time a one-sided rotation caused exactly this class of problem.

---

## Session 2026-08-27 — Update-check efficiency + overlay false positives

### Feature Under Test: `checkForUpdate` (Range fetch, two-strike, debounce)
### Result: PASS — measured in production

The poll re-downloaded the whole 143KB page every 20s per tab, plus on every focus and
visibilitychange, purely to read one version string. `APP_VERSION` moved to `<head>` (byte 472),
so the check Range-fetches 2KB. Measured against production:

| | Before | After |
|---|---|---|
| Per poll | 142,973 bytes | **2,048 bytes (1.4%)** |
| Per tab per hour | 25 MB | 0.35 MB |
| 20 tabs × 8h day | **3.83 GB** | **56 MB** |

| Test | Result | Notes |
|---|---|---|
| Range header sent (production) | PASS | `bytes=0-2047`; marker readable inside it |
| Fallback when Range is ignored | PASS | Verified against Python's `http.server`, which returns 200 + full body — regex still matches |
| Same version → silent | PASS | No overlay, `pendingRemoteVersion` null |
| New version, first sighting → silent | PASS | Records the candidate, shows nothing — a stale edge must not nag |
| Sighting flaps back to current → strike resets | PASS | `pendingRemoteVersion` cleared |
| Two agreeing sightings → overlay | PASS | Real deploy still prompts |
| focus + visibilitychange double-fire | PASS | Collapsed to one request per 5s; 0 extra fetches |
| Exactly one `APP_VERSION` declaration | PASS | Two `const`s in one scope is a SyntaxError that would blank the app |
| Board / lunch button / admin card intact | PASS | Verified in production after deploy |

### Why the overlay had been appearing repeatedly
Not a caching bug — **`APP_VERSION` was bumped 5 times in ~24h** (4 on 8/25, 1 on 8/26), and each
deploy interrupts every open tab within 20s. That was avoidable: the label change, the countdown
and the exempt state should have been one deploy, not three. Related changes are batched from here.

The two-strike rule addresses the separate, narrower case: during deploy propagation Vercel's
edges briefly disagree (observed 8/26 — back-to-back fetches of the same URL returned different
content), so a tab already on the new build could be told to refresh again.

### Blockers / Follow-ups:
- [x] ~~Admin pending-count refetches all commissions every 60s~~ — fixed in `4e49ad5`, below.

---

## Session 2026-08-27 — Pending badge counts in Postgres

### Feature Under Test: `get_pending_count_admin(text, text)` + the 60s badge poll
### Result: PASS — measured in production

The badge polled `get_all_commissions_admin` once a minute (SETOF commissions, every row and
column, paged by `rpcAll`) and counted `status='pending'` in JavaScript. The answer is one integer.

| | Before | After |
|---|---|---|
| Per poll | 273,926 bytes | **1 byte** |
| Per admin tab, 8h | 125.4 MB | **0.5 KB** |

| Test | Result | Notes |
|---|---|---|
| Wrong credential refused | PASS | `P0001 invalid admin credentials` via `assert_admin` |
| No unguarded variant | PASS | 0-arg call → `PGRST202`, not found |
| Count matches the old client-side filter | PASS | Both 0 |
| Badge hides at 0, shows at non-zero | PASS | Exercised both against the live DB |
| Failed call leaves the badge alone | PASS | Pointed the call at bad credentials; the existing value survived rather than flashing a wrong 0 |
| `loadAdmin()` still gets full rows | PASS | It needs them for the today/week/total money stats — only the poll was changed |
| Production after deploy | PASS | `pending-count-rpc-001`, no console errors |

Test admin sessions from this audit were revoked (`sb_end_session`).

### Blockers / Follow-ups:
- [ ] Nothing outstanding on efficiency. The two polls that dominated idle traffic (update check,
      pending badge) both now cost effectively nothing. `loadBoard` every 30s on the TV is the
      remaining periodic cost and it is doing real work — it renders the board.

## Session 2026-08-28 — anon could mint betting lines; daily guard audit added

### Result: PASS — hole closed, audit live

| Test | Result | Notes |
|------|--------|-------|
| Static guard check (catalog only) | **1 real finding** | `generate_daily_matchups(p_force boolean)` anon-callable: VOLATILE, inserts into `bet_lines`, and `p_force := true` bypasses BOTH its weekend and 8-AM-ET guards |
| Root cause | **CONFIRMED at ACL level** | `20260723190000:109` revokes from `anon, authenticated` but not `public`. Live ACL was `=X/postgres \| postgres=X \| service_role=X` — explicit anon grant gone, **PUBLIC left**, and anon inherits PUBLIC. Open since 2026-07-23; never a regression |
| `auto_settle_daily_matchups()` — same omission | **already closed** | Live ACL `postgres=X \| service_role=X`, anon false. I flagged it as likely open and was **wrong**; checked instead of assuming. Re-asserted anyway |
| What actually drives generation | **pg_cron job 1, as `postgres`** | `select public.generate_daily_matchups();` on `0 12,13 * * 1-5` (8 AM ET, doubled for DST). Corroborated by `bet_lines`: exactly 9 lines at 08:00 ET every weekday, never a weekend, 20+ days straight |
| Only client call site | admin wrapper | `index.html:1606` calls `admin_generate_daily_matchups(p_username, p_password)`, which asserts admin then calls the raw fn from SECURITY DEFINER |
| Apply revoke + verify | PASS | ACL now `postgres=X \| service_role=X`; `anon_can_generate` false |
| **Cron path still works after the revoke** | PASS | Called as `postgres` at 09:00 ET: returned 0 and inserted nothing, correctly stopped by its own hour guard. Proves executability without creating lines |
| Guard audit dry run | PASS | 57 functions, 0 findings, `invoker_open` = `odds_for_pair/2` (pure odds maths) |
| **Slack alert path**, forced findings in `begin; … rollback;` | PASS | enqueued to `net.http_request_queue`, URL is a Slack webhook, `Content-Type: application/json` with no charset, body well-formed — then rolled back, nothing sent |
| Schedule + webhook | PASS | `cron.job`: `guard-audit-daily @ 0 12 * * * as postgres`; webhook set (copied in-process, never printed or written to a file) |

### Why in-database rather than the hub's Vercel cron
This project has pg_cron 1.6.4 with jobs running as `postgres`, so the audit runs on a schedule with
**no credential stored anywhere**. The alternative was putting this project's service_role key — which
bypasses RLS on the money database — into the command-center's Vercel environment.

### Still open
- [ ] **33 credential-taking anon-executable functions here are behaviourally unverified.** The
      audit is static (who may execute what). Probing guards by calling them with a wrong credential
      means invoking betting/coin-ledger RPCs blind, and a settled line can never be re-settled — so
      that needs a human driving it deliberately, once.
- [ ] **Judgement call, not a bug:** `get_commission_stats`, `get_public_commission_feed` and
      `scoreboard_month_commission` expose company commission figures to anyone holding the
      publishable key in `index.html`. Allowlisted so the audit stays worth reading;
      fhe-command-center's `/dashboard` depends on the last one being anon-callable. If that exposure
      is unwanted the fix is a guarded overload plus a service-role read from the hub.
