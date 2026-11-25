#!/bin/zsh
# 054: two first saves of one recording at the same moment (the Mac and the phone, both on revision 0). The second
# waits for the first and is refused as a conflict — never written over it. Called by run_048_tests.sh with `psqla`'s
# connection settings: $1 = psql binary, $2 = socket dir, $3 = port, $4 = database.
set -euo pipefail
p=($1 -h $2 -p $3 -U postgres -d $4 -v ON_ERROR_STOP=1 -qAt)
body='{"schemaVersion":"coverage_audit_draw_v2","drawId":"dc","dataset":{"name":"rc-test","timescale":600},"recordings":[{"recordingId":"c","groupId":"g","contentFingerprint":"file:c","marksSha256":"m0","durationTicks":600,"intervals":[{"index":0,"startTick":0,"endTick":600}],"repeatIndices":[]}]}'
$p <<SQL
INSERT INTO public.label_videos (id, project, session_name, source_fingerprint) VALUES ('10000000-0000-0000-0000-0000000000cc', 'Scratch', 'c', 'file:c');
SET ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
SELECT public.coverage_audit_publish_draw('Scratch', '$body') IS NOT NULL;
SELECT public.coverage_audit_publish_recordings('Scratch', 'dc', '[{"recordingId":"c","videoId":"10000000-0000-0000-0000-0000000000cc","sourceFingerprint":"file:c","marksSha256":"m1","openIndices":[0]}]');
SQL
sha=$($p -c "SELECT draw_sha256 FROM public.label_coverage_audit_draws WHERE draw_id = 'dc'")
rec() { echo "{\"annotationVersion\":\"coverage_audit_v2\",\"recordingId\":\"c\",\"sourceFingerprint\":\"file:c\",\"drawId\":\"dc\",\"drawSha256\":\"$sha\",\"datasetName\":\"rc-test\",\"marksSha256\":\"m1\",\"timescale\":600,\"blindToPipeline\":true,\"tool\":\"$1\",\"intervals\":[{\"index\":0,\"startTick\":0,\"endTick\":600,\"verdict\":\"clean\",\"playedAllAtMaxRate\":2,\"findings\":[],\"reviewedAt\":\"2026-11-17T10:00:00Z\",\"reviewer\":\"00000000-0000-0000-0000-00000000000a\"}],\"resolutions\":[]}"; }
save() { echo "BEGIN; SET ROLE authenticated; SELECT set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', true);
             SELECT revision FROM public.coverage_audit_save('Scratch', 'dc', 'c', 0, '$(rec $1)'); SELECT pg_sleep($2); COMMIT;"; }
out=$(mktemp -d)
(save mac 1.5 | $p > $out/mac 2>&1; echo $? > $out/mac.rc) &
sleep 0.4
(save phone 0 | $p > $out/phone 2>&1; echo $? > $out/phone.rc) &
wait
[[ $(cat $out/mac.rc) == 0 ]] || { echo "FAIL: the first save failed: $(cat $out/mac)"; exit 1; }
grep -q 'conflict:' $out/phone || { echo "FAIL: the concurrent first save was not a conflict: $(cat $out/phone)"; exit 1; }
[[ $($p -c "SELECT record->>'tool' || ' r' || revision FROM public.label_coverage_audits WHERE draw_id = 'dc'") == 'mac r1' ]] || { echo "FAIL: the first save was overwritten"; exit 1; }
rm -rf $out
echo 'ALL 054 CONCURRENCY TESTS PASSED'
