-- 024_push.sql
--
-- APNs push for direct messages. Already applied to the live project; this
-- file is the committed record of that DDL.
--
-- The trigger reads its target URL and shared secret from Vault, so the
-- webhook can be pointed at a new deployment (or disabled outright) without
-- a migration, and neither value is ever committed. With either secret
-- missing the trigger is a no-op — inserts still succeed, they just don't
-- push, which is what a fresh branch or local stack should do.
--
-- One-time, NOT part of this migration (run once per environment):
--   select vault.create_secret('<random >=32 bytes>', 'push_webhook_secret');
--   select vault.create_secret(
--     'https://<project-ref>.supabase.co/functions/v1/push-message',
--     'push_message_url');

CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- ---------------------------------------------------------------- tokens ---

CREATE TABLE IF NOT EXISTS public.device_tokens (
    token       text PRIMARY KEY,
    user_id     text NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    environment text NOT NULL CHECK (environment IN ('production', 'sandbox')),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_device_tokens_user_id ON public.device_tokens(user_id);

ALTER TABLE public.device_tokens ENABLE ROW LEVEL SECURITY;

-- Read and revoke your own only. Registration goes through the RPC below so
-- a client can't claim a token for another account.
CREATE POLICY "device_tokens_select_own" ON public.device_tokens
    FOR SELECT TO authenticated
    USING (user_id = (SELECT auth.uid())::text);

CREATE POLICY "device_tokens_delete_own" ON public.device_tokens
    FOR DELETE TO authenticated
    USING (user_id = (SELECT auth.uid())::text);

-- ON CONFLICT reassigns rather than rejects: the same device token follows
-- whichever account last signed in on that phone.
CREATE OR REPLACE FUNCTION public.register_device_token(p_token text, p_environment text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE uid text := (SELECT auth.uid())::text;
BEGIN
    IF uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
    IF p_token IS NULL OR p_token !~ '^[0-9a-f]{32,}$' THEN RAISE EXCEPTION 'invalid token'; END IF;
    IF p_environment NOT IN ('production', 'sandbox') THEN RAISE EXCEPTION 'invalid environment'; END IF;

    INSERT INTO device_tokens (token, user_id, environment)
    VALUES (p_token, uid, p_environment)
    ON CONFLICT (token) DO UPDATE
        SET user_id = EXCLUDED.user_id,
            environment = EXCLUDED.environment,
            updated_at = now();
END $$;

REVOKE ALL ON FUNCTION public.register_device_token(text, text) FROM anon, public;
GRANT EXECUTE ON FUNCTION public.register_device_token(text, text) TO authenticated;

-- --------------------------------------------------------------- webhook ---

CREATE OR REPLACE FUNCTION public.push_on_message()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE secret text; fn_url text;
BEGIN
    SELECT decrypted_secret INTO secret FROM vault.decrypted_secrets WHERE name = 'push_webhook_secret';
    SELECT decrypted_secret INTO fn_url FROM vault.decrypted_secrets WHERE name = 'push_message_url';
    -- Unconfigured environment: insert the message, skip the push.
    IF secret IS NULL OR fn_url IS NULL THEN RETURN NEW; END IF;

    PERFORM net.http_post(
        url := fn_url,
        headers := jsonb_build_object('Content-Type', 'application/json',
                                      'Authorization', 'Bearer ' || secret),
        body := jsonb_build_object('type', 'INSERT', 'table', 'messages', 'record', to_jsonb(NEW)),
        timeout_milliseconds := 5000);
    RETURN NEW;
END $$;

REVOKE ALL ON FUNCTION public.push_on_message() FROM anon, authenticated, public;

DROP TRIGGER IF EXISTS trg_push_on_message ON public.messages;
CREATE TRIGGER trg_push_on_message
    AFTER INSERT ON public.messages
    FOR EACH ROW EXECUTE FUNCTION public.push_on_message();

NOTIFY pgrst, 'reload schema';
