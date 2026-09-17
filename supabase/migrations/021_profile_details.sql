-- Volleyball "Player Info" (play types, level, height, handedness, indoor
-- position, Instagram). Kept in a 1:1 side table rather than on profiles
-- because profiles is world-readable by design (search/follow) while this
-- data must honour privacy_level: public -> everyone; followers_only or
-- private -> the owner and their followers only. Absent row = never filled in.
-- Applied to the live project on 2026-09-17 via MCP apply_migration.
CREATE TABLE public.profile_details (
  user_id          text PRIMARY KEY REFERENCES public.profiles(id) ON DELETE CASCADE,
  play_types       text[] NOT NULL DEFAULT '{}'
                   CHECK (play_types <@ ARRAY['grass','beach','indoor']::text[]),
  height_cm        integer CHECK (height_cm BETWEEN 100 AND 250),
  level            text CHECK (level IN ('b','bb','a','aa','aaa','open')),
  handedness       text CHECK (handedness IN ('left','right')),
  indoor_position  text CHECK (indoor_position IN ('outside','opposite','middle','setter','libero')),
  instagram_handle text CHECK (instagram_handle ~ '^[A-Za-z0-9._]{1,30}$'),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.profile_details ENABLE ROW LEVEL SECURITY;

-- Read: owner always; anyone (incl. anon) when the profile is public;
-- followers when it is followers_only or private. Mirrors highlights_select
-- (016) except that 'private' still admits followers, per product decision.
CREATE POLICY "profile_details_select" ON public.profile_details
  FOR SELECT USING (
    user_id = (SELECT auth.uid())::text
    OR EXISTS (
      SELECT 1 FROM public.profiles p
      WHERE p.id = profile_details.user_id
        AND (
          p.privacy_level = 'public'
          OR EXISTS (
            SELECT 1 FROM public.follows f
            WHERE f.follower_id = (SELECT auth.uid())::text
              AND f.following_id = p.id
          )
        )
    )
  );

CREATE POLICY "profile_details_insert" ON public.profile_details
  FOR INSERT TO authenticated
  WITH CHECK (user_id = (SELECT auth.uid())::text);

CREATE POLICY "profile_details_update" ON public.profile_details
  FOR UPDATE TO authenticated
  USING (user_id = (SELECT auth.uid())::text)
  WITH CHECK (user_id = (SELECT auth.uid())::text);
-- No DELETE policy: clearing is done by nulling fields via upsert; account
-- deletion cascades from profiles.

CREATE TRIGGER update_profile_details_updated_at
  BEFORE UPDATE ON public.profile_details
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

NOTIFY pgrst, 'reload schema';
