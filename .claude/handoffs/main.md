# Session Handoff — main
Generated: 2026-08-05 18:52
Worktree: /Users/derrickrodriguez/Projects/fhe-scoreboard

## What We Were Working On
Reported bug: approved deals were not appearing on the scoreboard. Root cause was not the
approval path — PostgREST silently truncates every response at the project's Max rows
(1000) with an HTTP **206, not an error**, so `supabase-js` set no error and the board
aggregated a short list. `get_public_commission_feed` had crossed the cap. With no
`ORDER BY` on the function, Postgres returned heap order, and approving a commission is an
`UPDATE` that relocates the row to the end of the heap — so the rows falling past the cut
were precisely the newest approvals.

Fixed client-side first, then properly by moving the board's arithmetic into Postgres. The
session then widened into everything that class of bug touched: an audit of the sibling
apps, a canary to catch it recurring, an audit trail for coin movements, month grouping in
All Entries, and a UTC→Eastern day-bucketing fix.

## Remaining Work
No TASKS.md in this repo — these come from TEST_LOG.md follow-ups.

- **The canary is not scheduled.** `.github/workflows/canary.yml` exists locally but cannot
  be pushed — the gh token has `gist, read:org, repo` and `.github/workflows/` writes need
  `workflow` scope. Fix by running `gh auth refresh -h github.com -s workflow` in
  **Terminal.app** (the in-session `!` runner has a 120s cap and the device flow exceeded
  it), or paste the file via GitHub → Actions → New workflow. **Then remove the
  `.github/workflows/canary.yml` line from `.git/info/exclude`** — it was added so
  `git add -A` would stop sweeping the file into rejected pushes.
- **Nothing from this session has been looked at in a browser.** Playwright MCP was locked
  by another session throughout. Least-verified: the admin All Entries month grouping and
  the new bet-history rows.
- Raise **Max rows** in the Supabase dashboard (Settings → API) as a backstop. Every caller
  is fixed, but the cap is still armed for the next query anyone writes.
- Re-auth the **Supabase MCP** (`/mcp` → supabase → FHE org `ieuivsdynmfdncskrtdo`). Not
  blocking — the CLI covers it — but MCP tooling is unavailable until then.
- `coin_ledger.reason` / `.actor` only populate when a caller sets the `app.coin_reason` /
  `app.coin_actor` GUCs. Existing functions don't, so routine movements log with a null
  reason. Worth setting in the approval and settlement paths.
- No UI renders `coin_ledger`; `admin_coin_ledger(username, password, wallet_id, limit)`
  exists and is admin-gated.
- Canary covers the anon surface only — authenticated endpoints are unchecked.
- Known/accepted: `list_admin_names()` is anon-callable; `favicon.ico` 404s.

## Key Decisions This Session
- **Aggregate server-side, don't just raise the cap** — raising it re-breaks at the new
  ceiling. Board went from ~1024 rows/147KB per refresh to ~18 rows/2.9KB.
- **Coin audit implemented as a trigger on the balance column**, not inside
  `credit_wallet()`: betting and settlement use the helper, but the three
  `admin_*commission` functions write `set coins = coins + 10` directly, so helper-only
  logging would have missed every commission award. A trigger also catches raw operator SQL.
- **`get_public_commission_feed` bounded to 1000** rather than deleted — no callers left,
  but it was still a trap; the bound makes the contract honest.
- **Javier's disputed bet was switched, not refunded** (b→a, settled won, 1,495 credited,
  742→2,247). Evidence still indicates it was recorded as placed; this was an operator
  decision in the agent's favour and is recorded as such in TEST_LOG.md and the ledger.
- **The UTC streak quirk was deliberately preserved** when streaks moved into SQL, so
  numbers wouldn't shift mid-change — then fixed separately once understood.

## Kickstart Prompt
> fhe-scoreboard, 2026-08-05: the "approved deals don't show on the board" bug was
> PostgREST silently truncating responses at the 1000-row Max rows cap (HTTP 206, no
> error). Fully fixed and deployed — the board now reads `get_scoreboard_totals(p_since)`
> and `get_agent_streaks()` instead of pulling every commission. `main` is clean at
> `cda6a57`, live APP_VERSION `2026-08-05-eastern-time-days-004`.
>
> **Critical access note:** the Supabase MCP is dead (grant still points at the empty
> `Derrick Org`), but the **`supabase` CLI works** — `npx supabase db query --linked "<sql>"
> </dev/null` from this directory runs as `postgres` with full DDL and needs no DB
> password. Use `-f <file>` for migrations. Do NOT conclude DB work is blocked; that was a
> wrong assumption carried in the previous handoff.
>
> The single open blocker is that `.github/workflows/canary.yml` cannot be pushed — the gh
> token lacks `workflow` scope. The user must run `gh auth refresh -h github.com -s
> workflow` in Terminal.app (not via `!`, which caps at 120s and killed the device flow) or
> paste the file in GitHub's web UI. After that, push it AND delete the
> `.github/workflows/canary.yml` line from `.git/info/exclude`. `SLACK_WEBHOOK_URL` is
> already set as a repo secret.
>
> Nothing from this session has been verified in a browser — Playwright MCP was locked all
> day. If it's free, smoke the admin tab (All Entries month grouping) and the sportsbook
> bet history first; those are the least verified changes.
>
> Gotchas if you touch this code: `verify_bettor` must keep its `coalesce(..., false)` —
> callers do `if not verify_bettor(...)` and a NULL would skip the guard. Verify sign-out
> with `sb_session_whoami`, not by checking sessionStorage cleared. Day bucketing is
> `America/New_York` in three places (`calcStreak`, `calcPersonalBest`,
> `get_agent_streaks`) — keep them in step. And `rpcAll` pagination must always pass a
> unique-tie-broken sort (`created_at.desc,id.asc`); ordering by `id.asc` alone sorts by
> UUID, which is what silently scrambled the admin lists mid-session.
