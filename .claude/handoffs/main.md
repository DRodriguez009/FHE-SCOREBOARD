# Session Handoff — main
Generated: 2026-07-31 (sportsbook payout fix)
Worktree: /Users/derrickrodriguez/Projects/fhe-scoreboard

## What We Were Working On
Fixed "agents aren't getting paid out their sportsbook bets." The daily switch (Jul 23)
auto-generates + locks matchups but never settled them — settlement was manual and nobody did it,
so 13 bets sat `pending` (coins taken at bet time, never resolved) across Jul 24/27/30. Added
automatic settlement by commission + backfilled the backlog. DB-only; no client/deploy change.

## Remaining Work
- No open code work — fix shipped, backlog paid, verified.
- Watch item (next session): confirm the new cron `auto-settle-matchups` fires Mon 2026-08-03
  ~11:30 UTC and settles Friday's board:
  `select * from cron.job_run_details where jobid=(select jobid from cron.job where jobname='auto-settle-matchups') order by start_time desc limit 3;`
  Then confirm 0 stale open head_to_head lines remain from prior days.

## Key Decisions This Session
- Settlement is now AUTOMATIC by commission (owner approved). Winner = higher approved commission on
  the matchup day (same metric as board 'Today' view). Manual settle buttons kept as an override.
- Ties = refund both sides (push).
- Auto-settle runs 11:30 UTC weekdays — after midnight (prior day complete), before 8 AM generation.
- Fix is DB-only (functions + pg_cron). No index.html change, no Vercel deploy, APP_VERSION unchanged.

## Kickstart Prompt
> Read .claude/sessions/main.md. Single static `index.html` on Vercel (project fhe-scoreboard) with
> its OWN Supabase `sralgaskfktcynpdxjhj` (NOT shared eawp). Sportsbook is DAILY: pg_cron
> 'daily-matchups' (0 12,13 * * 1-5) → `generate_daily_matchups()` creates ~9 head_to_head lines at
> 8 AM NY, book locks 10:20 AM ET (server-side closes_at in place_bet). As of 2026-07-31 settlement
> is AUTOMATIC: pg_cron 'auto-settle-matchups' (30 11 * * 1-5) → `auto_settle_daily_matchups()`
> settles any open head_to_head line whose matchup day is over, paying winners via `credit_wallet`
> (winner = higher approved commission that NY day; tie = refund + cancel). Idempotent/self-healing;
> admin override = `admin_auto_settle_daily_matchups(user,pass)` + the manual settle buttons.
> Migration: supabase/migrations/20260731130000_sportsbook_auto_settle_daily_matchups.sql. To edit
> live locally: `python3 -m http.server <port>` over http:// (Supabase CORS); bump APP_VERSION on any
> client-JS change; ship branch→main directly (owner preference, no ruleset). Do NOT point at eawp.
