---
title: Frame identity of the iPhone copies — evidence, 2026-10-26
status: evidence for the owner; nothing uploaded, nothing on the server changed
created: 2026-10-26T22:20:00Z
updated: 2026-10-26T22:20:00Z
decision: D-024; owner direction 2026-10-26 §4
pr: fix/frame-identity-presentation
---

# Frame identity of the iPhone copies (2026-10-26)

**Question.** The phone plays a re-encoded H.264 copy of each recording, not the original. Do the existing copies support frame-accurate annotation?

**Answer.** The current copy encoding (`copyVersion` 3) keeps every frame of the original at its exact presentation time, and the pictures match. This was checked on seven eligible recordings covering H.264 and HEVC, constant and variable frame rate, portrait, a rotated source, a trimmed cut, 4K, and both previously problematic open-GOP HEVC sources. Four further findings matter:

1. **The app's frame-time reading was wrong for any file with an edit list.** That covers iPhone H.264, every B-frame encode and every trimmed cut. It read media times, not the presentation times the player shows and seeks on. Under that reading only 2 of the 7 copies "matched", by coincidence of encoder delay. The fix is the PR this note belongs to. With it, all 7 match.
2. **68 of the 109 Scratch copies on the server still use the older v2 encoding.** By its own record, v2 snapped variable-rate footage to a fixed grid. The commit gate judges each downloaded file on the phone, so a v2 copy that does not match stays playback-only. Remaking them is an upload (§ Correction) and needs the owner's approval. 1 copy predates versioning.
3. **3 of the 7 server copies were proven byte-identical to a regeneration**, because MD5 or multipart ETag and size match. The other 4 regenerated to slightly different bytes: same command, but a different encoder run (threading, or the x264 build). For those 4 the evidence covers the encoding, not the exact server bytes. The phone's gate checks the actual downloaded file in every case.
4. **Open-GOP HEVC leading pictures (D-025)** are present in the copies at the right times. They are frames AVFoundation cannot decode on the Mac, so the Mac shows the previous picture there while the phone shows ffmpeg's decode. About 3–4 frames before each key frame are affected. Events should not be placed on those frames from either device without checking. Their times still match.

## Method (read-only; no download, no upload)

1. **Regenerate.** For each recording, the copy was regenerated from the original on the read-only footage share. The command is exactly `LabelingSync.uploadSmallCopy`'s v3 command: `-an`, scale to 1280, `-fps_mode passthrough -enc_time_base demux`, `libx264 -preset slow -crf 20 -maxrate 5M -bufsize 10M`, `yuv420p`, `+faststart`.
2. **Match the server object without downloading it.** The size and MD5 (or 16 MiB multipart ETag) were compared with `storage.objects` metadata.
3. **Frame times.** These were read with the apps' own `FrameIdentity.allFrameTimes`, compiled verbatim into a small tool, for the original and the copy. They were compared frame by frame, along with count and digest. Both the old media-time reading and the corrected presentation-time reading were run.
4. **Pictures.** Every frame was decoded by ffmpeg, with the original scaled to the copy's size. Per-frame PSNR was computed with frames paired by timestamp.
   - Control on the three short clips: the same comparison with the copy shifted by one frame. In 1,616 of 1,616 frames the true pairing scored higher than the shifted one. PSNR therefore tells neighbouring frames apart, so a match is not just similar content.

## Results

| Recording | Source | Server copy reproduced | Frames orig / copy (presentation) | Digest | PSNR min / median (dB) | Old media-time reading |
|---|---|---|---|---|---|---|
| `bch_sid_sun_port_self_01` | H.264 608×1080 portrait, 30 fps CFR, edit list | **yes** (MD5) | 420 / 420 | **match** | 42.3 / 47.2 (shifted control 23.0) | 419 / 419, match (coincidence) |
| `grs_gnd_sun_land_self_01_v5` | H.264 1280×720, 30 fps CFR | **yes** (ETag) | 9,000 / 9,000 | **match** | 44.0 / 49.4 | match |
| `grs_extra_tester_03_v6` | H.264 1080p, **trimmed cut** (edit at media 2.467 s) | no (different bytes) | 210 / 210 | **match** | 39.5 / 42.4 (shifted 35.0) | 210 / 209, every time off by 1 frame |
| `grs_hnd_sun_land_self_01` | H.264 1080p, **rotated −90°**, VFR | no | 986 / 986 | **match** | 32.4 / 35.8 (shifted 33.2) | 986 / 983, off by 2 frames |
| `ind_sid_dim_land_self_01` | H.264 1080p, 60 fps **VFR** | **yes** (ETag) | 16,877 / 16,877 | **match** | 40.0 / 42.9 | 16,877 / 16,876, off by 1 frame |
| `ind_gnd_bright_port_self_03` | **HEVC** 1080×1920 portrait, 29.97 VFR, **open GOP** (D-025 source) | no | 9,005 / 9,005 | **match** | 41.0 / 43.7 | 9,001 / 9,004, off by up to 3 frames |
| `bch_ele_sun_land_self_01` | **HEVC 4K**, 60 fps VFR, **open GOP** (D-025 source) | no | 17,501 / 17,501 | **match** | 34.9 / 40.5 | 17,496 / 17,500, off by up to 5 frames |

PSNR above 30 dB on every frame of every copy means no frame shows a different picture. The lowest values are on the rotated grass clip, which has heavy texture at 1280 px.

## Consequences

- **The commit gate is correct and stays strict.** A copy may stand for the original only when its presentation-time digest equals the original's. With the corrected reading, v3 copies pass. Copies that do not reproduce the original remain playback-only.
- **The Mac's Review tab** steps and marks on the corrected presentation times too. Before the fix, files with an edit list stepped on media times, which are one or more frames late, and a trimmed cut's frame list covered the wrong stretch. No Stage 1 record exists yet, so nothing recorded under the old reading needs correcting.
- **The L2 labeling path is unaffected.** `TrackLabelModel` keeps its own sampling, unchanged.

## Correction (proposed; nothing done)

The smallest safe delivery change is **none to the encoder**: v3 already keeps frame identity. Two follow-ups, each needing the owner's approval:

1. **Remake the 63 eligible v2 copies as v3.** This uses the existing `remaking` path in `publishVideos`. It is about 6 GB of uploads, replacing existing copies, and is not a new kind of upload. The phone works without it: those recordings are playback-only until remade.
2. **A pre-upload self-check on the Mac** (a separate PR after #100): before uploading a copy, compute its presentation-time digest and upload only when it equals the original's. A copy that cannot reproduce the original's frames would then never reach the phone.
