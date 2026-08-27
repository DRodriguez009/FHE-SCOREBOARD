# Session Handoff — main
Generated: 2026-08-27 10:15
Worktree: /Users/derrickrodriguez/Projects/fhe-scoreboard

## What We Were Working On
Lunch tracking across the scoreboard and time clock (finished, live, exercised by real agents),
then the idle-traffic efficiency pass on this app's two polling loops. **Nothing is in flight.**
`APP_VERSION=2026-08-27-pending-count-rpc-001`, verified in production, no console errors.

## Remaining Work
No TASKS.md in this repo. Nothing outstanding in code. Everything left is blocked on a human:
- Rotate the Slack bot token (passed through a chat transcript). Needs the Slack admin UI.
- Decide whether lunch gets its own point tiers. It currently borrows `late_tier1..4_points`, so
  60+ minutes over costs 5 points — the same as being an hour late for a shift. **All three of
  8/26's lunch penalties were waived by hand**, which is the signal to watch: if it repeats, split
  the keys.
- PITR is disabled on `eawpwwctsifzcclrwvww`. Paid, and Derrick is a *member* not an admin on
  that Supabase org since the migration — same blocker as raising `max_rows` from 1000.
- Pre-existing here: `/favicon.ico` 404; real PINs live in this repo's git history, so never
  blanket `git add -A` without looking.

## Key Decisions This Session
- **Both idle-traffic patterns are scoreboard-only — audited, don't go hunting.** All five sibling
  apps have zero `APP_VERSION` overlays and zero row-counting timers. This is the only
  single-file `index.html` app, so the only one hand-rolling deploy-version detection.
- The update overlay now needs the same new version on **two consecutive polls** before it shows.
  Vercel's edges disagree during propagation, so one sighting is noise.
- `APP_VERSION` is declared **once**, in `<head>` at byte 472, so the poll can `Range`-fetch 2KB.
  A second `const` in the same global scope is a SyntaxError that blanks the entire app.
- `get_pending_count_admin` counts in Postgres; `loadAdmin()` still fetches full rows because the
  money stats need them.

## Kickstart Prompt
> Read the last two `## Session` blocks in `.claude/sessions/main.md`. Nothing is in flight —
> lunch tracking and the efficiency pass are both done, live, and measured.
>
> Before changing anything in `index.html`: it is one ~143KB file. Edit with python string
> replacements that assert a match count of 1, then syntax-check by extracting the inline
> `<script>` blocks and running `node --check` on each. **Bump `APP_VERSION` in `<head>` on every
> ship** or open tabs never see the change — and batch related changes into ONE deploy, because
> each bump interrupts the whole floor with a full-screen overlay (5 bumps in 24h on 8/25-26 was
> the mistake that prompted the two-strike fix).
>
> If the user reports a missing lunch control, check in this order before suspecting a bug: is
> there a scoreboard session AND a time-clock bridge session; is the person `clock_in_exempt`; do
> their PINs match across both apps. Parity was audited 2026-08-27 — 17/17 agents and 5/7 admins
> are fine — but it is a snapshot, and a one-sided PIN rotation silently removes the control.
>
> If attendance events look missing, query `time_clock.attendance_event_audit` FIRST. On 8/27
> three absent `lunch_late` rows read as a scoring bug and were a human deletion four minutes
> earlier.
>
> Two databases: this app is Supabase `sralgaskfktcynpdxjhj`; the lunch bridge reaches
> `eawpwwctsifzcclrwvww` (shared, no staging, **no PITR**). Use a `Zzz Smoke` disposable
> contractor for anything mutating, delete it child-rows-first, and cast `id::text` for
> `auth_sessions` or the batch rolls back and leaves the test row live in the admin dropdown.
