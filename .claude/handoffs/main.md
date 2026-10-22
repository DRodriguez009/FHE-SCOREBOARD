# Session Handoff — main
Generated: 2026-10-22 14:10
Worktree: /Users/derrickrodriguez/Projects/fhe-scoreboard

## What We Were Working On
**2026-10-22:** row-cap canary fix shipped — bettor leaderboard now summed server-side by
`get_bettor_leaderboard_public()` (migration 20261022120000, applied + verified). The held
2026-09-10 transport session hook shipped in the same push. Nothing in flight.

_Earlier:_ Voiding Bryan Sequeira's Sep 8 bets so he could re-place them, plus a self-serve "take a bet back"
button. **Bryan's half shipped and has since settled out. The button was written, then parked
unbuilt at the user's request.** Nothing is in flight.

## Remaining Work
No TASKS.md in this repo. Nothing outstanding in code. All carried-over items are human-blocked:
- **Supabase token is dead** (`sbp_c649…` → 401 from the CLI and from `api.supabase.com`). No SQL
  or DDL is possible until it's replaced. `npx supabase login` will NOT work under Claude Code's
  `!` prefix — non-TTY, `LegacyLoginMissingTokenError`. It needs a real terminal, and the durable
  fix is a dashboard **Personal Access Token** (`npx supabase login --token …`), because
  browser-flow tokens expire with the dashboard session. This has now bitten twice.
- Derrick is a **member, not owner** on the FHE Supabase org since the 8/01 migration. That is a
  403-class problem separate from the 401 above, and it is why PITR is off on `eawpwwctsifzcclrwvww`
  and `max_rows` is stuck at 1000. One request to the org owner retires all three.
- Rotate the Slack bot token (passed through a chat transcript).
- **The credentials sheet was read into a transcript this session**, so every FHE PIN is in that
  log. Rotation is the user's call.
- Pre-existing: `/favicon.ico` 404; real PINs live in this repo's git history, so never blanket
  `git add -A`.

## Key Decisions This Session
- **A withdrawn bet must be deleted, not restatused.** `sb_resettle_line` re-`pending`s every bet
  on a line with no status filter, and its reversal loop matches only `won`/`refunded` — so a
  `cancelled` row would keep its returned stake AND be paid out again. `settle_bet_line` isn't in
  this repo (MCP-created) and can't be audited, so deletion is the only path that's safe under
  every settler.
- **There is no per-bet void RPC.** `cancel_bet_line` is line-level, so voiding one person's bets
  refunds everyone on those lines. Bryan had bet all 9 lines, so this took out the whole day's book
  and also refunded Gabriel Tamayo (5 bets / 5,325) — surfaced and approved before executing.
- **`create_bet_line` takes no close-time parameter, so a recreated line has `closes_at = null` and
  NEVER locks.** That's the no-SQL way to reopen a book, and a footgun.
- Corrected mid-session: **there is no same-day settle deadline.** The settler only takes open
  head_to_head lines with `created_at::date < today`, so today's lines cannot settle today.

## Kickstart Prompt
> Read the last `## Session` block in `.claude/sessions/main.md`. **Nothing is in flight** — as of
> 2026-10-22 (`4cf27ee`) everything is committed, pushed and live, including the 2026-09-04
> transport session hook and the server-side bettor leaderboard (`get_bettor_leaderboard_public`,
> migration `20261022120000`). DDL goes through the dashboard SQL editor (paste the migration,
> run verify queries one at a time — the editor shows only the last result grid).
>
> **Before editing `index.html`:** it is one ~152KB file. Edit with python string replacements that
> assert a match count of 1, then extract the inline `<script>` blocks and `node --check` each.
> **Bump `APP_VERSION` on every ship** or open tabs never see the change — and batch related
> changes into ONE deploy, because each bump interrupts the whole floor with a full-screen overlay.
> Beware double-escaping in heredocs: `\\u2014` searches for a literal backslash and silently
> matches nothing — use the real `—`.
>
> **If someone reports an agent has no coins, read their PENDING BETS before the ledger.** Stakes
> debit at placement, so a big open position looks like a drained wallet. On 2026-09-10 Bryan
> Sequeira showed **1 coin** with 17 pending bets and 50,885 riding on "Marlon vs Abraham — Sep 10".
> (The other false-zero cause is an expired session: Coin Standings calls `get_agents_board`, which
> is anon and tokenless, while the badge calls `get_wallet` with a token. Standings right + badge 0
> = the session.)
>
> **To void bets or reopen a book with no DB access** (the 2026-09-08 playbook, now in memory):
> admin RPCs are anon-callable and guarded by the admin password, so drive them in a browser via
> the page's own `rpc()` helper. `currentAdmin` is a top-level `let` — reachable by name inside
> `page.evaluate` but NOT as `window.currentAdmin`. `get_all_bets_admin` does **not** return `id`
> or `line_id`; get line ids from `get_all_lines_admin`. Admin PIN: read
> `reference_credentials_sheet` in memory, don't ask. Capture a pre-state to
> `~/Projects/_rollbacks/` first — cancelling refunds real stakes and is NOT reversible.
>
> **The parked take-back button** is at `~/Projects/_rollbacks/parked-takeback-button-2026-09-08/`:
> the migration (`bet_cancellations` table + `cancel_my_bet` + `get_my_bets` returning
> `line_closes_at`) and a copy of index.html carrying the UI. Restoring is that migration plus three
> edits to index.html. Read the migration's header before changing its approach — it documents why
> the bet is deleted rather than restatused. **Needs the Supabase token; there is no browser
> workaround for DDL.**
>
> Two databases: this app is Supabase `sralgaskfktcynpdxjhj`; the lunch bridge reaches
> `eawpwwctsifzcclrwvww` (shared, no staging, **no PITR**).
>
> Settled and not to be re-litigated: **lunch does NOT get its own point tiers** (decided
> 2026-08-27) — it keeps sharing `late_tier1..4_points`, and lunch points land in the one combined
> total with attendance. Retuning *arrival* tiers still silently retunes lunch.
