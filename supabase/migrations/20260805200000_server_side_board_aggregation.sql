-- Move the scoreboard's arithmetic into the database, and stop the board depending on
-- the client receiving EVERY approved commission row.
--
-- Background: PostgREST truncates any response at the project's Max rows (1000) with an
-- HTTP 206 rather than an error. get_public_commission_feed crossed that on 2026-08-05
-- (1018 rows) and the board silently stopped counting the overflow. The client-side fix
-- (rpcAll pagination) restored correctness, but the board was still shipping ~1000 rows
-- to every wall TV every 30 seconds in order to compute five numbers.

-- 1) Deterministic ordering on the feed.
--    The function had no ORDER BY, so Postgres returned heap order. Approving a
--    commission is an UPDATE, which relocates the tuple to the end of the heap — so the
--    rows past the truncation point were precisely the newest approvals. That is what
--    made the bug present as "approved deals never appear". With an explicit DESC sort,
--    a truncated response now loses the OLDEST rows, which is the survivable direction.
create or replace function public.get_public_commission_feed()
returns table(agent_id uuid, agent_name text, amount numeric, approved_at timestamptz)
language sql
security definer
set search_path to 'public', 'extensions'
as $$
  select agent_id, agent_name, amount, approved_at
  from public.commissions
  where status = 'approved'
  order by approved_at desc, agent_id, amount;
$$;

-- 2) Per-agent totals for a period. p_since null = all time.
--    Returns one row per agent (~18) instead of one row per sale (~1024).
--    Prefers the canonical agents.name but falls back to the denormalized
--    commissions.agent_name, matching how the client already tolerated names that are
--    not on the current roster.
create or replace function public.get_scoreboard_totals(p_since timestamptz default null)
returns table(agent_id uuid, agent_name text, total numeric, sale_count bigint)
language sql
stable
security definer
set search_path to 'public', 'extensions'
as $$
  select c.agent_id,
         coalesce(a.name, c.agent_name) as agent_name,
         sum(c.amount)::numeric        as total,
         count(*)::bigint              as sale_count
  from public.commissions c
  left join public.agents a on a.id = c.agent_id
  where c.status = 'approved'
    and c.approved_at is not null
    and (p_since is null or c.approved_at >= p_since)
  group by c.agent_id, coalesce(a.name, c.agent_name);
$$;

grant execute on function public.get_scoreboard_totals(timestamptz)
  to anon, authenticated, service_role;

-- 3) Streaks, computed by gaps-and-islands instead of by shipping every row to the
--    browser. Deliberately reproduces the old client semantics in calcStreak(): UTC
--    dates, and a run still counts if it ends YESTERDAY (the old loop only broke on a
--    missing day when i > 0, so "no sale yet today" did not reset the streak).
create or replace function public.get_agent_streaks()
returns table(agent_id uuid, streak integer)
language sql
stable
security definer
set search_path to 'public', 'extensions'
as $$
  with d as (
    select distinct c.agent_id,
           (c.approved_at at time zone 'UTC')::date as sale_day
    from public.commissions c
    where c.status = 'approved' and c.approved_at is not null
  ),
  g as (
    select agent_id, sale_day,
           sale_day - (row_number() over (partition by agent_id order by sale_day))::integer as grp
    from d
  ),
  runs as (
    select agent_id, max(sale_day) as last_day, count(*)::integer as len
    from g
    group by agent_id, grp
  )
  select agent_id, len
  from runs
  where last_day >= ((now() at time zone 'UTC')::date - 1);
$$;

grant execute on function public.get_agent_streaks()
  to anon, authenticated, service_role;

-- 4) Bet history could not name the side it was betting on.
--    The UI rendered a bare "Side: B" next to the line's FREE-TEXT title, leaving the
--    bettor to infer that B meant the second name in that title. For auto-generated
--    matchups that inference happens to hold; for admin-created lines the title is typed
--    by hand and is independent of the agent A/B dropdowns, so it can be exactly
--    backwards. This produced a real dispute over a 712-coin bet on 2026-08-04 that
--    could not be settled by reading the screen.
--    Return the agent names so the client can print who the side actually is, and derive
--    the matchup label from the agent columns rather than the title.
--    Return type changes, so this needs DROP + CREATE; grants are reapplied below.
drop function if exists public.get_my_bets(text, text, text, text);

create function public.get_my_bets(p_bettor_type text, p_bettor_id text, p_pin text, p_admin_password text)
returns table(id uuid, line_id uuid, side text, amount numeric, odds_at_bet numeric,
              status text, payout numeric, created_at timestamptz,
              line_title text, line_type text,
              agent_a_name text, agent_b_name text, threshold numeric)
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
begin
  if not public.verify_bettor(p_bettor_type, p_bettor_id, p_pin, p_admin_password) then
    raise exception 'invalid credentials';
  end if;
  return query
    select b.id, b.line_id, b.side, b.amount, b.odds_at_bet, b.status, b.payout, b.created_at,
           bl.title, bl.type, bl.agent_a_name, bl.agent_b_name, bl.threshold
    from public.bets b
    left join public.bet_lines bl on bl.id = b.line_id
    where b.bettor_id = p_bettor_id
    order by b.created_at desc
    limit 25;
end;
$$;

grant execute on function public.get_my_bets(text, text, text, text)
  to anon, authenticated, service_role;
