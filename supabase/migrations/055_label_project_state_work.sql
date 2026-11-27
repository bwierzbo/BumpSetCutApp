-- 055: the work plan's facts (owner, 2026-11-26: "an overhaul of the RallyLab plan tab/overview so I can really track
-- exactly what I need to do on my off time").
--
-- What a person still has to do to each recording (mark its rallies, say its footage type, audit its unmarked
-- time) is worked out the same way on the Mac and the phone (Labeler/Shared/WorkPlan.swift). Two inputs only the
-- project's files on the Mac hold: each recording's camera group (the rally-classifier exporter's grouping) and
-- where its coverage audit stands over every draw. The Mac's sync publishes them with the project's state:
--
--   work = {"published_at": "<ISO 8601>", "recordings": [{"name": "<session name>", "group": "<group id>", "audit": "not_drawn"|"open"|"clean"|"findings"}]}
--
-- (`audit` is left out when the Mac could not read the draws.) Derived, never authoritative: nothing reads it back
-- into the project, and a build from before this migration neither reads nor writes the column (its row encoder
-- leaves it out, and the upsert keeps a column it is not sent). The table's row-level security and grants (030)
-- cover the new column as they cover `plan` and `scores`.

ALTER TABLE public.label_project_state ADD COLUMN IF NOT EXISTS work jsonb;

COMMENT ON COLUMN public.label_project_state.work IS
    'Per recording, its camera group and coverage-audit state as the Mac''s project files say (WorkPlan.Published); derived, null until a Mac build that writes it has synced.';
