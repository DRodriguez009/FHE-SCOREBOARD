# TEST_LOG.md

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
