# Session Handoff — main
Generated: 2026-08-01 12:48
Worktree: /Users/derrickrodriguez/Projects/fhe-scoreboard

## What We Were Working On
Security overhaul of the auth layer, triggered by a bug report that Derrick couldn't log in
to approve commissions. Fixing that (he had no `public.admins` row) exposed a much larger
problem: the app re-sent the admin password / agent PIN on **every** privileged RPC, agent
PINs were stored in **plaintext**, and a conventional DB lockout was provably useless here.
Replaced with session-token auth + bcrypt PINs + a working lockout. Shipped and verified.

Note: this repo is the **only one still on Derrick's personal GitHub account**
(`DRodriguez009/FHE-SCOREBOARD`, public) — that's deliberate. Its Supabase project
(`sralgaskfktcynpdxjhj`) *did* move to the FHE org on 2026-08-01.

## Remaining Work
- **Re-run `get_advisors`** on `sralgaskfktcynpdxjhj` once the Supabase MCP grant is
  re-authorized against the FHE org. It never ran after the DDL — permissions dropped
  mid-command as the project transferred. A black-box audit through the public anon key
  passed every externally testable lint (see TEST_LOG.md); the only residual is
  `function_search_path_mutable`, and every function sets an explicit `search_path` in
  the applied migration text. Expect confirmation, not discovery.
- **`list_admin_names()` is anon-callable** and enumerates admin usernames. Logged, not
  fixed — low value to hide since the names are on a wall-mounted board, but it is what
  makes targeted PIN guessing easy. Revisit if the lockout ever proves insufficient.
- Cosmetic: `favicon.ico` 404s on the bare site (pre-existing).

## Key Decisions This Session
- **Session tokens, not just a lockout.** A `RAISE` aborts the transaction and rolls back
  any failure counter written in the same call — verified empirically against the live DB.
  Since every privileged RPC here raises on bad credentials, a counter-based guard silently
  does nothing. Worse, `list_admin_names()` hands out usernames and `get_agents_admin(user,
  guess)` let an attacker walk all 10,000 four-digit PINs without ever tripping it. Tokens
  reduce secret handling to one non-raising entry point, which is what makes the counter stick.
- **RPC signatures left unchanged** — `p_password`/`p_pin` now carry tokens. Kept the 11
  `admin_*` callers edit-free. Don't be misled by the parameter names.
- **Agents can no longer have their PIN read back**; reset (`admin_set_agent_pin`) replaces
  lookup. The master credentials sheet remains the source of truth.

## Kickstart Prompt
> fhe-scoreboard's auth was rebuilt on 2026-08-01: session tokens (`auth_sessions`,
> `sb_issue_session`/`sb_resolve_session`/`sb_session_whoami`/`sb_end_session`), bcrypt agent
> PINs in `agents.pin_hash` (plaintext `pin` column dropped), and a working 8-fails/15-min
> lockout via `login_attempts`. Everything is deployed and verified — see TEST_LOG.md for the
> full pass including an adversarial black-box audit. The ONE open task is re-running
> `get_advisors` on Supabase project `sralgaskfktcynpdxjhj`, which is blocked until the user
> re-authorizes the Supabase MCP grant against the FHE org (`/mcp` → Supabase →
> re-authenticate → select the FHE org); right now `execute_sql` returns "You do not have
> permission" because the OAuth grant still points at the now-empty `Derrick Org`. If you
> need DB reads before that, the anon REST API at
> `https://sralgaskfktcynpdxjhj.supabase.co/rest/v1/rpc/...` still works with the anon key in
> index.html. Critical gotcha if you touch auth: `verify_bettor` must keep its
> `coalesce(..., false)` — callers do `if not verify_bettor(...)`, and a NULL would skip the
> guard entirely. And verify sign-out with `sb_session_whoami`, not by checking sessionStorage
> cleared — that exact mistake left live tokens behind and had to be fixed.
