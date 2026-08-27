-- A pending-count RPC, so the admin badge stops paying for the whole commissions table.
--
-- The admin panel refreshed its "Pending" pill every 60 seconds by calling
-- get_all_commissions_admin -- SETOF commissions, every row, every column, paged 1000 at a
-- time by rpcAll -- and then counting `status = 'pending'` in JavaScript. Same class of waste
-- as the update-check fetching 141KB to read one version string: the answer is one integer.
--
-- Guard is `assert_admin`, identical to every other admin_/get_*_admin function here.
-- p_password carries a session TOKEN, not a password (see the 2026-08-01 token migration) --
-- the parameter names are load-bearing for PostgREST and cannot be renamed in place.

create or replace function public.get_pending_count_admin(p_username text, p_password text)
returns integer
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_count integer;
begin
  perform public.assert_admin(p_username, p_password);
  select count(*) into v_count from public.commissions where status = 'pending';
  return v_count;
end;
$function$;

-- Naming `public` is NOT optional: PUBLIC holds EXECUTE by default and anon inherits it, so
-- revoking from anon alone is a silent no-op. The credentialled signature is then granted back,
-- exactly as the other admin functions are -- assert_admin is what actually protects it.
revoke all on function public.get_pending_count_admin(text, text) from public, anon, authenticated;
grant execute on function public.get_pending_count_admin(text, text) to anon, authenticated;
