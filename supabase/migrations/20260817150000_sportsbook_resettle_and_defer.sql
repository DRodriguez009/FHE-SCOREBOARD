-- Make a mis-settled sportsbook line correctable, and stop the auto-settler from
-- creating mis-settled lines in the first place.
--
-- What went wrong (2026-08-17, real money — 1,072 coins across two people):
--   The 2026-08-14 line "Albert vs Thomas" auto-settled Monday 07:30 ET as Thomas
--   winning, on commission totals of Albert 220 vs Thomas 365. Albert's Friday total
--   was really 570 — his second Friday deal (350) was still PENDING when the settler
--   ran, and was approved later that morning. Since 20260813160000 approval stamps
--   approved_at = created_at (so a sale counts on the day it was made), that late
--   approval retroactively landed on Friday and changed who should have won a line
--   that was already closed. Every bet on it was on Albert, so seven bets were wrongly
--   marked lost and nobody was paid.
--
--   That fix is right and stays. The bug is that settlement races deal approval:
--   `auto-settle-matchups` runs at 11:30 UTC (07:30 ET) weekdays, i.e. Friday's lines
--   settle Monday morning BEFORE admins work through the weekend's pending queue.
--
--   Worse, nothing could fix it afterwards: settle_bet_line and cancel_bet_line both
--   `raise exception 'line not open'`, and the admin screen only renders settle buttons
--   for open lines. The correction had to be hand-written SQL against production. This
--   is the second time a disputed bet couldn't be settled from the screen (see the
--   2026-08-04 712-coin note in index.html).
--
-- Three changes here:
--   1. sb_resettle_line()          — reverse a settlement and re-apply a new outcome.
--   2. admin_resettle_bet_line()   — admin-authed wrapper; marks the line [manual] so a
--                                    human decision is never overridden by the settler.
--   3. auto_settle_daily_matchups() — DEFERS a day that still has pending sales, and
--                                    SELF-CORRECTS its own recent settlements when a
--                                    late approval changes the verdict. Plus a second
--                                    daily cron run so a deferred day still settles same-day.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. The correction primitive. Server-only: it moves coins with no auth of its own.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.sb_resettle_line(p_line_id uuid, p_winning_side text, p_note text)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare
  v_line record; v_bet record; v_payout numeric;
  v_reversed int := 0; v_won int := 0; v_lost int := 0; v_refunded int := 0;
  v_back numeric := 0; v_out numeric := 0;
  v_neg jsonb;
begin
  select * into v_line from public.bet_lines where id = p_line_id for update;
  if not found then raise exception 'line not found'; end if;
  if v_line.status not in ('settled','cancelled') then
    raise exception 'line is %, not settled — use settle_bet_line or cancel_bet_line', v_line.status;
  end if;
  if p_winning_side is not null and p_winning_side not in ('a','b','over','under','yes','no') then
    raise exception 'invalid winning side: %', p_winning_side;
  end if;

  -- Reverse what the previous settlement paid. A won bet had its gross payout credited;
  -- a refunded bet had its stake returned. A lost bet was paid nothing, so nothing to undo.
  -- Stakes themselves are NOT touched: they were debited at place_bet time and only a
  -- refund returns them.
  for v_bet in select * from public.bets where line_id = p_line_id for update loop
    if v_bet.status = 'won' then
      perform public.credit_wallet(v_bet.bettor_type, v_bet.bettor_id, -coalesce(v_bet.payout, 0));
      v_back := v_back + coalesce(v_bet.payout, 0);
      v_reversed := v_reversed + 1;
    elsif v_bet.status = 'refunded' then
      perform public.credit_wallet(v_bet.bettor_type, v_bet.bettor_id, -v_bet.amount);
      v_back := v_back + v_bet.amount;
      v_reversed := v_reversed + 1;
    end if;
    update public.bets set status = 'pending', payout = null where id = v_bet.id;
  end loop;

  -- Apply the corrected outcome. A null winning side voids the line and refunds stakes,
  -- matching how the settler already handles a commission tie.
  for v_bet in select * from public.bets where line_id = p_line_id for update loop
    if p_winning_side is null then
      perform public.credit_wallet(v_bet.bettor_type, v_bet.bettor_id, v_bet.amount);
      update public.bets set status = 'refunded', payout = 0 where id = v_bet.id;
      v_out := v_out + v_bet.amount; v_refunded := v_refunded + 1;
    elsif v_bet.side = p_winning_side then
      v_payout := round(v_bet.amount * v_bet.odds_at_bet);
      perform public.credit_wallet(v_bet.bettor_type, v_bet.bettor_id, v_payout);
      update public.bets set status = 'won', payout = v_payout where id = v_bet.id;
      v_out := v_out + v_payout; v_won := v_won + 1;
    else
      update public.bets set status = 'lost', payout = 0 where id = v_bet.id;
      v_lost := v_lost + 1;
    end if;
  end loop;

  update public.bet_lines
     set status = case when p_winning_side is null then 'cancelled' else 'settled' end,
         winning_side = p_winning_side,
         settled_at = now(),
         settlement_note = p_note
   where id = p_line_id;

  -- A clawback can leave someone negative if they already spent the winnings. That is
  -- allowed on purpose — refusing would recreate the "line can never be corrected" hole —
  -- but the caller is told, because it blocks that person from betting until they earn back.
  select coalesce(jsonb_agg(jsonb_build_object('wallet', w.name, 'coins', w.coins)), '[]'::jsonb)
    into v_neg
  from (
    select a.name, a.coins from public.agents a
     where a.coins < 0
       and a.id::text in (select bettor_id from public.bets
                           where line_id = p_line_id and bettor_type = 'agent')
    union all
    select m.name, m.coins from public.managers_wallet m
     where m.coins < 0
       and m.username in (select bettor_id from public.bets
                           where line_id = p_line_id and bettor_type <> 'agent')
  ) w;

  return jsonb_build_object(
    'reversed', v_reversed, 'clawed_back', v_back,
    'won', v_won, 'lost', v_lost, 'refunded', v_refunded, 'paid_out', v_out,
    'net_coins', v_out - v_back, 'negative_wallets', v_neg);
end;
$$;

revoke execute on function public.sb_resettle_line(uuid, text, text) from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. Admin-authed correction. Appends [manual] to the note, which permanently opts the
--    line out of auto-correction below — a human verdict outranks the commission math.
-- ─────────────────────────────────────────────────────────────────────────────
create or replace function public.admin_resettle_bet_line(
  p_username text, p_password text, p_line_id uuid,
  p_winning_side text default null, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare v_note text; v_prev text;
begin
  perform public.assert_admin(p_username, p_password);

  -- the coin_ledger trigger reads these, so the clawback/payout rows are attributable
  perform set_config('app.coin_reason',
    'bet correction: ' || coalesce(nullif(btrim(p_reason), ''), 'admin re-settled line'), true);
  perform set_config('app.coin_actor', 'admin:' || p_username, true);

  select settlement_note into v_prev from public.bet_lines where id = p_line_id;
  v_note := left(coalesce(nullif(v_prev, '') || ' | ', '')
    || '[manual] corrected '
    || to_char(now() at time zone 'America/New_York', 'YYYY-MM-DD HH24:MI')
    || ' by ' || p_username
    || ' → ' || coalesce(p_winning_side, 'voided, stakes refunded')
    || coalesce(': ' || nullif(btrim(p_reason), ''), ''), 2000);

  return public.sb_resettle_line(p_line_id, p_winning_side, v_note);
end;
$$;

-- The browser calls this one, so anon needs EXECUTE; assert_admin is the gate. Granting
-- anon explicitly (rather than leaning on the default PUBLIC grant) is what makes the
-- revokes in section 5 safe to write as `from public, anon, authenticated`.
revoke execute on function public.admin_resettle_bet_line(text, text, uuid, text, text)
  from public, authenticated;
grant execute on function public.admin_resettle_bet_line(text, text, uuid, text, text) to anon;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. The settler: defer while sales are still pending, and correct itself afterwards.
-- ─────────────────────────────────────────────────────────────────────────────
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

revoke execute on function public.auto_settle_daily_matchups() from public, anon, authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. Run twice a weekday instead of once. 11:30 UTC (07:30 ET) is before the pending
--    queue is worked, which is what caused this; 20:00 UTC (16:00 ET) catches the same
--    day once approvals are in. Re-running is harmless — phase 1 only looks at open
--    lines from past days, phase 2 no-ops when the verdict already matches.
-- ─────────────────────────────────────────────────────────────────────────────
select cron.unschedule('auto-settle-matchups')
 where exists (select 1 from cron.job where jobname = 'auto-settle-matchups');
select cron.schedule('auto-settle-matchups', '30 11,20 * * 1-5',
  $$select public.auto_settle_daily_matchups();$$);

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. 🔴 UNRELATED CRITICAL HOLE, found while reading the grants above.
--
--    `credit_wallet(type, id, delta)` adds coins to any wallet, takes no credential, and
--    is executable by anon. Verified live from a real anon REST call with the app's
--    publishable key (which ships in index.html): HTTP 200, and it returns the new
--    balance. Agent UUIDs are already public on the board, so ANYONE could mint
--    themselves unlimited coins — or drain a rival's wallet with a negative delta.
--
--    `auto_settle_daily_matchups()` is in the same state: no credential, anon-executable,
--    and it pays out real coins. An attacker could force settlement on demand.
--
--    Why the existing guard missed it: 20260731130000 says
--        revoke execute on function public.auto_settle_daily_matchups() from anon, authenticated;
--    but a new function's EXECUTE is granted to **PUBLIC**, and anon inherits that. The
--    ACL still read `=X/postgres` (PUBLIC) afterwards, so the revoke was a no-op. Any
--    revoke here must name `public` as well — that trap has now cost two projects.
--
--    Nothing legitimate breaks: neither function is referenced anywhere in index.html or
--    scripts/. Every real caller is either a SECURITY DEFINER function (whose internal
--    call runs as the owner, not the caller) or pg_cron (which runs as postgres).
-- ─────────────────────────────────────────────────────────────────────────────
revoke execute on function public.credit_wallet(text, text, numeric)
  from public, anon, authenticated;
revoke execute on function public.read_wallet(text, text)
  from public, anon, authenticated;  -- same shape: internal reader, no credential, unused by the client
revoke execute on function public.auto_settle_daily_matchups()
  from public, anon, authenticated;  -- the 20260731130000 revoke missed PUBLIC

-- Mark the hand-corrected 2026-08-14 line as a manual verdict so phase 2 leaves it be.
update public.bet_lines
   set settlement_note = settlement_note || ' [manual]'
 where id = '42d47458-930d-46fd-afce-28bce0605a28'
   and settlement_note not like '%[manual]%';
