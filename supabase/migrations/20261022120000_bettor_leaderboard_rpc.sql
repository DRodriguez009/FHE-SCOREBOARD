-- A server-side bettor leaderboard, so the sportsbook stops pulling every settled bet.
--
-- loadBettorLeaderboard called get_settled_bets_public -- one row per settled bet, every bet
-- ever -- and summed net coins per bettor in JavaScript. On 2026-10-22 the canary flagged it
-- at 856 rows (16 bettors), heading for PostgREST's 1000-row Max rows. Past the cap the
-- response is silently truncated (HTTP 206, no error), and since the function has no ORDER BY
-- the dropped rows would be arbitrary, so the leaderboard would quietly show wrong totals.
-- Same failure as the 2026-08-05 commission feed.
--
-- The answer is one row per bettor, so compute it here. This wraps get_settled_bets_public
-- rather than re-deriving bettor_name from bets, so the two cannot disagree about who a bettor
-- is or which bets count -- and a call made inside SQL is not subject to the PostgREST cap.
-- The net math is exactly what the browser did: won => payout - amount, otherwise => -amount.
--
-- SECURITY INVOKER on purpose: it runs as anon and can expose nothing get_settled_bets_public
-- does not already expose, so it needs no allowlist entry (fhe_guard_audit reports it as
-- `invoker_open`, for visibility only).

create or replace function public.get_bettor_leaderboard_public()
returns table(bettor_name text, net numeric, bet_count bigint)
language sql
stable
security invoker
set search_path to 'public', 'pg_temp'
as $function$
  select s.bettor_name::text,
         sum(case when s.status = 'won' then s.payout::numeric - s.amount::numeric
                  else -s.amount::numeric end),
         count(*)
  from public.get_settled_bets_public() s
  group by s.bettor_name
  order by 2 desc, 1;
$function$;

-- Public by design, like the function it wraps: the board renders before login.
revoke all on function public.get_bettor_leaderboard_public() from public, anon, authenticated;
grant execute on function public.get_bettor_leaderboard_public() to anon, authenticated;

-- Verify (run after applying; expect ~16 rows, and the sum of bet_count to equal the
-- settled-bet count):
--   select * from public.get_bettor_leaderboard_public();
--   select (select sum(bet_count) from public.get_bettor_leaderboard_public()) as leaderboard_bets,
--          (select count(*) from public.get_settled_bets_public())              as settled_bets;
