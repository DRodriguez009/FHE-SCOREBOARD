-- Public admin name list for the login dropdown (username + display name, no hash).
-- Agent names are already public via get_agents_board(); this adds the admin equivalent.
-- Applied to this app's OWN Supabase project (sralgaskfktcynpdxjhj) on 2026-07-08 via
-- the Supabase MCP; committed for repo/DB parity.

create or replace function public.list_admin_names()
returns table(username text, name text)
language sql security definer set search_path to 'public','extensions'
as $$
  select username, name from public.admins order by name;
$$;

grant execute on function public.list_admin_names() to anon, authenticated;
