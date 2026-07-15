-- 017: Drop broad SELECT policies on public buckets (security audit follow-up).
--
-- Both `videos` and `avatars` are PUBLIC buckets: object serving goes through
-- /storage/v1/object/public/... which bypasses RLS entirely. The SELECT
-- policies below only enabled the storage list/read APIs — letting anon
-- enumerate every object in both buckets. Neither the iOS app nor the webapp
-- calls .list()/.download()/signed URLs on these buckets (iOS uses
-- getPublicURL + upload only; webapp uses the service-role client).

drop policy if exists "videos_select" on storage.objects;
drop policy if exists "Avatars are publicly accessible" on storage.objects;
