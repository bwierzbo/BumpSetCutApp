---
name: yolo-dependency-inventory
status: active
created: 2026-11-25T01:52:01Z
updated: 2026-11-25T01:52:01Z
---

# YOLO and net-detector dependency inventory, and what the removal changed

Made for [D-042](../decisions/DECISION_LOG.md#d-042) (owner authorisation 2026-11-24, §4 and §5) from `main` at `bd25d95b`, before any change; the right-hand columns say what the removal PR did with each dependency. "YOLO-derived" means the Ultralytics-derived packages `ball_v2_small`, `bestv2`, `bestv3`, `ball_rallylab_960`, `ball_rallylab_1280` and `net`. `ball_heat` (the multi-frame heatmap model, trained from scratch) is not one.

Three targets matter. **BumpSetCut** is the iOS app. **Labeler** is RallyLab on the iPhone, distributed through TestFlight. **RallyLab** is the Mac research tool; it does not ship.

## 1. What each target carried

| | BumpSetCut (iOS) | Labeler (iOS) | RallyLab (macOS) |
|---|---|---|---|
| Detector code compiled before | `YOLODetector`, `YOLORawDecode`, `NetDetector`, `BallNetSampler` | the same four | the same four |
| YOLO-derived packages bundled before | all six | `ball_v2_small`, `net` | all six |
| Detector code compiled now | none | none | the four, in `RallyLab/LegacyDetectors/` |
| YOLO-derived packages bundled now | none | none | all six |
| `ball_heat` | bundled, before and now | bundled, before and now | bundled, before and now |

Checked on built apps with `scripts/check_shipping_build.sh` (models in the bundle, and the detectors' symbols in the code, with a control that the symbols were readable).

## 2. Active dependencies in what ships, and what became of each

| # | Where (at `bd25d95b`) | What it did | Active? | Now |
|---|---|---|---|---|
| 1 | `VideoProcessor.swift:51/53` | Built a `YOLODetector` for every processor, whatever the configuration | Yes: the model loaded on every run, though heat-only runs never asked it for a frame | The processor holds no detector. A configuration that asks for a single-frame one gets it from the build (`PipelineDefaults`); the apps that ship have none. |
| 2 | `VideoProcessor.swift:707, 994` | `heatAlone = heatmapOnly && heatDetector != nil`: if `ball_heat` failed to load, YOLO ran on every frame with no error | Yes: a silent fallback | A heat-only run whose model is missing or won't load throws `ProcessingError.modelNotFound` ("AI model not found. Please reinstall the app."), in every target. |
| 3 | `VideoProcessor.swift:524–528, 598–606, 1432–1456` | Ran the net detector on 8 frames before the first frame of every run with a net rule on (all three are on by default, for every camera position) | Yes: every default run, in the app and the Labeler | The net comes from a named source (`NetGeometrySource`). The app's is the video's person-confirmed calibration; the Labeler has none; RallyLab's is the old detector, unchanged. |
| 4 | `VideoProcessor.swift:324–480` (`processVideoDebug`) | The app's "Debug Processing" video: its own loop over YOLO alone, every third frame — not the pipeline that cuts rallies | Yes, behind Debug Features | The debug video is the pipeline's own run (multi-frame model, same tracker, rules and decision), drawn from its evidence in a second pass. A video with no rally is still drawn. |
| 5 | `SettingsView.swift:316, 321, 360, 365`; `SettingsComponents.swift:120–145` | Ball Model and Ball Finder pickers (YOLO, YOLO + multi-frame, multi-frame only; three YOLO models) | Yes, behind Debug Features and for testers | Removed, with `BallFinder`. A stored `debugBallFinder` value is read by nothing. |
| 6 | `Detections.swift:140, 144` | The configuration's ball finder defaulted from that stored debug choice | Yes | The default is the bundled multi-frame model alone, unconditionally. |
| 7 | `Labeler/Tracking/TrackSession.swift:260–269, 291–294` | Assisted tracking: YOLO candidates on every frame, merged with the multi-frame model's peaks | Yes | The multi-frame model's peaks are the candidates. |
| 8 | `Labeler/Tracking/TrackSession.swift:492–506`; `Labeler/Shared/TrackFinder.swift:113–121` | "Look again" near a fix: the multi-frame model at a low threshold, then YOLO on zoomed crops | Yes | The multi-frame search only. The Mac passes its detector for the crops; the iPhone has none. |
| 9 | `Labeler/Views/PipelineRunView.swift:172–183` | Ran the shared pipeline: net detector by default, YOLO constructed | Yes | Runs with no net (the Labeler names no source): the net rules are skipped and the run says so. |
| 10 | `project.pbxproj` | The app target had no resource exceptions, so it bundled all six packages; the Labeler's list named two | Yes | The six are excluded from the app target and the two removed from the Labeler's list. |

Not active in what ships, before or now: `DeterministicRallyEngine` (its only callers are RallyLab's FSM tab and `DeterministicPipeline`), and `ProcessingMetadata.netCenterX` (written, read by nothing).

## 3. What stays, and why

| What | Where | Why it stays |
|---|---|---|
| `YOLODetector`, `YOLORawDecode`, `NetDetector`, `BallNetSampler`, the six packages | RallyLab only (`RallyLab/LegacyDetectors/`, RallyLab's memberships) | RallyLab's pre-labeling, click-to-box, model evaluation, Net tab and net-label proposals use them directly; stored evaluations and baselines were made with them. Research, not shipped. |
| The old net detector as the pipeline's net | RallyLab only (`LegacyNetDetectorSource`, the sampling moved as it was) | The rally-classifier dataset depends on it: the feature `y_above_net`, each recording's `net` record, the `r0` / `r0_prime` baselines (the above-net rule), and indirectly every tracker feature, through off-court and under-net rejection. RallyLab's runs must give what they gave. |
| `ProcessorConfig.ballModel`, `heatmapOnly`, the three net-rule flags, and the `BallModel` names | shared code, every target | A configuration's identity is a reflection over every stored field (`canonicalSHA256`, `ProcessingCheckpoint.hash`): removing or renaming one changes the hash for the same settings — the classifier dataset's `configSha256`, the scoring ledger's references, the tuner's cache keys. In the apps that ship `ballModel` is a name nothing loads. |
| The word "YOLO" in a log line and in local names (`yoloDets`, the timing line) | `VideoProcessor.swift` | The research path through the shared loop. No model behind it in a shipping build. |

## 4. The net rules without the detector

The three rules read one box for the whole run. The rule code is unchanged; what changed is where the box comes from, and that its absence is recorded.

| | Before | Now, the app | Now, the Labeler | RallyLab |
|---|---|---|---|---|
| Net for a run | the detector's median box, when it found a net | the box round the four corners a person confirmed for that video, when one confirmed net covers the whole video | none | as before |
| Under-net rejection (a path that never rises above the net's bottom is not a rally) | ran when a net was found | runs on the confirmed net; otherwise skipped | skipped | as before |
| Off-court rejection (a ball beyond the posts is another court's) | ran when a net was found, end-line camera | runs on the confirmed net; otherwise skipped | skipped | as before |
| Above-net requirement (a multi-contact rally must clear the net's top once) | ran when a net was found | runs on the confirmed net; otherwise skipped | skipped | as before |
| Recorded | `netCenterX` only | `spatialChecks` in the metadata: the net's origin (`person_confirmed`, a method's name, `unavailable` with its reason) and each rule as `ran`, `off` or `no_net_geometry`; one log line naming the skipped rules; a line on the video's screen before the run | the same record and log line | the same record, origin `legacy_net_detector` |

No net is never read as "in the court" or "above the net": a rule with no net does nothing, as it did when the detector found none, and now says so. No net position is made up. A confirmed net is used only for the file it was confirmed on (a stale calibration is no net), only when the video is one stable camera view, and only by a run that detects in the upright frame the calibration is in.

**This is a degradation for a video with no confirmed net**: balls on a neighbouring court can form tracks, a ball rolled under the net can pass the physics gate, and a background rally that never clears the net is kept. It is what already happened on any video where the detector found no net.

**Not verified:** how rally output with a person's box compares with the detector's box on the same recordings. The rules are the same code given a box in the same space (checked by unit test: the box is the corners' bounds, upright, Vision-normalised); the person's corners in RallyLab's net labels were mostly the detector's box, confirmed or adjusted. A comparison on beach, grass and indoor recordings needs the footage and is the owner's device check and a RallyLab run.

## 5. The Labeler's assisted tracking

Candidates now come from the multi-frame model alone, at its own threshold; "look again" searches with it at a low threshold and no longer runs a detector on zoomed crops. What that costs is not measured here: on a frame where the single-frame detector saw a ball the multi-frame model missed (a ball that is still, or the first and last frames of a clip, which a nine-frame window covers thinly), there is now no candidate, and the person places the ball by hand — which the screen has always allowed. No stored track, box or confirmation is changed; a rally already tracked opens as it was saved. Tracking by hand, and everything the lead does for a withheld recording, is as before.

## 6. Reproducibility of the classifier work

Nothing in `RallyLab/RallyClassifierExporter.swift`, `EvidenceReplayer.swift`, `scripts/rally_classifier/` or any stored dataset, fold, baseline or audit record is touched. `ProcessorConfig` has the same stored fields with the same defaults in RallyLab (`heatmapOnly` was already true there unless a debug default the Mac never sets said otherwise), so `canonicalSHA256` of a default configuration is what it was. RallyLab's pipeline gets the same YOLO detector (same model choice, thresholds and letterboxing, kept across runs as before) and the same net box (the sampling code moved, not rewritten). One behaviour differs in RallyLab too: a heat-only run whose model fails to load now throws instead of running YOLO — the case the exporter already refused.

**Not run:** `RallyLabTests` and a headless RallyLab comparison, both of which launch RallyLab and need the owner's go-ahead; `ScoringExposureTests`, `RallyClassifierExporterTests` and `NetLabelsTests` are the ones that bear on this.
