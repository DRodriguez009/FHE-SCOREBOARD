# Session Handoff — main
Generated: 2026-09-04 14:25
Worktree: /Users/derrickrodriguez/Projects/fhe-scoreboard

## What We Were Working On
A reported "Albert has 0 Mike Coins" that turned out to be a **display lie, not a lost balance** —
Albert Gonzalez has 2,067 coins and lifetime betting of net −33. Fixed the client-side bug class
that invented the zero. **Nothing is in flight.**
`APP_VERSION=2026-09-04-wallet-error-honesty-001`.

## Remaining Work
No TASKS.md in this repo. Nothing outstanding in code. Carried over, all human-blocked:
- Rotate the Slack bot token (passed through a chat transcript). Needs the Slack admin UI.
- Decide whether lunch gets its own point tiers. It currently borrows `late_tier1..4_points`, so
  60+ minutes over costs 5 points — the same as being an hour late for a shift. All three of
  8/26's lunch penalties were waived by hand; if that repeats, split the keys.
- PITR is disabled on `eawpwwctsifzcclrwvww`. Paid, and Derrick is a *member* not an admin on
  that Supabase org since the migration — same blocker as raising `max_rows` from 1000.
- **New:** the `.catch(()=>null)`-then-render-a-number pattern fixed here was never audited in the
  five sibling apps. Worth one sweep.
- Pre-existing here: `/favicon.ico` 404; real PINs live in this repo's git history, so never
  blanket `git add -A` without looking.

## Key Decisions This Session
- **An unreadable value must never render as a number.** `get_wallet` RAISES `P0001 invalid
  credentials` on a dead token; the old `.catch(()=>null)` plus `wallet?Number(wallet.coins)||0:0`
  turned that into a confident `🪙 0 Mike Coins`. Now: dead token → real sign-out with a message,
  other failures → `🪙 —`, bet modal refuses to open on a balance it couldn't read.
- **Match on the error message, never `P0001` alone.** `place_bet` raises P0001 for `insufficient
  balance` / `exceeds max bet` / `line closed`; keying off the code would sign people out for
  ordinary bet refusals. Verified no other `raise exception` in `supabase/migrations` contains
  "invalid credentials".
- `sbSessionExpired()` reuses `agentLogout`/`adminLogout` so the server-side revoke and the paired
  time-clock token die with the scoreboard session.

## Kickstart Prompt
> Read the last `## Session` block in `.claude/sessions/main.md`. Nothing is in flight.
>
> Before changing anything in `index.html`: it is one ~143KB file. Edit with python string
> replacements that assert a match count of 1, then syntax-check by extracting the inline
> `<script>` blocks and running `node --check` on each. **Bump `APP_VERSION` in `<head>` on every
> ship** or open tabs never see the change — and batch related changes into ONE deploy, because
> each bump interrupts the whole floor with a full-screen overlay.
>
> **If an agent reports missing coins/points, check the session before the ledger.** Coin Standings
> calls `get_agents_board` (anon, tokenless) while the balance badge calls `get_wallet` (token). If
> the standings show real coins and the badge shows 0, it's an expired token. As of
> 2026-09-04 that renders as a sign-out instead of a zero.
>
> **Testing `index.html` in a browser:** top-level `let` bindings (`currentAgent`,
> `sbCurrentBettor`) are NOT window properties — assign them directly inside `page.evaluate`, not
> via `window.x =`, or your test silently exercises the wrong path. Function declarations (`rpc`)
> *are* on `window` and can be stubbed. Don't call `navTo()` in a test; it fires an async
> `initSportsbook()` that races your assertions.
>
> If a missing lunch control is reported, check in this order before suspecting a bug: is there a
> scoreboard session AND a time-clock bridge session; is the person `clock_in_exempt`; do their
> PINs match across both apps. Parity was audited 2026-08-27 (17/17 agents, 5/7 admins) but that's
> a snapshot — a one-sided PIN rotation silently removes the control.
>
> If attendance events look missing, query `time_clock.attendance_event_audit` FIRST. On 8/27
> three absent `lunch_late` rows read as a scoring bug and were a human deletion four minutes
> earlier.
>
> Two databases: this app is Supabase `sralgaskfktcynpdxjhj`; the lunch bridge reaches
> `eawpwwctsifzcclrwvww` (shared, no staging, **no PITR**). Use a `Zzz Smoke` disposable
> contractor for anything mutating, delete it child-rows-first, and cast `id::text` for
> `auth_sessions` or the batch rolls back and leaves the test row live in the admin dropdown.
>
> Note: the Supabase CLI access token is EXPIRED as of 2026-09-02 — `supabase db query --linked`
> returns 401. Read paths that still work: the anon key in `index.html` against
> `<ref>.supabase.co/rest/v1/rpc/<anon-callable-fn>` (that's how Albert's balance was confirmed).
