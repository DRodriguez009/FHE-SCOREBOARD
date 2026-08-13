-- Count a sale on the day it was SUBMITTED, not the day an admin approved it.
--
-- Background: agents submit sales as 'pending'; an admin later approves them. Approval
-- stamped approved_at = now(), and the whole app (board period filter, streaks,
-- personal-best, sportsbook daily settlement) buckets by approved_at. So when an admin
-- bulk-approved yesterday's leftover pending sales this morning, those sales landed on
-- TODAY — e.g. 4 deals submitted the evening of 2026-08-12 jumped onto 2026-08-13 when
-- approved at 10:08am ET.
--
-- Fix: on approval, set approved_at = created_at. created_at is the sale's true day in
-- both paths — for agent submissions it's when the agent logged it, and for admin manual
-- / back-dated entries admin_add_commission already writes created_at = the occurred/
-- back-date. Bucketing by approved_at therefore now means "the day the sale happened",
-- and every downstream consumer is fixed with no query or client change. Back-dating is
-- unaffected (admin_add_commission still sets both columns to the effective date).
--
-- Scope: forward-looking. Historical rows keep their old approved_at; the only ones that
-- differ are sales approved on a different ET day than submitted (rare — most were
-- approved same day), so past totals are effectively unchanged.

create or replace function public.admin_approve_commission(p_username text, p_password text, p_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare v_agent_id uuid;
begin
  perform public.assert_admin(p_username, p_password);
  update public.commissions
    set status = 'approved', approved_at = created_at
    where id = p_id
    returning agent_id into v_agent_id;
  if v_agent_id is not null then
    update public.agents set coins = coins + 10 where id = v_agent_id;
  end if;
end;
$function$;

create or replace function public.admin_bulk_approve_commissions(p_username text, p_password text, p_ids uuid[])
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare v_id uuid; v_agent_id uuid;
begin
  perform public.assert_admin(p_username, p_password);
  foreach v_id in array p_ids loop
    update public.commissions
      set status = 'approved', approved_at = created_at
      where id = v_id
      returning agent_id into v_agent_id;
    if v_agent_id is not null then
      update public.agents set coins = coins + 10 where id = v_agent_id;
    end if;
  end loop;
end;
$function$;
