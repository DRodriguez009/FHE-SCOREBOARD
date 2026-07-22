# Session Handoff — main
Generated: 2026-07-22 17:12
Worktree: /Users/derrickrodriguez/Projects/fhe-scoreboard

## What We Were Working On
Owner asked to track monthly stats — "total commission for the month". SHIPPED: added a fourth
period toggle **Month to date** (Today / Week to date / Month to date / All time) to the board.
Purely client-side, no schema change / no migration — reuses the existing `approved_at` period
filter. Stat tiles relabel to "This month total / sales", and each agent's `.tv-sub` subtitle now
follows the selected period (owner's choice) instead of being hardcoded to week-to-date.

## Remaining Work
- No open code work. APP_VERSION `2026-07-22-month-to-date-001`.
- Follow-up offered, NOT done: the Sportsbook bet-line period selector (`#sbl-period`, index.html
  ~:502) still only offers Today / This week — add a monthly option if owner wants monthly bet lines.

## Key Decisions This Session
- Month = calendar month-to-date (1st of current month → now), keyed off `approved_at`, same as the
  other periods. New helper `startOfMonth()` at index.html:705.
- Subtitle follows the selected period (owner picked this over keeping a constant week-to-date line).
  Retired the always-computed `weekTotals`/`weekCounts`; subtitle uses the period totals + `subLabel`.

## Kickstart Prompt
> Read .claude/sessions/main.md. Single static `index.html` on Vercel (project fhe-scoreboard), its
> OWN Supabase `sralgaskfktcynpdxjhj` (NOT shared eawp). Board period toggle has 4 periods —
> Today/Week to date/Month to date/All time — driven by `setPeriod()`, `filterByPeriod()` (index.html
> :869), and date helpers `startOfToday`/`startOfWeek`/`startOfMonth` (:702-705); all filter on
> `approved_at`. Stat-tile labels come from `pLabel`, per-agent subtitle from `subLabel` (both keyed
> to currentPeriod in `loadBoard()`). The `.section-tab` pill row (agent portal ~:394 + admin ~:580)
> mirrors the FHE Command Center's 7 sections linking to `fhe-command-center.vercel.app/<section>`.
> To edit live locally: `python3 -m http.server <port>` over http:// (Supabase CORS). Bump
> APP_VERSION on any client-JS change. Ship branch→main directly (owner preference for FHE solo
> repos, no branch-protection ruleset). Do NOT point at the shared eawp Supabase.
