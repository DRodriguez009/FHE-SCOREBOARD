-- Stop get_public_commission_feed being a trap, and give the canary an independent
-- source of truth to check the board against.
--
-- The feed no longer has any caller in index.html — the board reads get_scoreboard_totals
-- now. But it is still a public RPC returning every approved commission, which means it
-- still silently truncates at the 1000-row response cap. Left alone, the next person to
-- call it inherits exactly the bug that started all of this, with no error to warn them.
--
-- Bound it explicitly instead. Combined with the DESC sort added earlier, the contract
-- becomes an honest "the most recent 1000 approved commissions" rather than "all of them,
-- except silently not". A caller that needs everything should aggregate server-side or
-- page deliberately.
create or replace function public.get_public_commission_feed()
returns table(agent_id uuid, agent_name text, amount numeric, approved_at timestamptz)
language sql
security definer
set search_path to 'public', 'extensions'
as $$
  select agent_id, agent_name, amount, approved_at
  from public.commissions
  where status = 'approved'
  order by approved_at desc, agent_id, amount
  limit 1000;
$$;

-- A one-row rollup counted straight off the table. Deliberately computed by a different
-- path from get_scoreboard_totals (no join, no grouping) so that comparing the two is a
-- real cross-check rather than a function agreeing with itself.
create or replace function public.get_commission_stats()
returns table(approved_count bigint, approved_total numeric, pending_count bigint)
language sql
stable
security definer
set search_path to 'public', 'extensions'
as $$
  select count(*) filter (where status = 'approved')::bigint,
         coalesce(sum(amount) filter (where status = 'approved'), 0)::numeric,
         count(*) filter (where status = 'pending')::bigint
  from public.commissions;
$$;

grant execute on function public.get_commission_stats() to anon, authenticated, service_role;
