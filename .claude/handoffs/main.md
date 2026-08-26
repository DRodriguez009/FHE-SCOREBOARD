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

## Open items
- Whether admin passwords here match time-clock PINs — unknown until a real admin signs in.
- Mark Caraher and Michael Bregio are not time-clock admins, so they always get the link
  version of the admin card. By design; worth telling them once.
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
