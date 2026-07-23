-- Bugfix: admin_remove_agent failed with a foreign-key violation whenever the
-- agent appeared in any bet_lines row. The bet_lines FKs (agent_a_id/agent_b_id)
-- are NO ACTION, and the old function did a bare `delete from agents`.
-- Fix: refund + cancel the agent's OPEN lines, then null the FK ids on their
-- historical (settled/cancelled) lines -- agent names are stored as text so the
-- history stays readable -- then delete (commissions cascade via their own FK).
-- Applied to sralgaskfktcynpdxjhj on 2026-07-23 via MCP; recorded here for parity.
create or replace function public.admin_remove_agent(p_username text, p_password text, p_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public','extensions'
as $$
declare v_bet record;
begin
  perform public.assert_admin(p_username, p_password);

  for v_bet in
    select b.* from public.bets b
    join public.bet_lines l on l.id = b.line_id
    where b.status='pending' and l.status='open'
      and (l.agent_a_id = p_id or l.agent_b_id = p_id)
    for update
  loop
    perform public.credit_wallet(v_bet.bettor_type, v_bet.bettor_id, v_bet.amount);
    update public.bets set status='refunded' where id = v_bet.id;
  end loop;
  update public.bet_lines set status='cancelled'
    where status='open' and (agent_a_id = p_id or agent_b_id = p_id);

  update public.bet_lines set agent_a_id = null where agent_a_id = p_id;
  update public.bet_lines set agent_b_id = null where agent_b_id = p_id;

  delete from public.agents where id = p_id;
end;
$$;
