-- Daily guard audit for THIS project, mirroring the one added to the shared goal-leaderboard
-- database on 2026-08-28 (fhe-command-center/supabase/migrations/20260828130000_guard_audit_cron.sql).
--
-- WHY. That audit covered one of the two production databases. This project holds the money --
-- commissions, bet_lines, and the coin ledger where stake is debited at placement and a settled line
-- can never be re-settled -- and had no coverage at all. The gap was not theoretical: a static check
-- on 2026-08-28 found public.generate_daily_matchups(boolean) anon-callable since 2026-07-23,
-- because its lockdown line revoked from `anon, authenticated` without naming `public`, and anon
-- inherits PUBLIC. Closed in 20260828140000. Nothing would have reported it.
--
-- WHY THIS SHAPE. This project has pg_cron 1.6.4 with jobs running as `postgres`, so the whole thing
-- runs inside the database on a schedule: **no credential is stored anywhere for it**. The
-- alternative was putting this project's service_role key into the command-center's Vercel
-- environment so its existing cron route could audit across projects -- a second copy of a key that
-- bypasses RLS on the money database, to save nothing. pg_cron is strictly better here.
--
-- SCOPE, same as the other one. This is the STATIC check -- who may execute what -- which is exactly
-- what went wrong. It does NOT probe guards behaviourally by calling functions with a wrong
-- credential: on THIS project that would mean invoking betting and coin-ledger RPCs blind, and
-- settlement is irreversible. 33 credential-taking anon-executable functions here remain
-- behaviourally unverified; that needs a human driving it, deliberately, once.
--
-- Alerts are SECURITY DEFINER only. A SECURITY INVOKER function runs AS anon and so can do nothing
-- anon could not already do; those are returned as `invoker_open` for visibility, not alerted.

create extension if not exists pg_net with schema extensions;

-- Config, mirroring public.app_alert_config on the other project. The webhook value is deliberately
-- EMPTY here: it is a secret and must not live in git. Set it out of band -- see APPLY NOTES.
create table if not exists public.app_alert_config (
  key   text primary key,
  value text not null default ''
);
alter table public.app_alert_config enable row level security;  -- RPC-only, no policies
revoke all on public.app_alert_config from public, anon, authenticated;

insert into public.app_alert_config (key, value) values
  ('guard_audit_slack_webhook_url', '')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- The allowlist: functions that are anon-executable ON PURPOSE.
--
-- This is a public scoreboard -- agents see the board and the book before logging in -- so the
-- read-only display functions genuinely cannot take a credential.
--
-- NOTE FOR REVIEW, not a defect: get_commission_stats, get_public_commission_feed and
-- scoreboard_month_commission expose company commission figures to anyone holding this project's
-- publishable key, which ships in index.html. That is a business-sensitivity judgement rather than a
-- bug, and fhe-command-center's /dashboard actively depends on scoreboard_month_commission being
-- anon-callable (src/lib/scoreboard.ts reads it with the anon key). Allowlisted so the audit stays
-- quiet and therefore worth reading -- but if that exposure is not wanted, the fix is a guarded
-- overload plus a service-role read from the hub, not a silent revoke.
-- ---------------------------------------------------------------------------
create or replace function public.fhe_guard_allowlist()
 returns table(fn_key text, reason text)
 language sql
 IMMUTABLE
 set search_path to 'pg_temp'
as $function$
  values
    ('public.list_admin_names/0',          'login dropdown — admin sign-in'),
    ('public.get_agents_board/0',          'public leaderboard — rendered before login'),
    ('public.get_agent_streaks/0',         'public leaderboard — streaks widget'),
    ('public.get_announcement/0',          'public banner — rendered before login'),
    ('public.get_open_lines/0',            'public sportsbook — the open book'),
    ('public.get_settled_bets_public/0',   'public sportsbook — settled results'),
    ('public.get_scoreboard_totals/1',     'public leaderboard — totals'),
    ('public.get_commission_stats/0',      'public commission display — see the review note above'),
    ('public.get_public_commission_feed/0','public commission feed — see the review note above'),
    ('public.scoreboard_month_commission/0','read by fhe-command-center /dashboard with the anon key — see the review note above');
$function$;

revoke all on function public.fhe_guard_allowlist() from public, anon, authenticated;
grant execute on function public.fhe_guard_allowlist() to service_role;

-- ---------------------------------------------------------------------------
-- The audit.
-- ---------------------------------------------------------------------------
create or replace function public.fhe_guard_audit(p_notify boolean default true)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'extensions', 'pg_temp'
as $function$
declare
  v_findings jsonb;
  v_invoker  jsonb;
  v_count    int;
  v_checked  int;
  v_url      text;
  v_text     text;
  v_rec      record;
begin
  with fns as (
    select n.nspname                                        as schema_name,
           p.proname                                        as fn_name,
           pg_get_function_identity_arguments(p.oid)        as args,
           n.nspname || '.' || p.proname || '/' || p.pronargs as fn_key,
           has_function_privilege('anon', p.oid, 'execute') as anon_exec,
           p.prosecdef                                      as sec_def,
           exists (
             select 1 from unnest(coalesce(p.proargnames, '{}'::text[])) a
             where a ~* '^p_(pin|password|token|actor_pin|admin_password|current_pin)$'
           )                                                as has_cred
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prokind = 'f'
      and p.prorettype <> 'trigger'::regtype
  )
  select count(*),
         coalesce(jsonb_agg(jsonb_build_object(
           'fn', f.schema_name || '.' || f.fn_name, 'args', f.args, 'fn_key', f.fn_key)
           order by f.fn_name) filter (
           where f.anon_exec and f.sec_def and not f.has_cred
             and not exists (select 1 from public.fhe_guard_allowlist() al where al.fn_key = f.fn_key)
         ), '[]'::jsonb),
         coalesce(jsonb_agg(f.fn_key order by f.fn_key) filter (
           where f.anon_exec and not f.sec_def and not f.has_cred
         ), '[]'::jsonb)
    into v_checked, v_findings, v_invoker
  from fns f;

  v_count := jsonb_array_length(v_findings);

  if v_count > 0 and p_notify then
    select value into v_url from public.app_alert_config where key = 'guard_audit_slack_webhook_url';
    if v_url is not null and length(btrim(v_url)) > 0 then
      v_text := ':rotating_light: *FHE Scoreboard guard audit: ' || v_count ||
                ' function(s) are anon-executable with no credential argument.*' || chr(10) ||
                'This project holds commissions, bet_lines and the coin ledger. Anyone with its '
                || 'publishable key (it ships in index.html) can call these.' || chr(10);
      for v_rec in select e.value as item from jsonb_array_elements(v_findings) e loop
        v_text := v_text || '• `' || (v_rec.item->>'fn') || '(' ||
                  coalesce(v_rec.item->>'args','') || ')`' || chr(10);
      end loop;
      v_text := v_text || chr(10) ||
                'Fix: `revoke execute on function <fn> from public, anon, authenticated;` — '
                || '**naming `public` is required**, anon inherits PUBLIC. That exact omission left '
                || 'generate_daily_matchups open from 2026-07-23 to 2026-08-28. Or add a guarded '
                || 'overload, or allowlist it in public.fhe_guard_allowlist() with a reason.';

      -- No charset in Content-Type: pg_net rejects `application/json; charset=utf-8`.
      perform net.http_post(
        url     := v_url,
        body    := jsonb_build_object('text', v_text),
        headers := jsonb_build_object('Content-Type', 'application/json')
      );
    end if;
  end if;

  return jsonb_build_object(
    'checked_at',     (now() at time zone 'America/New_York'),
    'functions_seen', v_checked,
    'findings_count', v_count,
    'findings',       v_findings,
    'invoker_open',   v_invoker,
    'notified',       (v_count > 0 and p_notify
                       and v_url is not null and length(btrim(coalesce(v_url,''))) > 0)
  );
exception when others then
  -- Never raise from a scheduled path, but never let a broken audit look like a passing one either.
  return jsonb_build_object('error', sqlerrm, 'findings_count', -1);
end;
$function$;

revoke all on function public.fhe_guard_audit(boolean) from public, anon, authenticated;
grant execute on function public.fhe_guard_audit(boolean) to service_role;

-- APPLY NOTES
--   1) Schedule it (pg_cron jobs here run as `postgres`, so no grant is needed):
--        select cron.schedule('guard-audit-daily', '0 12 * * *',
--                             $$select public.fhe_guard_audit(true);$$);
--      12:00 UTC = 08:00 ET, matching the hub's audit.
--   2) Set the webhook -- a SECRET, never committed:
--        update public.app_alert_config
--           set value = '<slack incoming webhook url>'
--         where key = 'guard_audit_slack_webhook_url';
--   3) Dry run, no Slack post:  select public.fhe_guard_audit(false);
