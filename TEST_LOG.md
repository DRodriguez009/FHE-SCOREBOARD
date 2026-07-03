# TEST_LOG.md

## Smoke — 2026-07-03 17:24

### URL: https://fhe-scoreboard.vercel.app
### Surface: headless
### Overall: PASS

| Check | Result | Details |
|-------|--------|---------|
| Route: / | PASS | 0 console errors, 0 failed requests |

### Notes:
- Ran ad hoc (no smoke.config.json existed for this project — a minimal one was created covering the single static route `/`, since this app has no server-side routing).
- Verified against production after the recent Vercel git-integration fix + PR #3 merge: leaderboard rendered correctly with live data (16 agents) via the security-hardened RPCs, nav (Scoreboard / Agent Portal / Sportsbook / Admin) present, no errors.
- Login/admin/sportsbook flows were not exercised (would require real credentials) — visual/route check only.

## Smoke — 2026-07-03 (login flows)

### URL: https://fhe-scoreboard.vercel.app
### Surface: headless (custom script — see below)
### Overall: PASS

| Check | Result | Details |
|-------|--------|---------|
| Flow: loginAgent (Daniel Ramirez) | PASS | 0 console errors, 0 failed requests, portal rendered ("Welcome, Daniel Ramirez") |
| Flow: loginAdmin (admin) | PASS | 0 console errors, 0 failed requests, panel rendered ("Welcome, Admin! You have full admin access.") |

### Notes:
- Added `flows.loginAgent` / `flows.loginAdmin` to `smoke.config.json` (proper /smoke skill flow format, forward-compatible with the Chrome-MCP interactive path).
- The shared /smoke skill's headless runner can't execute these: it hands off from a login context to a fresh route-check context via Playwright's `storageState()`, which does not capture `sessionStorage` — and this app stores its session in `sessionStorage`, not cookies/localStorage. A fresh context would just see the login screen again.
- Added `scripts/smoke-login-check.mjs` (project-local) to run a named flow start-to-finish in one persistent page/context instead, so the app's real session state survives through the final screenshot. Reuses the Playwright install already bundled with the `/smoke` skill rather than adding a dependency to this static-HTML repo.
- Credentials are passed as env vars only (`SMOKE_AGENT_NAME`/`SMOKE_AGENT_PIN`, `SMOKE_ADMIN_USER`/`SMOKE_ADMIN_PASS`) — never written to `smoke.config.json` or committed anywhere.
- Confirmed via code read (`agentLogin()`/`adminLogin()`) that both call read-only `verify_*_login` RPCs — no lockout counters, no shared/global session state — so this check is safe to run anytime without affecting real users.
- Usage: `SMOKE_AGENT_NAME="..." SMOKE_AGENT_PIN="..." node scripts/smoke-login-check.mjs loginAgent` (swap for `SMOKE_ADMIN_USER`/`SMOKE_ADMIN_PASS` + `loginAdmin`).
