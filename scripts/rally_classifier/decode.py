"""From per-step probabilities to clips: the fixed decode contract (research document §5, preregistration §5).

    probabilities ─ hysteresis ─ raw intervals ─ raw floor ─ SegmentBuilder.finalizeWithRaw ─ clips

Everything here is post-processing, the same for every learned candidate. Ticks are 600 per second and
intervals half-open, as in the scoring contract.

**Hysteresis**, per footage segment (never across a segment break, never inside a cut range or a time-breaking
span — those steps are not footage and no interval opens there):
- idle → in rally once the steps of one unbroken run all have p ≥ θ_on and the run spans ≥ sustain_on; the
  interval **starts at the run's first step**;
- in rally → idle once the steps of one unbroken run all have p ≤ θ_off and the run spans ≥ sustain_off; the
  interval **ends at the run's first step** (the first inactive frame, as the decider's raw ranges end);
- a run's span is its last step's tick minus its first's, compared with the sustain in ticks;
- an interval still open at the segment's last step ends one cell (600 / samplingHz ticks) after it, clamped to
  the recording's duration.

**Raw floor**: an interval shorter than 1.1653 s is dropped before padding (the decider's `minRallySec`).

**Padding, joining, minimum clip length**: `finalize_with_raw` is the port of `SegmentBuilder.closeSegment` +
`finalizeWithRaw`. It is the validator's `pad_and_merge` — the function the contract (§3a) names as the port
and the one the stored baseline's shape comes from — so there is one implementation of the padding in Python,
not two. `parity` proves it on the dataset in hand before it is trusted: every stored clip of every variant
must be rebuilt exactly from its own pre-merge raw spans, and one mismatch stops the run.
"""

from __future__ import annotations

import itertools
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import validate_dataset as v  # noqa: E402

RAW_FLOOR_SEC = 1.1653
THETA_ON = (0.5, 0.6, 0.7, 0.8)
THETA_OFF = (0.2, 0.3, 0.4)
SUSTAIN_ON_SEC = (0.1, 0.2, 0.4)
SUSTAIN_OFF_SEC = (0.4, 0.8, 1.2)
# The grid in its order (the last tie-break of the selection rule is "earlier grid order").
GRID = [{"thetaOn": a, "thetaOff": b, "sustainOnSec": c, "sustainOffSec": d}
        for a, b, c, d in itertools.product(THETA_ON, THETA_OFF, SUSTAIN_ON_SEC, SUSTAIN_OFF_SEC)]


class ParityError(Exception):
    """The padding port does not rebuild the stored baseline. Nothing may be decoded with it."""


def hysteresis(ticks, p, point: dict, end_tick: int) -> list:
    """The raw intervals [(start, end)] of one footage segment's steps (`ticks` ascending, `p` their probabilities)."""
    on, off = point["thetaOn"], point["thetaOff"]
    sustain_on, sustain_off = round(point["sustainOnSec"] * v.TIMESCALE), round(point["sustainOffSec"] * v.TIMESCALE)
    out, active, run, start = [], False, None, None
    for k, q in zip(ticks, p):
        if (q <= off) if active else (q >= on):
            run = k if run is None else run
            if k - run >= (sustain_off if active else sustain_on):
                if active:
                    out.append((start, run))
                else:
                    start = run
                active, run = not active, None
        else:
            run = None
    if active:
        out.append((start, end_tick))
    return out


def is_footage(tick: int, rec: dict) -> bool:
    return not any(s["startTick"] <= tick < s["endTick"] for s in rec["cutRanges"] + rec["timeBreakingSpans"])


def raw_intervals(rec: dict, ticks, seg_ranges, p, point: dict, sampling_hz: float) -> tuple:
    """A recording's decoded raw intervals after the raw floor, and how many the floor dropped. `ticks` and `p` are
    the recording's arrays, `seg_ranges` the (start, stop) index ranges of its segments."""
    duration = round(rec["durationSec"] * v.TIMESCALE)
    cell = round(v.TIMESCALE / sampling_hz)
    found = []
    for a, b in seg_ranges:
        if is_footage(int(ticks[a]), rec):
            found += hysteresis(ticks[a:b].tolist(), p[a:b].tolist(), point, min(duration, int(ticks[b - 1]) + cell))
    kept = [(s, e) for s, e in found if (e - s) / v.TIMESCALE >= RAW_FLOOR_SEC]
    return kept, len(found) - len(kept)


def finalize_with_raw(raw_spans, settings: dict, duration_ticks: int) -> list:
    """The clips production builds from raw rallies [(startTick, endTick)] at `settings` (prerollSec, postrollSec,
    joinSec, minSegmentSec): [{rawSpans, startTick, endTick}] in time order. Refuses what the port does not cover:
    a pre- or post-roll that is not a whole number of ticks (the builder converts them with CMTimeMakeWithSeconds,
    whose rounding is not ported) and a raw rally outside the recording."""
    for key in ("prerollSec", "postrollSec"):
        if abs(settings[key] * v.TIMESCALE - round(settings[key] * v.TIMESCALE)) > 1e-9:
            raise ValueError(f"{key} {settings[key]} is not a whole number of ticks; the port does not cover it")
    for a, b in raw_spans:
        if not (0 <= a < b <= duration_ticks):
            raise ValueError(f"raw span [{a}, {b}) is not inside the recording [0, {duration_ticks}]")
    return v.pad_and_merge(raw_spans, settings, duration_ticks)


def clips_from(rec: dict, raw: list, settings: dict) -> list:
    return finalize_with_raw(raw, settings, round(rec["durationSec"] * v.TIMESCALE))


def parity(dataset_dir: str, manifest: dict) -> dict:
    """Rebuild every stored clip of every baseline variant from its pre-merge raw spans at the variant's settings.
    Returns {variant: clips checked}; raises ParityError naming the mismatches otherwise."""
    settings = {var["name"]: var["settings"] for var in manifest["baseline"]["variants"]}
    checked = {name: 0 for name in settings}
    wrong = []
    for rec in manifest["recordings"]:
        duration = round(rec["durationSec"] * v.TIMESCALE)
        for name, clips in v.read_baseline(dataset_dir, rec).items():
            for j, clip in enumerate(clips):
                want = [{"rawSpans": clip["rawSpans"], "startTick": clip["startTick"], "endTick": clip["endTick"]}]
                try:
                    got = finalize_with_raw([(q["startTick"], q["endTick"]) for q in clip["rawSpans"]], settings[name], duration)
                except ValueError as e:
                    got = str(e)
                checked[name] += 1
                if got != want:
                    shown = got if isinstance(got, str) else [(c["startTick"], c["endTick"]) for c in got]
                    wrong.append(f"{rec['recordingId']} {name}[{j}]: stored [{clip['startTick']}, {clip['endTick']}) from raws "
                                 f"{[(q['startTick'], q['endTick']) for q in clip['rawSpans']]}, the port builds {shown}")
    if wrong:
        raise ParityError(f"the SegmentBuilder port does not reproduce {len(wrong)} of {sum(checked.values())} stored clips: "
                          + "; ".join(wrong[:5]) + (" …" if len(wrong) > 5 else ""))
    return checked
