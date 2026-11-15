"""Model inputs from a recording's stored steps (`rcf_v1`): the derived feature set `derived_v1` for the
timestamp-windowed model (R1) and the 30 Hz uniform-grid view `grid_v1` for the step-indexed model (R2).

The definitions are the research document's §3.2–§3.3 and the dataset contract's §4.2 and §4.4; this file is
the one function the Swift extractor has to reproduce. Rules that hold for everything here:

- **Nothing crosses a segment** (`seg`): every window, every "last"/"next" and every serve is looked up among
  the steps of the step's own segment.
- **Nothing beyond the look-ahead bound**: a value at a step with tick `k` depends only on steps with tick
  ≤ `k + lookaheadSec × 600`. No label, no weight and no decider output is read.
- **Membership is decided on the integer tick** (600/s), so a window holds the same steps in any language;
  durations and rates use the steps' `t` in seconds.
- **A null is 0**, except `dt`, which is the nominal period — and so is the `dt` of every segment's first step:
  the stored value there is the time since a step of another segment (the gap, the cut), which is not this
  segment's to read and would be a huge outlier in a column that is otherwise nearly constant. The same rule
  fills R1's raw columns and R2's cells; standardisation comes later and belongs to the model.

`derived_v1` (R1), after the 18 raw columns in their order:

  per trailing window of 1.0 s and of 3.0 s — the steps with tick in (k − W, k]:
    ball_frac, proj_frac       mean of has_ball, of is_projectile
    mean_r2, mean_grav         mean over the steps where the value is not null (0 when none is)
    max_sel_y                  highest sel_y (0 when none)
    mean_speed                 mean of |Δ(sel_x, sel_y)| / Δt over consecutive step pairs, both in the window and
                               both with a selected track (0 when no such pair)
    rejections                 sum of n_cands_rejected
  log_size_rate_1s             least-squares slope of ln(sel_size) against t over the 1.0 s window's steps with a
                               size (0 with fewer than two)
  t_since_ball, t_since_proj   seconds since the last step with has_ball / is_projectile, capped at 3 (3 when none)
  serve_covered                1 when a serve emitted at a step e with tick_e ≤ k + lookahead has its contact at or
                               before this step and its emission at or after it (contact = t_e − serve_contact_offset)
  t_since_serve_contact        seconds since the latest contact, at or before this step, of a serve emitted no later
                               than the bound; capped at 3 (3 when none)
  fwd2_ball_frac, fwd2_proj_frac   mean of has_ball / is_projectile over the steps with tick in (k, k + lookahead]
                               (0 when there is none)
  t_until_ball, t_until_proj   seconds until the next such step, capped at the look-ahead (the look-ahead when none)
  has_y_above_net              1 when y_above_net is not null (its 0 would otherwise read as "at the net top")

`grid_v1` (R2): within a segment, cell c holds the steps with (tick − first tick) // (600 / samplingHz) = c — the
contract's `t_k ≤ t < t_{k+1}` on the tick timeline — and keeps the last of them. A cell's 19 values are the kept
step's 18 raw columns and `cell_missing` 0; an empty cell is the missing row (nulls, zeros, `dt` = the period,
`cell_missing` 1) with label UNKNOWN and weight 0. A step's prediction is its cell's.
"""

from __future__ import annotations

import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import validate_dataset as v  # noqa: E402

DERIVED_VERSION = "derived_v1"
GRID_VERSION = "grid_v1"
R1_LOOKAHEAD_SEC = 2.0
TRAILING_SEC = (1.0, 3.0)
CAP_SEC = 3.0
RAW_NAMES = [name for name, _, _, _ in v.FEATURES]
R1_NAMES = (RAW_NAMES
            + [f"{name}_{int(w)}s" for w in TRAILING_SEC
               for name in ("ball_frac", "proj_frac", "mean_r2", "mean_grav", "max_sel_y", "mean_speed", "rejections")]
            + ["log_size_rate_1s", "t_since_ball", "t_since_proj", "serve_covered", "t_since_serve_contact",
               "fwd2_ball_frac", "fwd2_proj_frac", "t_until_ball", "t_until_proj", "has_y_above_net"])
GRID_NAMES = RAW_NAMES + ["cell_missing"]
# R2's windows over a segment's cells: 600 cells (20 s), hop 300. A window answers for its middle 300 cells, so a
# cell is answered once, with at least 150 cells of the segment on each side (or the segment's own edge) — more
# than the 63 the network's ±62-cell receptive field needs.
WINDOW, HOP = 600, 300
MARGIN = (WINDOW - HOP) // 2
_I = v.FEATURE_INDEX


def arrays(steps: list, ablate_net: bool = False) -> dict:
    """A recording's steps as arrays: t, tick, seg, y, w and F (steps × 18, NaN for null). `ablate_net` makes
    `y_above_net` null everywhere (the net-ablated condition)."""
    F = np.array([[np.nan if x is None else x for x in s["f"]] for s in steps], dtype=np.float64).reshape(len(steps), len(RAW_NAMES))
    if ablate_net:
        F[:, _I["y_above_net"]] = np.nan
    return {"t": np.array([s["t"] for s in steps], dtype=np.float64), "tick": np.array([s["tick"] for s in steps], dtype=np.int64),
            "seg": np.array([s["seg"] for s in steps], dtype=np.int64), "y": np.array([s["y"] for s in steps], dtype=np.int64),
            "w": np.array([s["w"] for s in steps], dtype=np.float64), "F": F}


def segments(seg: np.ndarray) -> list:
    """[(start, stop)] index ranges of the contiguous segments."""
    cuts = np.flatnonzero(np.diff(seg)) + 1
    return list(zip(np.concatenate(([0], cuts)).tolist(), np.concatenate((cuts, [len(seg)])).tolist()))


def filled(arr: dict, sampling_hz: float) -> np.ndarray:
    """The raw columns with nulls filled: 0, and the nominal period for a null `dt` and for the `dt` of each
    segment's first step."""
    F = arr["F"]
    out = np.where(np.isnan(F), 0.0, F)
    out[:, _I["dt"]] = np.where(np.isnan(F[:, _I["dt"]]), 1.0 / sampling_hz, F[:, _I["dt"]])
    out[[a for a, _ in segments(arr["seg"])], _I["dt"]] = 1.0 / sampling_hz
    return out


def _prefix(x: np.ndarray) -> np.ndarray:
    return np.concatenate(([0.0], np.cumsum(x)))


def _ratio(num: np.ndarray, den: np.ndarray) -> np.ndarray:
    return np.divide(num, den, out=np.zeros(len(num)), where=den > 0)


def _segment_derived(t: np.ndarray, tick: np.ndarray, F: np.ndarray, look_ticks: int, lookahead_sec: float) -> np.ndarray:
    m = len(t)
    idx = np.arange(m)
    ball, proj = F[:, _I["has_ball"]], F[:, _I["is_projectile"]]
    sel_x, sel_y, size = F[:, _I["sel_x"]], F[:, _I["sel_y"]], F[:, _I["sel_size"]]
    cols = []
    # Speed of the selected track between a step and its predecessor, where both have one.
    pair = np.zeros(m, dtype=bool)
    pair[1:] = ~np.isnan(sel_x[1:]) & ~np.isnan(sel_x[:-1])
    speed = np.zeros(m)
    speed[1:] = np.where(pair[1:], np.hypot(np.nan_to_num(sel_x[1:] - sel_x[:-1]), np.nan_to_num(sel_y[1:] - sel_y[:-1])) / (t[1:] - t[:-1]), 0.0)
    p_ball, p_proj, p_rej = _prefix(ball), _prefix(proj), _prefix(F[:, _I["n_cands_rejected"]])
    p_speed, p_pair = _prefix(speed), _prefix(pair.astype(np.float64))
    los = {}
    for w in TRAILING_SEC:
        lo = np.searchsorted(tick, tick - round(w * v.TIMESCALE), side="right")      # the first step with tick > k − W
        los[w] = lo
        count = (idx + 1 - lo).astype(np.float64)
        cols += [(p_ball[idx + 1] - p_ball[lo]) / count, (p_proj[idx + 1] - p_proj[lo]) / count]
        for name in ("r2", "grav"):
            x = F[:, _I[name]]
            p_sum, p_n = _prefix(np.nan_to_num(x)), _prefix((~np.isnan(x)).astype(np.float64))
            cols.append(_ratio(p_sum[idx + 1] - p_sum[lo], p_n[idx + 1] - p_n[lo]))
        height = np.where(np.isnan(sel_y), -np.inf, sel_y)
        highest = np.array([height[lo[i]:i + 1].max() for i in range(m)])
        cols.append(np.where(np.isinf(highest), 0.0, highest))
        cols.append(_ratio(p_speed[idx + 1] - p_speed[lo + 1], p_pair[idx + 1] - p_pair[lo + 1]))   # pairs wholly inside: j > lo
        cols.append(p_rej[idx + 1] - p_rej[lo])
    # Least-squares slope of ln(size) against time over the 1 s window, centred per window (no prefix sums: their
    # cancellation over a long segment would cost the slope its precision).
    sized = ~np.isnan(size) & (np.nan_to_num(size) > 0)
    ln = np.log(np.where(sized, size, 1.0))
    lo = los[TRAILING_SEC[0]]
    p_sized = _prefix(sized.astype(np.float64))
    rate = np.zeros(m)
    for i in np.flatnonzero(p_sized[idx + 1] - p_sized[lo] >= 2):
        k = lo[i] + np.flatnonzero(sized[lo[i]:i + 1])
        du = t[k] - t[k].mean()
        rate[i] = float(du @ (ln[k] - ln[k].mean()) / (du @ du))
    cols.append(rate)
    # Time since the last ball / projectile, and until the next (within the look-ahead).
    for flag in (ball, proj):
        last = np.maximum.accumulate(np.where(flag > 0, idx, -1))
        cols.append(np.where(last >= 0, np.minimum(t - t[np.maximum(last, 0)], CAP_SEC), CAP_SEC))
    # Serves, each known only from tick_e − lookahead on.
    covered = np.zeros(m)
    contact = np.full(m, -np.inf)
    for e in np.flatnonzero(F[:, _I["serve_emitted"]] > 0):
        c = t[e] - F[e, _I["serve_contact_offset"]]
        j0 = max(np.searchsorted(tick, tick[e] - look_ticks, side="left"), np.searchsorted(tick, round(c * v.TIMESCALE), side="left"))
        covered[j0:e + 1] = 1.0
        contact[j0:] = np.maximum(contact[j0:], c)
    cols += [covered, np.clip(t - contact, 0.0, CAP_SEC)]
    hi = np.searchsorted(tick, tick + look_ticks, side="right")                         # one past the last step with tick ≤ k + L
    ahead = (hi - (idx + 1)).astype(np.float64)
    cols += [_ratio(p_ball[hi] - p_ball[idx + 1], ahead), _ratio(p_proj[hi] - p_proj[idx + 1], ahead)]
    for flag in (ball, proj):
        nxt = np.concatenate((np.minimum.accumulate(np.where(flag > 0, idx, m)[::-1])[::-1][1:], [m]))   # the next index > i
        cols.append(np.where(nxt < hi, np.minimum(t[np.minimum(nxt, m - 1)] - t, lookahead_sec), lookahead_sec))
    cols.append((~np.isnan(F[:, _I["y_above_net"]])).astype(np.float64))
    return np.column_stack(cols)


def derived(arr: dict, sampling_hz: float, lookahead_sec: float = R1_LOOKAHEAD_SEC) -> np.ndarray:
    """R1's input, steps × len(R1_NAMES): the filled raw columns, then `derived_v1`."""
    look_ticks = round(lookahead_sec * v.TIMESCALE)
    out = np.empty((len(arr["t"]), len(R1_NAMES)))
    out[:, :len(RAW_NAMES)] = filled(arr, sampling_hz)
    for a, b in segments(arr["seg"]):
        out[a:b, len(RAW_NAMES):] = _segment_derived(arr["t"][a:b], arr["tick"][a:b], arr["F"][a:b], look_ticks, lookahead_sec)
    return out


def grid(arr: dict, sampling_hz: float) -> list:
    """`grid_v1`: one entry per segment — {start, stop (the segment's steps), cell (each step's cell), X (cells × 19),
    y, w (per cell)}."""
    if v.TIMESCALE % sampling_hz:
        raise ValueError(f"grid_v1 needs a whole number of ticks per cell: {v.TIMESCALE} / {sampling_hz}")
    cell_ticks = int(v.TIMESCALE // sampling_hz)
    raw = filled(arr, sampling_hz)
    out = []
    for a, b in segments(arr["seg"]):
        cell = (arr["tick"][a:b] - arr["tick"][a]) // cell_ticks
        last = np.concatenate((np.flatnonzero(np.diff(cell)), [b - a - 1]))            # the last step of each occupied cell
        n = int(cell[-1]) + 1
        X = np.zeros((n, len(GRID_NAMES)))
        X[:, _I["dt"]] = 1.0 / sampling_hz
        X[:, -1] = 1.0
        y = np.full(n, v.STATES["UNKNOWN"], dtype=np.int64)
        w = np.zeros(n)
        X[cell[last], :len(RAW_NAMES)] = raw[a:b][last]
        X[cell[last], -1] = 0.0
        y[cell[last]] = arr["y"][a:b][last]
        w[cell[last]] = arr["w"][a:b][last]
        out.append({"start": a, "stop": b, "cell": cell, "X": X, "y": y, "w": w})
    return out


def windows(cells: int) -> list:
    """[(start, keep_from, keep_to)] over a segment of `cells` cells: window j covers [start, start + WINDOW) and
    answers for [keep_from, keep_to); the answers partition [0, cells)."""
    reach = WINDOW - MARGIN
    count = 1 if cells <= reach else 1 + math.ceil((cells - reach) / HOP)
    return [(j * HOP, 0 if j == 0 else j * HOP + MARGIN, cells if j == count - 1 else j * HOP + reach) for j in range(count)]


def window_cells(start: int, cells: int) -> np.ndarray:
    """The cell indices a window reads: [start, start + WINDOW), the segment's last cell repeated past its end."""
    return np.minimum(np.arange(start, start + WINDOW), cells - 1)
