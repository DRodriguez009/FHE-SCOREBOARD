-- An audit trail for every Mike Coins movement.
--
-- Why a trigger and not logging inside credit_wallet(): coins move by two different
-- routes. Betting, settlement, house credit and agent removal all go through
-- credit_wallet(), but admin_approve_commission / admin_bulk_approve_commissions /
-- admin_add_commission write `set coins = coins + 10` directly. Logging inside the helper
-- would have silently missed every commission award — the most common movement there is.
--
-- A trigger on the balance column catches all of it regardless of route, including raw
-- SQL run by an operator. That last case is the one that prompted this: on 2026-08-05 a
-- disputed bet was manually switched from Nelson Santos to Gabriel Tamayo and 1,495 coins
-- were credited, and nothing in the database recorded that it had ever been touched. The
-- only trace was a git commit. For a balance agents argue about, that is not enough.

create table if not exists public.coin_ledger (
  id            bigserial primary key,
  wallet_type   text        not null check (wallet_type in ('agent','manager')),
  wallet_id     text        not null,
  wallet_name   text,
  delta         numeric     not null,
  balance_after numeric     not null,
  reason        text,
  actor         text,
  occurred_at   timestamptz not null default now()
);

create index if not exists coin_ledger_wallet_idx
  on public.coin_ledger (wallet_type, wallet_id, occurred_at desc);
create index if not exists coin_ledger_time_idx
  on public.coin_ledger (occurred_at desc);

-- This is an audit log: it must not be readable through the public API, and nothing
-- should be able to rewrite history. RLS is on with no policies, so even if a grant is
-- added by accident later, no rows are selectable by anon/authenticated.
alter table public.coin_ledger enable row level security;
revoke all on public.coin_ledger from anon, authenticated;
revoke all on sequence public.coin_ledger_id_seq from anon, authenticated;

-- reason/actor are optional context. Any function (or an operator running a manual fix)
-- can set them for the transaction with:
--   set local app.coin_reason = 'manual correction: bet 3b89ba66 side switch';
--   set local app.coin_actor  = 'derrick';
-- When unset they are null, and the delta + timestamp still reconcile against
-- commissions.approved_at and bets.created_at.
create or replace function public.log_coin_change()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
declare
  v_type text;
  v_id   text;
  v_name text;
begin
  if new.coins is not distinct from old.coins then
    return new;
  end if;

  if tg_table_name = 'agents' then
    v_type := 'agent'; v_id := new.id::text; v_name := new.name;
  else
    v_type := 'manager'; v_id := new.username; v_name := new.username;
  end if;

  insert into public.coin_ledger
    (wallet_type, wallet_id, wallet_name, delta, balance_after, reason, actor)
  values
    (v_type, v_id, v_name, new.coins - old.coins, new.coins,
     nullif(current_setting('app.coin_reason', true), ''),
     nullif(current_setting('app.coin_actor',  true), ''));

  return new;
end;
$$;

drop trigger if exists trg_log_coin_change on public.agents;
create trigger trg_log_coin_change
  after update on public.agents
  for each row execute function public.log_coin_change();

drop trigger if exists trg_log_coin_change on public.managers_wallet;
create trigger trg_log_coin_change
  after update on public.managers_wallet
  for each row execute function public.log_coin_change();

-- Admin-only reader. Newest first; p_wallet_id null returns every wallet.
create or replace function public.admin_coin_ledger(
  p_username text, p_password text, p_wallet_id text default null, p_limit integer default 200)
returns table(occurred_at timestamptz, wallet_name text, wallet_id text,
              delta numeric, balance_after numeric, reason text, actor text)
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $$
begin
  perform public.assert_admin(p_username, p_password);
  return query
    select l.occurred_at, l.wallet_name, l.wallet_id, l.delta, l.balance_after, l.reason, l.actor
    from public.coin_ledger l
    where p_wallet_id is null or l.wallet_id = p_wallet_id
    order by l.occurred_at desc, l.id desc
    limit least(coalesce(p_limit, 200), 1000);
end;
$$;

grant execute on function public.admin_coin_ledger(text, text, text, integer)
  to anon, authenticated, service_role;

-- Backfill the one movement we already know is missing, so the ledger does not open with
-- a silent gap. Recorded at the real time of the correction, not at migration time.
insert into public.coin_ledger
  (wallet_type, wallet_id, wallet_name, delta, balance_after, reason, actor, occurred_at)
select 'agent', b.bettor_id, b.bettor_name, 1495,
       (select a.coins from public.agents a where a.id::text = b.bettor_id),
       'Manual correction: bet ' || left(b.id::text, 8) ||
       ' switched from Nelson Santos (side b) to Gabriel Tamayo (side a) and settled as won. '
       'Operator decision, not a proven system fault — see TEST_LOG.md 2026-08-05.',
       'derrick', timestamptz '2026-08-05 20:30:00+00'
from public.bets b
where b.id = '3b89ba66-bd09-49fe-9d8e-bc2bb314403d'
  and not exists (
    select 1 from public.coin_ledger l
    where l.wallet_id = b.bettor_id and l.delta = 1495 and l.reason like 'Manual correction: bet%'
  );
