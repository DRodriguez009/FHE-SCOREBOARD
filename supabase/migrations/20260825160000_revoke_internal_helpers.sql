-- Two internal helpers were left anon-callable, against the convention in
-- reference_fhe_db_function_security: take a credential and validate it, or revoke execute.
--
-- Neither is currently exploitable — assert_admin only raises or returns void and needs a
-- valid session token to do anything, and log_coin_change is a trigger function that errors
-- if called directly. But this is exactly the shape of the 2026-08-17 credit_wallet hole,
-- and the convention exists so nobody has to re-derive that judgement.
--
-- `public` MUST be named: EXECUTE is granted to PUBLIC by default and anon inherits it, so
-- revoking from anon/authenticated alone is a silent no-op. That mistake is why the
-- credit_wallet revoke on 2026-07-31 did nothing for two and a half weeks.
--
-- Safe: SECURITY DEFINER callers run as the owner (postgres), which keeps EXECUTE, and
-- triggers fire in the table owner's context. Neither is referenced by index.html.

revoke execute on function public.assert_admin(text, text)
  from public, anon, authenticated;

revoke execute on function public.log_coin_change()
  from public, anon, authenticated;
