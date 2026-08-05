-- Pin search_path on the last function that was missing it.
--
-- The 2026-08-01 auth overhaul set an explicit search_path on every function it
-- touched, and the handoff recorded the residual `function_search_path_mutable`
-- advisor warning as "expect confirmation, not discovery" — get_advisors could not
-- be run at the time because the Supabase MCP grant broke mid-migration when the
-- project moved to the FHE org.
--
-- Running it on 2026-08-05 (via `supabase db query --linked`, which uses the CLI's
-- own token and needs no MCP) turned up one genuine miss: public.odds_for_pair,
-- added later by the sportsbook daily-matchups work and never covered by that pass.
--
-- A mutable search_path on a function that is reachable from the API lets a caller
-- who can create objects in an earlier schema shadow an unqualified reference
-- inside the body. odds_for_pair is SECURITY INVOKER and only does arithmetic, so
-- the practical risk here is low — but it is the last one, and leaving it means the
-- advisor never goes quiet, which is how the genuinely important warning gets
-- missed next time.
--
-- Verified after applying: 0 functions in `public` with a null proconfig, and the
-- advisor run drops to 0 findings of this type.

alter function public.odds_for_pair(numeric, numeric)
  set search_path to 'public', 'extensions';
