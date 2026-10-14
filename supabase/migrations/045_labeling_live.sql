-- Live sync for labeling: any write to the labeling tables sends a tiny
-- private Realtime broadcast ("changed", topic "labeling") naming the table
-- and who wrote; the phones and the Mac pull at once instead of on their
-- next 30-second look. No row data goes out; only labelers may listen.

CREATE OR REPLACE FUNCTION private.notify_labeling() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
BEGIN
    BEGIN
        PERFORM realtime.send(jsonb_build_object('table', TG_TABLE_NAME, 'by', auth.uid()), 'changed', 'labeling', true);
    EXCEPTION WHEN OTHERS THEN
        -- A notice that can't go out must never stop a save.
        RAISE WARNING 'notify_labeling: %', SQLERRM;
    END;
    RETURN NULL;
END;
$$;
REVOKE ALL ON FUNCTION private.notify_labeling() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER label_tracks_live AFTER INSERT OR UPDATE OR DELETE ON public.label_tracks
    FOR EACH STATEMENT EXECUTE FUNCTION private.notify_labeling();
CREATE TRIGGER label_rally_times_live AFTER INSERT OR UPDATE OR DELETE ON public.label_rally_times
    FOR EACH STATEMENT EXECUTE FUNCTION private.notify_labeling();
CREATE TRIGGER label_videos_live AFTER INSERT OR UPDATE OR DELETE ON public.label_videos
    FOR EACH STATEMENT EXECUTE FUNCTION private.notify_labeling();
CREATE TRIGGER label_project_state_live AFTER INSERT OR UPDATE OR DELETE ON public.label_project_state
    FOR EACH STATEMENT EXECUTE FUNCTION private.notify_labeling();

-- Labelers may receive the "labeling" topic's broadcasts.
CREATE POLICY labeling_live_receive ON realtime.messages FOR SELECT TO authenticated
    USING (realtime.topic() = 'labeling' AND (SELECT private.is_labeler()));
