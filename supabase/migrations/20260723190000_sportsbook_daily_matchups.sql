-- Daily sportsbook: auto-generated matchups + 10:20 AM ET betting lock.
-- Applied to project sralgaskfktcynpdxjhj on 2026-07-23 via MCP; recorded here for repo parity.

-- 1) Per-line betting deadline + scheduler extension
alter table public.bet_lines add column if not exists closes_at timestamptz;
create extension if not exists pg_cron;

-- 2) oddsForPair() port: implied-probability odds clamped 1.2..5.0
create or replace function public.odds_for_pair(a numeric, b numeric)
returns table(oa numeric, ob numeric)
language sql immutable
as $$
  select
    case when coalesce(a,0)+coalesce(b,0)=0 then 2.0
         else greatest(1.2, least(5.0, round((1.0/greatest(a/(a+b),0.1))::numeric,1))) end,
    case when coalesce(a,0)+coalesce(b,0)=0 then 2.0
         else greatest(1.2, least(5.0, round((1.0/greatest(b/(a+b),0.1))::numeric,1))) end;
$$;

-- 3) Auto-generate the day's head-to-head matchups.
--    Ranks/prices by trailing-4-week approved commission (today is empty at 8 AM).
--    period='today'; closes_at = today 10:20 America/New_York (DST-aware).
--    Guarded to run only Mon-Fri during the 8 o'clock hour NY time unless p_force.
create or replace function public.generate_daily_matchups(p_force boolean default false)
returns integer
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare
  v_dow int := extract(dow  from (now() at time zone 'America/New_York'))::int;
  v_hour int := extract(hour from (now() at time zone 'America/New_York'))::int;
  v_ny_date date := (now() at time zone 'America/New_York')::date;
  v_close timestamptz;
  v_datelabel text;
  v_created int := 0;
begin
  if not p_force then
    if v_dow = 0 or v_dow = 6 then return 0; end if;  -- weekend, skip
    if v_hour <> 8 then return 0; end if;             -- only the 8 AM NY hour
  end if;

  v_close := ((v_ny_date::text || ' 10:20:00')::timestamp) at time zone 'America/New_York';
  v_datelabel := to_char(v_ny_date, 'Mon FMDD');

  with recent as (
    select agent_id, sum(amount) as total
    from public.commissions
    where status = 'approved' and approved_at >= now() - interval '28 days'
    group by agent_id
  ),
  roster as (
    select a.id, a.name,
           coalesce(r.total,0) as total,
           regexp_split_to_array(btrim(a.name), '\s+') as parts,
           lower(split_part(btrim(a.name),' ',1)) as firstkey
    from public.agents a
    left join recent r on r.agent_id = a.id
  ),
  fnc as (select firstkey, count(*) c from roster group by firstkey),
  ranked as (
    select ro.id, ro.name, ro.total,
           case when f.c > 1 and array_length(ro.parts,1) > 1
                then ro.parts[1] || ' ' || upper(left(ro.parts[array_length(ro.parts,1)],1)) || '.'
                else ro.parts[1] end as shortname,
           row_number() over (order by ro.total desc, ro.name asc) as rn
    from roster ro join fnc f on f.firstkey = ro.firstkey
  ),
  pairs as (
    select x.id a_id, x.name a_name, x.shortname a_short, x.total a_total,
           y.id b_id, y.name b_name, y.shortname b_short, y.total b_total
    from ranked x join ranked y on y.rn = x.rn + 1
    where x.rn % 2 = 1
  )
  insert into public.bet_lines(type,title,description,period,status,created_by,
    agent_a_id,agent_a_name,agent_b_id,agent_b_name,
    odds_a,odds_b,threshold,odds_over,odds_under,odds_yes,odds_no,closes_at)
  select 'head_to_head',
    p.a_short || ' vs ' || p.b_short || ' — ' || v_datelabel,
    'Auto-generated daily matchup — bet on who books more commission today. Book closes 10:20 AM ET.',
    'today','open','Auto (daily)',
    p.a_id,p.a_name,p.b_id,p.b_name,
    o.oa,o.ob,null,2.0,2.0,2.0,2.0,v_close
  from pairs p, lateral public.odds_for_pair(p.a_total,p.b_total) o
  where not exists (
    select 1 from public.bet_lines bl
    where bl.status='open' and bl.type='head_to_head'
      and ((bl.agent_a_id=p.a_id and bl.agent_b_id=p.b_id)
        or (bl.agent_a_id=p.b_id and bl.agent_b_id=p.a_id))
  );

  get diagnostics v_created = row_count;
  return v_created;
end;
$$;

-- 4) Admin-authed manual trigger for the same generator; lock down the raw one.
create or replace function public.admin_generate_daily_matchups(p_username text, p_password text)
returns integer
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
begin
  perform public.assert_admin(p_username, p_password);
  return public.generate_daily_matchups(true);
end;
$$;
revoke execute on function public.generate_daily_matchups(boolean) from anon, authenticated;

-- 5) Enforce the betting deadline in place_bet (added: closes_at check).
create or replace function public.place_bet(p_bettor_type text, p_bettor_id text, p_pin text, p_admin_password text, p_line_id uuid, p_side text, p_amount numeric)
 returns numeric
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $$
declare
  v_coins numeric; v_odds numeric; v_status text; v_max numeric; v_name text; v_closes timestamptz;
begin
  if not public.verify_bettor(p_bettor_type, p_bettor_id, p_pin, p_admin_password) then
    raise exception 'invalid credentials';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'invalid amount'; end if;

  if p_bettor_type = 'agent' then
    select coins, name into v_coins, v_name from public.agents where id::text = p_bettor_id for update;
  else
    select coins, name into v_coins, v_name from public.managers_wallet where username = p_bettor_id for update;
  end if;
  v_coins := coalesce(v_coins, 0);

  select status, closes_at,
    case p_side
      when 'a' then odds_a when 'b' then odds_b
      when 'over' then odds_over when 'under' then odds_under
      when 'yes' then odds_yes when 'no' then odds_no
      else null end
  into v_status, v_closes, v_odds
  from public.bet_lines where id = p_line_id for update;

  if v_status is null then raise exception 'line not found'; end if;
  if v_status <> 'open' then raise exception 'line not open'; end if;
  if v_closes is not null and now() >= v_closes then raise exception 'line closed'; end if;
  if v_odds is null then raise exception 'invalid side'; end if;
  if p_amount > v_coins then raise exception 'insufficient balance'; end if;
  v_max := floor(v_coins * 0.5);
  if p_amount > v_max then raise exception 'exceeds max bet'; end if;

  insert into public.bets(line_id, bettor_type, bettor_id, bettor_name, side, amount, odds_at_bet, status)
    values (p_line_id, p_bettor_type, p_bettor_id, v_name, p_side, p_amount, v_odds, 'pending');

  return public.credit_wallet(p_bettor_type, p_bettor_id, -p_amount);
end;
$$;

-- 6) Schedule: 12:00 & 13:00 UTC Mon-Fri; the function no-ops unless it is the
--    8 o'clock hour in New York, so exactly one run fires at 8 AM under both EDT and EST.
select cron.unschedule('daily-matchups') where exists (select 1 from cron.job where jobname='daily-matchups');
select cron.schedule('daily-matchups','0 12,13 * * 1-5', $$select public.generate_daily_matchups();$$);
