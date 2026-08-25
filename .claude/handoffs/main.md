# Session Handoff — main
Generated: 2026-08-25 16:05
Worktree: /Users/derrickrodriguez/Projects/fhe-scoreboard

## What We Were Working On
Reported bug: "the bets were not paid out to Tamayo — he won the matchup for Bryan." The
Aug-24 line was never settled, not mis-paid. Fixed the payout, then fixed the cause: the
auto-settler's pending-sales guard deferred the line with a bare `continue`, telling nobody.
The session then widened into the migration-history drift and row-cap exposure across every
FHE project.

## Remaining Work
No TASKS.md in this repo — these come from TEST_LOG.md follow-ups.

- **BLOCKED, needs an org owner: raise `max_rows` from 1000.** The Management API refuses
  with "account does not have the necessary privileges" on BOTH FHE projects — Derrick is a
  member, not an admin, since the org migration. Every caller aggregates server-side and the
  scoreboard has a canary, but the cap is still armed on all ~12 projects. Nothing is
  currently truncating (verified). Note this role limit blocks any project-config change.
- **Needs a human call:** `fhe-coachings-tracker/supabase/migrations/` has TWO files on
  version `20260706170000` — `init_coaching_schema.sql` and `init_coaching_schema.local.sql`
  — both creating the same tables and inserting the same managers. Duplicate version
  prefixes break `supabase db push` on their own. The `.local` variant looks like a dev copy
  that shouldn't be there, but deleting a migration wasn't mine to do. The shared-DB backfill
  inserted 53 rows for 54 files because of this.
- **The deferred-note UI row has never rendered.** Needs an agent login AND a live deferred
  line; neither existed. It'll appear naturally the first morning a sale is pending at
  07:30 ET. The canary now posts it to Slack at 09:00, which is the better signal anyway.
- Re-auth the **Supabase MCP** (`/mcp` → supabase → FHE org `ieuivsdynmfdncskrtdo`) so
  `get_advisors` can run. Not blocking — the CLI and Management API both work.
- Optional: rotate the scoreboard's `jwt_secret`. Reading `/v1/projects/<ref>/postgrest` to
  check `max_rows` returns it in the response, so it's in this session's transcript on disk.
- **Sibling repos have no truncation canary.** Only fhe-scoreboard does. `scripts/canary.mjs`
  reads its Supabase URL and anon key out of `index.html`, so porting it to command-center or
  goal-leaderboard is mostly a config change.
- Known/accepted, unchanged: `list_admin_names()` is anon-callable (names are on a wall
  board); `favicon.ico` 404s.
- Cosmetic: the defer note says "settles as soon as they are approved" without mentioning the
  2-day backstop, after which a line settles on whatever is approved.

## Key Decisions This Session
- **Fix the cause, not just the symptom.** Notes + UI + Slack only make the wait legible;
  calling the settler from both approval RPCs is what stops the recurrence. Shipped both.
- **Ran the settler, not `admin_resettle_bet_line`.** The line was `open`, not mis-settled —
  and the resettler stamps `[manual]`, permanently exempting a line from auto-correction.
- **Test destructive DB changes with an atomic `DO` block ending in a deliberate `raise`.**
  No staging copy exists. Everything rolls back — inserts, coin movements, even a throwaway
  `sb_issue_session` token — while results still return in the error payload. Reusable.
- **Verified object existence before declaring 54 migrations applied.** Falsely marking one
  applied would hide a real gap. Parsed every `create function|table|trigger` and checked the
  catalogs: zero missing.
- **Return shape decides row-cap exposure, not table size.** `carrier_agent_states` is at 974
  but reached via `carrier_detail`, which returns jsonb — a single row the cap can't truncate.

## Kickstart Prompt
> fhe-scoreboard, 2026-08-25. The "bets not paid out to Tamayo" bug is fixed and shipped:
> the Aug-24 line `de9f3fc8` was never settled because the auto-settler's pending-sales
> guard deferred it with a bare `continue` that told nobody. Tamayo was paid 1,588 (wallet
> 3,500 → 5,088). `main` is clean at `ac0ddd2`, live APP_VERSION
> `2026-08-25-deferred-line-reason-001`, canary green in CI.
>
> **The diagnostic trap to remember:** approval stamps `approved_at = created_at`, so a sale
> that was pending when the settler ran later looks like it was approved on the match day.
> A deferred line therefore looks like a settler failure with no evidence. It isn't — check
> `settlement_note` on the open line first; since `20260825140000` it says so explicitly.
>
> **DB access:** the Supabase MCP is still dead, but `npx supabase db query --linked "<sql>"
> </dev/null` from this directory works as `postgres` with full DDL, and the Management API
> works for other projects via the CLI keychain token
> (`security find-generic-password -s "Supabase CLI" -w` → POST
> `/v1/projects/<ref>/database/query`). Beware: `cd`-ing inside a Bash call persists, and
> `--linked` resolves from the cwd — a stray `cd` gives a confusing "Cannot find project ref".
>
> **To test anything destructive**, wrap it in a `do $$ ... raise exception 'ROLLBACK-BY-DESIGN\n...' end $$;`
> block — atomic, so it all rolls back, and the results come back in the error message.
> Verify residue afterwards anyway.
>
> Two open items need the USER, not you: raising `max_rows` (blocked — member, not org
> admin, on both Supabase projects) and deleting/renaming the duplicate-version
> `fhe-coachings-tracker/supabase/migrations/20260706170000_init_coaching_schema.local.sql`.
>
> If it's the morning: check whether Thomas Eustace ($110) and Bryan Sequeira ($80) got
> approved. If not, their Aug-25 lines deferred — and the canary should have said so in
> Slack at 09:00 ET. That's the first chance to actually see the new deferred-note row in
> bet history, which has never been rendered on screen.
