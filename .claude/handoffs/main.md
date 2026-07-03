# Session Handoff — main
Generated: 2026-07-03 17:44
Worktree: /Users/derrickrodriguez/Projects/fhe-scoreboard

## What We Were Working On
Two threads, both now closed out:
1. The broken Vercel auto-deploy hook flagged at the end of the prior session (pushes/merges to
   `main` weren't triggering a Production deployment after the account moved from the personal
   Vercel team to the new `FHE` team). Root-caused via the Vercel REST API, fixed by
   disconnecting/reconnecting the GitHub integration from the Vercel dashboard UI (not the CLI —
   `vercel git connect` alone is a no-op if the DB link record already looks correct), and
   confirmed fixed across two independent merges.
2. Along the way: removed a stray duplicate file (`index .html`, trailing space in the name),
   and set up `/smoke`-skill tooling for this repo — a route check plus login-flow checks for
   both the agent portal and admin panel.

## Remaining Work
None on this repo. Everything shipped and merged:
- PR #3 (`chore/remove-stray-index-file`) — merged `a95d09c`.
- PR #4 (`chore/smoke-login-flows`) — merged `ac29c5e`.
- PR #5 (`chore/update-test-log`) — merged `5d29a7f`.
- Auto-deploy confirmed working via `source: "git"` / `target: "production"` deployments for
  both the PR #2 and PR #3 merges (verified via the Vercel API, not just "should work now").
- Smoke suite (route check + `loginAgent` + `loginAdmin`) run twice, fully green both times —
  see `TEST_LOG.md`.

This repo still has never been through `/auto-init` — no TASKS.md/PLAN.md/CONTEXT.md/VISION.md
exist. Optional, not blocking anything at current scope.

## Key Decisions This Session
- Branch workflow question (open since the prior session) is resolved: feature branches + PRs
  for everything on this repo going forward. No more direct-to-`main` commits.
- Vercel API access for this project now goes through the `plugin:vercel:vercel` MCP connector
  (authorized for **All FHE projects** under the `FHE` team), not the original `claude.ai Vercel`
  connector, which is still stuck on the old personal team and 403s on this project.
- Confirmed agentLogin()/adminLogin() (index.html) are safe to smoke-test anytime: read-only RPCs
  (`verify_agent_login`/`verify_admin_login`), no lockout state, session lives in tab-local
  `sessionStorage` only — running the login checks can't affect real agents/admins.
- Daniel Ramirez's correct smoke-test PIN is **3596** (not 3006, which the user first guessed).

## Kickstart Prompt
> Read this repo's `.claude/sessions/main.md` in `~/Projects/fhe-scoreboard` for full context —
> especially the 2026-07-03 17:44 session block, which covers the Vercel auto-deploy fix in
> detail. There is no engineering work queued on this repo right now; everything from the last
> two sessions (the "Go to" dropdown, sessionStorage login persistence, the auto-deploy fix, the
> stray-file cleanup, and the smoke-test tooling) is shipped, merged, and verified.
>
> If a future change needs to smoke-test this app: `smoke.config.json` has `routes: ["/"]` plus
> `flows.loginAgent`/`flows.loginAdmin`. Run the plain route check with the shared skill's
> headless runner (`node ~/.claude/skills/smoke/scripts/headless-runner.mjs --config
> ./smoke.config.json --out ./.smoke-out`), but run the login flows with this repo's own
> `scripts/smoke-login-check.mjs <flowName>` instead — the shared skill's headless runner can't
> verify them because it hands login state between Playwright contexts via `storageState()`,
> which doesn't capture `sessionStorage`, and this app's session lives in `sessionStorage`.
> Credentials go in as env vars only (`SMOKE_AGENT_NAME`/`SMOKE_AGENT_PIN`,
> `SMOKE_ADMIN_USER`/`SMOKE_ADMIN_PASS`) — never write them into `smoke.config.json`.
>
> If a push to `main` ever stops auto-deploying again: check the Vercel API (or `vercel ls
> fhe-scoreboard --scope fhe-projects`) for whether the latest Production deployment has
> `source: "git"` or `source: "cli"` — `cli` means the webhook silently isn't firing again, and
> the fix is a dashboard-side (not CLI) Git disconnect/reconnect under Project → Settings → Git.
