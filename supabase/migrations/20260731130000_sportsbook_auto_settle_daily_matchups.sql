-- Auto-settle daily head-to-head matchups by approved commission.
-- Applied to project sralgaskfktcynpdxjhj on 2026-07-31 via MCP; recorded here for repo parity.
--
-- WHY: the daily switch (20260723190000) auto-GENERATES + locks matchups but never
-- SETTLED them — settlement was manual and no manager ever did it, so 13 bets sat
-- 'pending' (coins debited at bet time, never resolved) across Jul 24-30. Winning
-- bettors were effectively unpaid. This adds automatic settlement.
--
-- Winner = agent with higher approved commission on the matchup day, using the SAME
-- metric the scoreboard 'Today' view uses (status='approved', bucketed by approved_at
-- NY calendar date). Tie => refund all pending bets + cancel the line. Idempotent:
-- only touches lines still 'open' whose matchup day is fully over, so it is safe to
-- call any number of times and self-heals missed days.

create or replace function public.auto_settle_daily_matchups()
returns integer
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare
  v_today date := (now() at time zone 'America/New_York')::date;
  v_line record;
  v_bet record;
  v_a numeric; v_b numeric; v_win text; v_payout numeric;
  v_settled int := 0;
begin
  for v_line in
    select id, agent_a_id, agent_b_id, agent_a_name, agent_b_name,
           (created_at at time zone 'America/New_York')::date as match_day
    from public.bet_lines
    where status = 'open' and type = 'head_to_head'
      and (created_at at time zone 'America/New_York')::date < v_today
    for update
  loop
    select coalesce(sum(amount),0) into v_a from public.commissions
      where agent_id = v_line.agent_a_id and status = 'approved'
        and (approved_at at time zone 'America/New_York')::date = v_line.match_day;
    select coalesce(sum(amount),0) into v_b from public.commissions
      where agent_id = v_line.agent_b_id and status = 'approved'
        and (approved_at at time zone 'America/New_York')::date = v_line.match_day;

    if v_a > v_b then v_win := 'a';
    elsif v_b > v_a then v_win := 'b';
    else v_win := null;  -- tie
    end if;

    if v_win is null then
      for v_bet in select * from public.bets where line_id = v_line.id and status = 'pending' for update loop
        update public.bets set status = 'refunded', payout = 0 where id = v_bet.id;
        perform public.credit_wallet(v_bet.bettor_type, v_bet.bettor_id, v_bet.amount);
      end loop;
      update public.bet_lines
        set status = 'cancelled', settled_at = now(),
            settlement_note = 'Auto-settled: commission tie (' || v_a || ' vs ' || v_b || ') — all bets refunded'
        where id = v_line.id;
    else
      for v_bet in select * from public.bets where line_id = v_line.id and status = 'pending' for update loop
        if v_bet.side = v_win then
          v_payout := round(v_bet.amount * v_bet.odds_at_bet);
          update public.bets set status = 'won', payout = v_payout where id = v_bet.id;
          perform public.credit_wallet(v_bet.bettor_type, v_bet.bettor_id, v_payout);
        else
          update public.bets set status = 'lost', payout = 0 where id = v_bet.id;
        end if;
      end loop;
      update public.bet_lines
        set status = 'settled', winning_side = v_win, settled_at = now(),
            settlement_note = 'Auto-settled by commission: '
              || v_line.agent_a_name || ' ' || v_a || ' vs ' || v_line.agent_b_name || ' ' || v_b
        where id = v_line.id;
    end if;
    v_settled := v_settled + 1;
  end loop;
  return v_settled;
end;
$$;

revoke execute on function public.auto_settle_daily_matchups() from anon, authenticated;

-- Admin-authed manual trigger (parity with admin_generate_daily_matchups).
create or replace function public.admin_auto_settle_daily_matchups(p_username text, p_password text)
returns integer
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
begin
  perform public.assert_admin(p_username, p_password);
  return public.auto_settle_daily_matchups();
end;
$$;

-- Schedule: weekday mornings before the 8 AM generation run. 11:30 UTC is 6:30/7:30 AM
-- New York (EST/EDT) — always after midnight (prior day complete) and before matchup
-- generation (12:00/13:00 UTC).
select cron.unschedule('auto-settle-matchups') where exists (select 1 from cron.job where jobname = 'auto-settle-matchups');
select cron.schedule('auto-settle-matchups', '30 11 * * 1-5', $$select public.auto_settle_daily_matchups();$$);
