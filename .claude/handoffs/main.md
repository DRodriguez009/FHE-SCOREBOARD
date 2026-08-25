# Session Handoff — main
Generated: 2026-08-25 (evening)
Worktree: /Users/derrickrodriguez/Projects/fhe-scoreboard

## State
**Nothing in flight.** The lunch button shipped, deployed and was verified in production
(`8618615`, `APP_VERSION=2026-08-25-lunch-nav-button-003`). Read the last `## Session` block
in `.claude/sessions/main.md` before touching it — especially the brute-force cap and the
isolation rule, both of which are load-bearing and neither of which is obvious from the code.

## The one open thread: Slack notification on lunch start
The user asked for a Slack message telling an agent what time they went to lunch and when
they are due back. **They are creating the Slack app themselves on 2026-08-26.**

### What exists today (checked, do not re-derive)
- `pg_net` is installed on `eawpwwctsifzcclrwvww`.
- TWO incoming webhooks in `time_clock.policy_config`: `slack_points_webhook_url` and
  `slack_sto_webhook_url`. **Incoming webhooks post to ONE channel and cannot DM anyone.**
- **No Slack user-id column exists anywhere** — verified across the `time_clock` and `public`
  schemas. There is nothing today that can address a message to an individual.
- The working template to copy is `time_clock.tct_notify_slack_lunch_late` — an
  `AFTER INSERT` trigger on `attendance_events` that builds text and fires
  `net.http_post`, wrapped in `exception when others then return new` so Slack being down can
  never roll back a punch. Keep that fire-and-forget discipline.

### What the user needs to hand over
A **bot token** (`xoxb-…`) from a Slack app with `chat:postMessage` and `im:write`.
Not a webhook URL — a webhook cannot do this job.

### Build order once the token exists
1. Store the token in `policy_config` (`slack_bot_token`). It is a secret in a table that
   several apps read — check who can select from `policy_config` before putting it there.
2. Add `slack_user_id` to `time_clock.contractors`. Populate by calling Slack `users.list`
   and matching on email; agent emails are `@firsthealthenroll.org`. Expect a few misses —
   the code must no-op cleanly on a null id rather than erroring.
3. Trigger on `clock_punches` where `punch_type='lunch_out'`, posting via
   `net.http_post` to `https://slack.com/api/chat.postMessage` with
   `Authorization: Bearer <token>`, `channel` = the agent's `slack_user_id`.
   Message: start time and due-back time (`punched_at + lunch_minutes_allowed`).
4. ⚠️ **`chat.postMessage` returns HTTP 200 even when it fails** (`{"ok":false,...}`).
   A fire-and-forget `pg_net` call will look successful while delivering nothing. Verify a
   real DM actually arrives — do not trust the status code.

### Worth raising before building it
The button already shows a live countdown and states the return time when tapped, so a DM at
lunch *start* largely duplicates what the agent is already holding. **A DM at the 50-minute
mark** — "10 minutes left" — is the version that would actually prevent a late-back. Suggest
that trade before writing the start-time version.

## Also still open (pre-existing)
- Not yet exercised by a REAL agent through the login form — needs a live PIN. Watch the first
  agent who signs in and confirm the button appears.
- `max_rows` still 1000 org-wide; raising it needs an org owner (Derrick is member, not admin).
- `/favicon.ico` 404.

## Kickstart Prompt
> Read the last `## Session` block in `.claude/sessions/main.md`. The scoreboard lunch button
> is live and nothing is in flight.
>
> Today's job is the Slack lunch notification. The user was creating the Slack app on
> 2026-08-26 — **ask for the `xoxb-` bot token before planning anything**, since a webhook
> cannot DM and that is the whole blocker. Then follow the build order in the handoff.
>
> Before writing the trigger, raise the 50-minute-warning alternative: the button already
> shows a countdown and the return time, so a start-time DM mostly repeats what the agent
> already has.
>
> Shared prod Supabase `eawpwwctsifzcclrwvww`, no staging, no PITR. Use a `Zzz Smoke Test`
> disposable contractor for anything mutating and delete it child-rows-first afterwards.
> Management API READS work; WRITES to this project were refused by the auto-mode classifier
> in the time-clock repo — DML went through fine from here today, but if DDL is refused, hand
> it over with `pbcopy` for the SQL editor rather than reshaping the command.
