-- Remove the shared `admin` login.
--
-- `public.admins` held a generic account (username 'admin', display name "Admin") that
-- anyone with the PIN could sign in as. It defeats the per-person accountability the rest
-- of the stack deliberately moved to on 2026-07-01: every admin action — approving
-- commissions, creating and settling bet lines, correcting a settled line — is attributed
-- to `p_username`, and "admin" attributes it to nobody.
--
-- It was also on Derrick's personal PIN until the 2026-08-14 rotation gave it its own, which
-- is how it surfaced. Approved by Derrick 2026-08-17.
--
-- Why deleting the row is sufficient: manager identity is a session token resolved against
-- `auth_sessions` (principal 'admin'), and the only thing that mints one is
-- `verify_admin_login`, which looks the username up in `public.admins`. No row, no session,
-- no login. `list_admin_names()` is just `select username, name from public.admins`, so the
-- name also disappears from the sign-in dropdown with no client change. Checked first: 0
-- live sessions for it, so nobody is interrupted mid-action.
--
-- Deliberately KEPT:
--   * `managers_wallet` row 'admin' (150 coins) and its one historical bet — "Will Albert
--     get to 25K", 50 coins on yes, settled won for 100 on 2026-06-30. The wallet is now
--     unreachable because nothing can authenticate as 'admin', so it is inert. Deleting it
--     would orphan a settled bet and punch a hole in the coin history for no security gain:
--     the risk was the shared *login*, not the record of what it once did.

delete from public.auth_sessions where principal = 'admin' and identity = 'admin';
delete from public.login_attempts where identity = 'admin';
delete from public.admins where username = 'admin';
