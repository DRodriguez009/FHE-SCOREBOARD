-- Make a deferred sportsbook line explain itself, and settle it the moment approvals land.
--
-- What went wrong (2026-08-25, 1,588 coins): the Aug-24 line "Gabriel T. vs Bryan" sat
-- `open` while all seven other Aug-24 lines settled at 07:30 ET. Gabriel Tamayo had 794
-- coins on himself and won the day 745 vs 555 — but his bet showed a bare PENDING badge,
-- with no reason given and no payout.
--
-- Cause: the pending-sales guard added in 20260817150000 is correct and stays. The bug is
-- that it is a bare `continue`. When it fires, nothing is written to the line, nobody is
-- told, and the only retry is the next cron tick — so a line can sit unexplained for
-- hours (by design, up to 2 days).
--
-- It is also nearly undiagnosable after the fact: approval stamps approved_at =
-- created_at (20260813160000), so the sale that was still pending at 07:30 now looks like
-- it was approved on Aug 24 along with the other six. Inspecting the data shows a line
-- that should obviously have settled and no trace of why it didn't.
--
-- Three changes:
--   1. auto_settle_daily_matchups()  — write the reason onto the line it defers.
--   2. get_my_bets()                 — return the line's status and note, so an agent's
--                                      bet history can say why a bet is still pending.
--   3. admin_approve_commission() /
--      admin_bulk_approve_commissions() — run the settler after approving. The approval
--                                      that clears the last pending sale for a day now
--                                      settles that day's deferred lines immediately,
--                                      instead of waiting up to 9h for the next cron.
--      These also now annotate coin movements (app.coin_reason / app.coin_actor), which
--      closes the null-reason gap left open when coin_ledger landed in 20260805210000.


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The settler: say so when deferring.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.auto_settle_daily_matchups()
returns int
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare
  v_today date := (now() at time zone 'America/New_York')::date;
  v_line record;
  v_bet record;
  v_a numeric; v_b numeric; v_win text; v_payout numeric;
  v_pending int;
  v_note text;
  v_settled int := 0;
begin
  -- ── Phase 1: settle days that are complete ──────────────────────────────────
  for v_line in
    select id, agent_a_id, agent_b_id, agent_a_name, agent_b_name,
           (created_at at time zone 'America/New_York')::date as match_day
      from public.bet_lines
     where status = 'open' and type = 'head_to_head'
       and (created_at at time zone 'America/New_York')::date < v_today
     for update
  loop
    -- Don't settle a day whose sales aren't all approved yet: since 20260813160000 a
    -- late approval lands back on the sale's own day and would change the verdict of an
    -- already-closed line. Pending rows have approved_at null, so bucket them by created_at.
    select count(*) into v_pending
      from public.commissions
     where agent_id in (v_line.agent_a_id, v_line.agent_b_id)
       and status = 'pending'
       and (created_at at time zone 'America/New_York')::date = v_line.match_day;

    -- ...but never hold stakes hostage to a queue nobody works: after 2 days, settle on
    -- what is approved. Phase 2 still corrects it if an approval lands later.
    if v_pending > 0 and v_line.match_day > v_today - 3 then
      -- Record WHY. This used to be a bare `continue`, which left the bettor staring at
      -- an unexplained PENDING badge for hours (2026-08-25). Phase 2 cannot pick this
      -- note up by mistake: it requires 'Auto-settled%' AND status in (settled,cancelled),
      -- and a deferred line is still 'open'. The settle and tie branches below overwrite
      -- the note, so it clears itself once the day resolves.
      update public.bet_lines
         set settlement_note = 'Awaiting sale approvals: ' || v_pending
               || case when v_pending = 1 then ' sale' else ' sales' end
               || ' still pending for ' || to_char(v_line.match_day, 'Mon FMDD')
               || ' — settles as soon as they are approved'
       where id = v_line.id;
      continue;
    end if;

    select coalesce(sum(amount), 0) into v_a from public.commissions
     where agent_id = v_line.agent_a_id and status = 'approved'
       and (approved_at at time zone 'America/New_York')::date = v_line.match_day;
    select coalesce(sum(amount), 0) into v_b from public.commissions
     where agent_id = v_line.agent_b_id and status = 'approved'
       and (approved_at at time zone 'America/New_York')::date = v_line.match_day;

    if v_a > v_b then v_win := 'a'; elsif v_b > v_a then v_win := 'b'; else v_win := null; end if;

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

  -- ── Phase 2: re-check what this function settled in the last 3 days ─────────
  -- A sale approved after settlement changes its day's totals retroactively, so the
  -- recorded winner can become wrong with nobody noticing. Only lines this function
  -- settled are eligible: an admin correction carries [manual] and is left alone.
  for v_line in
    select id, agent_a_id, agent_b_id, agent_a_name, agent_b_name, status, winning_side,
           (created_at at time zone 'America/New_York')::date as match_day
      from public.bet_lines
     where type = 'head_to_head'
       and status in ('settled','cancelled')
       and settlement_note like 'Auto-settled%'
       and settlement_note not like '%[manual]%'
       and (created_at at time zone 'America/New_York')::date >= v_today - 3
     for update
  loop
    select coalesce(sum(amount), 0) into v_a from public.commissions
     where agent_id = v_line.agent_a_id and status = 'approved'
       and (approved_at at time zone 'America/New_York')::date = v_line.match_day;
    select coalesce(sum(amount), 0) into v_b from public.commissions
     where agent_id = v_line.agent_b_id and status = 'approved'
       and (approved_at at time zone 'America/New_York')::date = v_line.match_day;

    if v_a > v_b then v_win := 'a'; elsif v_b > v_a then v_win := 'b'; else v_win := null; end if;

    -- Nothing to do when the verdict still matches what is recorded.
    if v_win is not distinct from v_line.winning_side then
      continue;
    end if;

    v_note := 'Auto-settled by commission: '
      || v_line.agent_a_name || ' ' || v_a || ' vs ' || v_line.agent_b_name || ' ' || v_b
      || ' (auto-corrected ' || to_char(now() at time zone 'America/New_York', 'YYYY-MM-DD')
      || ': a late approval changed the result from '
      || coalesce(v_line.winning_side, 'tie/void') || ' to ' || coalesce(v_win, 'tie/void') || ')';

    perform public.sb_resettle_line(v_line.id, v_win, v_note);
    v_settled := v_settled + 1;
  end loop;

  return v_settled;
end;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Bet history: hand the client the line's status and note.
--    Adding columns to the return TABLE needs drop + create, so the grants are
--    re-applied below. anon/authenticated is correct here — the function authenticates
--    the bettor itself via verify_bettor.
-- ─────────────────────────────────────────────────────────────────────────────
drop function if exists public.get_my_bets(text, text, text, text);

create function public.get_my_bets(p_bettor_type text, p_bettor_id text, p_pin text, p_admin_password text)
returns table(
  id uuid, line_id uuid, side text, amount numeric, odds_at_bet numeric,
  status text, payout numeric, created_at timestamptz,
  line_title text, line_type text, agent_a_name text, agent_b_name text, threshold numeric,
  line_status text, line_note text
)
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
begin
  if not public.verify_bettor(p_bettor_type, p_bettor_id, p_pin, p_admin_password) then
    raise exception 'invalid credentials';
  end if;
  return query
    select b.id, b.line_id, b.side, b.amount, b.odds_at_bet, b.status, b.payout, b.created_at,
           bl.title, bl.type, bl.agent_a_name, bl.agent_b_name, bl.threshold,
           bl.status, bl.settlement_note
    from public.bets b
    left join public.bet_lines bl on bl.id = b.line_id
    where b.bettor_id = p_bettor_id
    order by b.created_at desc
    limit 25;
end;
$$;

grant execute on function public.get_my_bets(text, text, text, text)
  to anon, authenticated, service_role;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Approval settles. An approval can be the last pending sale holding a deferred
--    line, and waiting up to 9h for the next cron tick is what made this visible as a
--    bug rather than a delay. Both paths are admin-gated, so this adds no anon surface,
--    and the settlement is atomic with the approval that justified it.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_approve_commission(p_username text, p_password text, p_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare v_agent_id uuid;
begin
  perform public.assert_admin(p_username, p_password);

  update public.commissions
    set status = 'approved', approved_at = created_at
    where id = p_id
    returning agent_id into v_agent_id;

  if v_agent_id is not null then
    -- log_coin_change reads these GUCs; without them the ledger row has a null reason.
    perform set_config('app.coin_reason', 'commission approved (+10)', true);
    perform set_config('app.coin_actor', p_username, true);
    update public.agents set coins = coins + 10 where id = v_agent_id;
  end if;

  perform set_config('app.coin_reason', 'auto-settle after commission approval', true);
  perform set_config('app.coin_actor', p_username, true);
  perform public.auto_settle_daily_matchups();
end;
$$;

create or replace function public.admin_bulk_approve_commissions(p_username text, p_password text, p_ids uuid[])
returns void
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare v_id uuid; v_agent_id uuid;
begin
  perform public.assert_admin(p_username, p_password);

  perform set_config('app.coin_reason', 'commission approved in bulk (+10)', true);
  perform set_config('app.coin_actor', p_username, true);

  foreach v_id in array p_ids loop
    update public.commissions
      set status = 'approved', approved_at = created_at
      where id = v_id
      returning agent_id into v_agent_id;
    if v_agent_id is not null then
      update public.agents set coins = coins + 10 where id = v_agent_id;
    end if;
  end loop;

  -- Once, after the whole batch — not per row.
  perform set_config('app.coin_reason', 'auto-settle after bulk commission approval', true);
  perform set_config('app.coin_actor', p_username, true);
  perform public.auto_settle_daily_matchups();
end;
$$;
