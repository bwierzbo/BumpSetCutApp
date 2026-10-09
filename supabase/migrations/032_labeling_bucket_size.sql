-- 032_labeling_bucket_size.sql
--
-- Phone copies in the labeling bucket are now encoded to a quality rather
-- than a fixed 2 Mbps (grainy indoor footage fell apart at 2 Mbps a few
-- seconds in), so a 5-minute copy can run past 100 MB. Room for 250 MB.

UPDATE storage.buckets SET file_size_limit = 262144000 WHERE id = 'labeling';
