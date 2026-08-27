# Session Handoff — main
Generated: 2026-08-26
Worktree: /Users/derrickrodriguez/Projects/fhe-scoreboard

## State
**Nothing in flight.** Live at `APP_VERSION=2026-08-26-admin-lunch-panel-001`, verified in
production (card present, all four bridge functions defined, no console errors).

Two lunch features live in this file, both riding a bridge to a DIFFERENT Supabase project
(`eawpwwctsifzcclrwvww`, not this app's `sralgaskfktcynpdxjhj`):
- **Agent:** `🍔 Lunch` in the top nav → counts down → `Back from Lunch · 47m left` → red
  `12m OVER`. Dimmed `Lunch · Not Required` for `clock_in_exempt` staff (Mark Caraher only).
- **Admin:** `🍔 Currently On Lunch` card in the Admin panel.

Read the last `## Session` block in `.claude/sessions/main.md` — the bridge's failure modes are
not obvious from the code.

## Rules for touching the bridge
- **Every** time-clock call goes through `tctRpc()`, which resolves to `{data,error}` and never
  throws. Do not fold these into this app's own error paths — that is the 2026-08-19 clock-in
  outage shape, and this app must survive the other project being down.
- **One login attempt per tab** (`fhe-scoreboard-tct-skip`, `fhe-scoreboard-tct-admin-skip`).
  The time clock throttles logins; a retry loop could lock a real person out of the real clock.
- **Never render blank.** Both features have explicit copy for every state. Two "it's broken"
  reports this week were both just a component hiding itself when it had nothing to show.
- A dead time-clock token must never sign the user out of the scoreboard. Verified for both.

## Credential parity — audited 2026-08-26, do not re-derive
Every PIN from the master sheet was replayed against both apps' login RPCs (and admins' tokens
pushed through `tct_admin_open_lunches`). Result: **agents 17/17 will see the button, zero
broken.** **Admins: 5 of 7 get the live card** — Derrick, Jordan Kyles, Joshua Diaz, Michael
Sanguily, Yamill Julian. Mark Caraher signs in but is not a time-clock admin; Michael Bregio has
no time-clock account. Both correctly get the link version. Full table in TEST_LOG.md.

⚠️ **This is a snapshot, not a guarantee.** Rotating a PIN in one app and not the other silently
removes that person's lunch button — no error, just an absent control. See
`project_pin_rotation_handoff_gap` in memory for the last time a one-sided rotation did this.

## Efficiency — done, don't redo
Both polls that dominated idle traffic were fixed 2026-08-27 and measured in production: the
update check `Range`-fetches 2KB instead of 143KB (`9dc615d`), and the pending badge counts in
Postgres instead of shipping every commission (`4e49ad5`). `loadBoard`'s 30s refresh is the
remaining periodic cost and it is doing real work. ⚠️ `APP_VERSION` now lives in `<head>` and
must stay a single declaration — a second `const` in the same scope blanks the app.

## Open items
- Nobody has punched a real lunch yet. Watch the first one.
- Pre-existing: `max_rows` 1000 (needs an org owner to raise), `/favicon.ico` 404, real PINs in
  this repo's git history — never blanket `git add -A` without checking.

## Kickstart Prompt
> Read the last `## Session` block in `.claude/sessions/main.md`. Both lunch features are live
> and nothing is in flight.
>
> If the user says a lunch control is missing, check in this order before suspecting a bug:
> is there a scoreboard session AND a time-clock bridge session; is the person
> `clock_in_exempt`; are their PINs the same in both apps. A mismatch degrades to a missing
> control, never an error — that is intentional, and it is also the most likely cause.
>
> This app is one 120k+ line `index.html`. Edits are python string replacements with an
> asserted match count; syntax-check by extracting the inline `<script>` and running
> `node --check`. Bump `APP_VERSION` on every ship or open tabs never see the change.
