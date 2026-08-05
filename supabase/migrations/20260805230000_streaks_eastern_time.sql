-- Bucket streak days in Eastern time, not UTC.
--
-- Found on 2026-08-05: Albert Gonzalez's "best day" read $2,490, but $760 of that was a
-- sale approved at 8:20 PM ET on Jun 29 — 00:20 UTC on Jun 30, so UTC bucketing folded it
-- into the following day. His actual best day is Jul 31 at $1,815.
--
-- The team sells into the evening, so every sale approved after 8 PM ET (7 PM in winter)
-- was being counted on the next calendar day. For streaks that means a day nobody sold on
-- could be credited, and a day they did sell on could show a gap.
--
-- Note this function was written earlier today to reproduce the old client-side UTC
-- behaviour exactly, so the numbers would not move underneath anyone during that change.
-- That was the right call then; this is the follow-up that fixes the behaviour itself.
-- Everything else on the board already works in the viewer's local time, which for this
-- office is Eastern — so this brings streaks into line rather than making them different.
create or replace function public.get_agent_streaks()
returns table(agent_id uuid, streak integer)
language sql
stable
security definer
set search_path to 'public', 'extensions'
as $$
  with d as (
    select distinct c.agent_id,
           (c.approved_at at time zone 'America/New_York')::date as sale_day
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
  -- A run still counts if it ended yesterday: "no sale yet today" must not reset a streak
  -- mid-morning. This matches the original client behaviour and is deliberate.
  where last_day >= ((now() at time zone 'America/New_York')::date - 1);
$$;
