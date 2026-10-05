-- 025_app_testers.sql
--
-- Who gets the TestFlight tools (Pro override, ball model / ball finder
-- pickers). Replaces the app's receipt-based TestFlight check, which App
-- Review installs pass too — the reviewer got free Pro and the tester UI.
--
-- Rows are added from the dashboard / service role only: there are no
-- insert, update or delete policies. A signed-in user can read only their
-- own row, so the list of testers isn't public.

CREATE TABLE IF NOT EXISTS public.app_testers (
    user_id  text PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
    added_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.app_testers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "app_testers_select_own" ON public.app_testers;
CREATE POLICY "app_testers_select_own" ON public.app_testers
    FOR SELECT TO authenticated
    USING ((SELECT auth.uid())::text = user_id);

-- Signed-out clients have no row to read; keep the table out of their schema.
REVOKE ALL ON public.app_testers FROM anon;
