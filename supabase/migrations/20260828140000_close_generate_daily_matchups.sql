-- Close public.generate_daily_matchups(boolean) to anon. It has been open since 2026-07-23.
--
-- WHAT WAS WRONG. `20260723190000_sportsbook_daily_matchups.sql:109` ends with:
--     revoke execute on function public.generate_daily_matchups(boolean) from anon, authenticated;
-- under the comment "lock down the raw one". It never locked anything down: **anon inherits PUBLIC**,
-- and that statement does not name `public`. The live ACL confirms it exactly --
-- `=X/postgres | postgres=X/postgres | service_role=X/postgres`: the explicit `anon` grant was
-- removed, the leading `=X` (PUBLIC) stayed, and `has_function_privilege('anon', ..., 'execute')`
-- returns true. This is not a regression; the revoke was a no-op from the day it was written.
--
-- WHY IT MATTERS. The function is VOLATILE and inserts into bet_lines, and `p_force := true`
-- bypasses BOTH of its own guards -- the weekend skip and the 8-AM-ET-only window:
--     if not p_force then
--       if v_dow = 0 or v_dow = 6 then return 0; end if;
--       if v_hour <> 8 then return 0; end if;
--     end if;
-- So anyone holding this project's publishable key -- which ships in index.html's page source --
-- could mint betting lines at any hour, on any day, into a ledger where stake is debited at
-- placement and a settled line can never be re-settled.
--
-- WHY THIS IS SAFE (all three verified live, not assumed):
--   1. The real driver is **pg_cron job 1**, `select public.generate_daily_matchups();` on
--      `0 12,13 * * 1-5` (8 AM ET, doubled for DST), **running as `postgres`**. A revoke from
--      public/anon/authenticated has no effect on it. Confirmed against cron.job, and corroborated
--      by bet_lines: exactly 9 lines at 08:00 ET every weekday, never a weekend, for 20+ days.
--   2. The only client call site is `index.html:1606`, and it calls the admin wrapper
--      `admin_generate_daily_matchups(p_username, p_password)`, which asserts admin and then calls
--      this function from inside SECURITY DEFINER -- so it keeps working.
--   3. No external scheduler uses it: nothing in any repo references the raw name, and the pg_cron
--      job fully accounts for the observed daily cadence.
--
-- Naming `public` is the entire point of this migration. Do not write a revoke without it.
revoke execute on function public.generate_daily_matchups(boolean) from public, anon, authenticated;
grant execute on function public.generate_daily_matchups(boolean) to service_role;

-- Same omission appears on `20260731130000_sportsbook_auto_settle_daily_matchups.sql:79` for
-- auto_settle_daily_matchups(). That one is ALREADY closed in practice -- its live ACL is
-- `postgres=X | service_role=X`, with no PUBLIC entry -- so it is left alone rather than "fixed"
-- blind. Re-asserting it costs nothing and makes the intent explicit if it is ever recreated.
revoke execute on function public.auto_settle_daily_matchups() from public, anon, authenticated;
grant execute on function public.auto_settle_daily_matchups() to service_role;
