"""Tests for scripts/rally_classifier/features.py: `derived_v1` against hand-computed values, its look-ahead
bound and segment isolation, and the `grid_v1` view and its windows. Synthetic steps only.

    python3 -m unittest scripts.tests.test_rally_classifier_features -v
"""

import copy
import os
import shutil
import sys
import tempfile
import unittest

try:
    import numpy as np
except ImportError:   # the checker's CI runner has no numpy; these run where the trainer does
    raise unittest.SkipTest("numpy is not installed: the rally-classifier trainer's tests run where it is")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import rally_classifier_synthetic as syn  # noqa: E402
import features as ft  # noqa: E402
import validate_dataset as v  # noqa: E402

I = v.FEATURE_INDEX
COL = {name: i for i, name in enumerate(ft.R1_NAMES)}


def step(t, seg=0, y=0, **values):
    """A step at time t with nothing detected, then `values` by column name."""
    f = [None if nullable else 0 for _, nullable, _, _ in v.FEATURES]
    for name, value in values.items():
        f[I[name]] = value
    return {"t": t, "tick": round(t * v.TIMESCALE), "seg": seg, "f": f, "y": y, "w": v.WEIGHTS[str(y)]}


def derived(steps, **kw):
    return ft.derived(ft.arrays(steps), 30, **kw)


class Derived(unittest.TestCase):
    def test_names(self):
        self.assertEqual(len(ft.R1_NAMES), 42)
        self.assertEqual(len(set(ft.R1_NAMES)), 42)
        self.assertEqual(ft.R1_NAMES[:18], [n for n, _, _, _ in v.FEATURES])

    def test_raw_columns_fill_nulls_with_zero_and_dt_with_the_period(self):
        X = derived([step(0.0), step(0.5, dt=0.5, has_ball=1, max_conf=0.9), step(40.0, seg=1, dt=39.5), step(40.1, seg=1, dt=0.1)])
        self.assertAlmostEqual(X[0, COL["dt"]], 1 / 30)
        self.assertEqual(X[0, COL["max_conf"]], 0.0)
        self.assertEqual((X[1, COL["dt"]], X[1, COL["max_conf"]]), (0.5, 0.9))
        self.assertAlmostEqual(X[2, COL["dt"]], 1 / 30)      # a segment's first step: its stored dt is the gap behind it, not read
        self.assertEqual(X[3, COL["dt"]], 0.1)

    def test_trailing_windows_by_hand(self):
        ball = dict(has_ball=1, is_projectile=1, r2=0.8, grav=0.5, sel_size=0.02)
        steps = [step(0.0, **ball, sel_x=0.1, sel_y=0.2, n_cands=2, n_cands_rejected=2),
                 step(0.5, dt=0.5, **ball, sel_x=0.4, sel_y=0.6, n_cands=1, n_cands_rejected=1),   # moved 0.5 in 0.5 s
                 step(1.0, dt=0.5),
                 step(1.5, dt=0.5, has_ball=1),
                 step(3.2, dt=1.7, has_ball=1, is_projectile=1, r2=0.4, grav=0.1, sel_x=0.5, sel_y=0.9, sel_size=0.04)]
        X = derived(steps)
        at = lambda i, name: X[i, COL[name]]
        # the 1 s window of the step at 1.0 holds the steps in (0.0, 1.0]: those at 0.5 and 1.0
        self.assertAlmostEqual(at(2, "ball_frac_1s"), 0.5)
        self.assertAlmostEqual(at(2, "mean_r2_1s"), 0.8)
        self.assertAlmostEqual(at(2, "max_sel_y_1s"), 0.6)
        self.assertEqual(at(2, "rejections_1s"), 1)
        self.assertEqual(at(2, "mean_speed_1s"), 0.0)       # its only moving pair starts outside the window
        # the 3 s window of the step at 1.5 holds all four earlier steps
        self.assertAlmostEqual(at(3, "ball_frac_3s"), 0.75)
        self.assertAlmostEqual(at(3, "proj_frac_3s"), 0.5)
        self.assertAlmostEqual(at(3, "mean_grav_3s"), 0.5)
        self.assertAlmostEqual(at(3, "max_sel_y_3s"), 0.6)
        self.assertAlmostEqual(at(3, "mean_speed_3s"), 1.0)  # |(0.3, 0.4)| / 0.5 s
        self.assertEqual(at(3, "rejections_3s"), 3)
        # the step at 3.2: 3 s window is (0.2, 3.2]
        self.assertAlmostEqual(at(4, "ball_frac_3s"), 0.75)
        self.assertAlmostEqual(at(4, "max_sel_y_3s"), 0.9)
        self.assertAlmostEqual(at(4, "mean_r2_1s"), 0.4)
        # nothing detected in a window reads 0, not null
        self.assertEqual((at(2, "max_sel_y_1s") > 0, X[2, COL["sel_y"]]), (True, 0.0))
        alone = derived([step(0.0), step(0.5, dt=0.5)])
        self.assertEqual((alone[1, COL["mean_r2_1s"]], alone[1, COL["max_sel_y_3s"]], alone[1, COL["mean_speed_3s"]]), (0.0, 0.0, 0.0))

    def test_log_size_rate_is_the_slope_of_log_size(self):
        steps = [step(0.1 * i, dt=None if i == 0 else 0.1, has_ball=1, is_projectile=1, sel_x=0.5, sel_y=0.5, sel_size=0.02 * np.exp(0.7 * 0.1 * i))
                 for i in range(8)]
        X = derived(steps)
        self.assertEqual(X[0, COL["log_size_rate_1s"]], 0.0)                 # one size: no slope
        np.testing.assert_allclose(X[1:, COL["log_size_rate_1s"]], 0.7, rtol=1e-9)

    def test_time_since_and_until_are_capped(self):
        steps = [step(0.0, has_ball=1, is_projectile=1)] + [step(0.5 * i, dt=0.5) for i in range(1, 9)] + [step(4.5, dt=0.5, has_ball=1)]
        X = derived(steps)
        self.assertEqual(X[0, COL["t_since_ball"]], 0.0)
        self.assertAlmostEqual(X[4, COL["t_since_ball"]], 2.0)
        self.assertEqual(X[8, COL["t_since_ball"]], 3.0)                    # 4.0 s ago: capped
        self.assertEqual(X[8, COL["t_since_proj"]], 3.0)
        self.assertAlmostEqual(X[9, COL["t_since_ball"]], 0.0)
        self.assertEqual(X[9, COL["t_since_proj"]], 3.0)
        self.assertAlmostEqual(X[8, COL["t_until_ball"]], 0.5)
        self.assertAlmostEqual(X[5, COL["t_until_ball"]], 2.0)              # exactly at the bound
        self.assertEqual(X[4, COL["t_until_ball"]], 2.0)                    # 2.5 s ahead: beyond the look-ahead, reads as none
        self.assertEqual(X[9, COL["t_until_ball"]], 2.0)
        self.assertAlmostEqual(X[5, COL["fwd2_ball_frac"]], 0.25)           # the four steps in (2.5, 4.5]
        self.assertEqual(X[4, COL["fwd2_ball_frac"]], 0.0)
        self.assertEqual(X[9, COL["fwd2_ball_frac"]], 0.0)                  # no step ahead

    def test_serve_coverage_only_through_serves_emitted_within_the_bound(self):
        # a serve with its contact at 2.5 s, emitted at 5.0 s
        steps = [step(0.5 * i, dt=None if i == 0 else 0.5) for i in range(10)] + [step(5.0, dt=0.5, serve_emitted=1, serve_contact_offset=2.5)] \
            + [step(5.5, dt=0.5), step(9.0, dt=3.5)]
        steps[-1]["seg"] = 0
        X = derived(steps)
        covered = X[:, COL["serve_covered"]]
        t = [s["t"] for s in steps]
        # covered: at or after the contact, at or before the emission, and the emission no later than t + 2.0
        self.assertEqual([tt for tt, c in zip(t, covered) if c], [3.0, 3.5, 4.0, 4.5, 5.0])
        since = dict(zip(t, X[:, COL["t_since_serve_contact"]]))
        self.assertEqual(since[2.5], 3.0)                                    # the serve is not known yet (emitted 2.5 s later)
        self.assertAlmostEqual(since[3.0], 0.5)
        self.assertAlmostEqual(since[5.5], 3.0)
        self.assertEqual(since[9.0], 3.0)                                    # capped
        wider = derived(steps, lookahead_sec=3.0)[:, COL["serve_covered"]]
        self.assertEqual([tt for tt, c in zip(t, wider) if c], [2.5, 3.0, 3.5, 4.0, 4.5, 5.0])

    def test_has_y_above_net_and_the_ablation(self):
        steps = [step(0.0, has_ball=1, is_projectile=1, sel_x=0.5, sel_y=0.8, y_above_net=0.0), step(0.5, dt=0.5)]
        X = derived(steps)
        self.assertEqual(X[:, COL["has_y_above_net"]].tolist(), [1.0, 0.0])
        ablated = ft.derived(ft.arrays(steps, ablate_net=True), 30)
        self.assertEqual(ablated[:, COL["has_y_above_net"]].tolist(), [0.0, 0.0])
        self.assertEqual(ablated[:, COL["y_above_net"]].tolist(), [0.0, 0.0])
        others = [i for i, n in enumerate(ft.R1_NAMES) if n not in ("y_above_net", "has_y_above_net")]
        np.testing.assert_array_equal(ablated[:, others], X[:, others])


class OnADataset(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="rc-features-")
        dataset = syn.write(cls.tmp)
        manifest = v.load_manifest(dataset)
        cls.steps = {r["recordingId"]: v.read_steps(dataset, r) for r in manifest["recordings"]}

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    @staticmethod
    def scramble(s, rng):
        """Replace a step's measurements with other valid ones (dt, t and seg stay: they are the timeline)."""
        f = s["f"]
        ball = int(rng.integers(0, 2))
        f[I["has_ball"]], f[I["is_projectile"]] = ball, ball
        f[I["n_court_dets"]] = f[I["n_dets"]] = f[I["n_cands"]] = f[I["n_cands_proj"]] = ball
        f[I["n_cands_rejected"]] = 0
        for name in ("max_conf", "ball_y_any", "sel_x", "sel_y", "sel_size", "r2", "grav"):
            f[I[name]] = float(rng.uniform(0.05, 0.95)) if ball else None
        f[I["y_above_net"]] = float(rng.uniform(-0.3, 0.3)) if ball else None
        f[I["serve_emitted"]], f[I["serve_contact_offset"]] = 1, float(rng.uniform(0.5, 2.5))

    def test_a_step_beyond_the_look_ahead_changes_nothing(self):
        rng = np.random.default_rng(0)
        steps = self.steps["syn_gra_02"]
        base = derived(steps)
        look = round(ft.R1_LOOKAHEAD_SEC * v.TIMESCALE)
        for k in (400, 900, 1500):
            changed = copy.deepcopy(steps)
            for s in changed[k:]:
                self.scramble(s, rng)
            X = derived(changed)
            safe = [i for i, s in enumerate(steps) if s["tick"] + look < steps[k]["tick"]]
            self.assertGreater(len(safe), 100)
            np.testing.assert_array_equal(X[safe], base[safe])
            near = [i for i, s in enumerate(steps) if steps[k]["tick"] - look <= s["tick"] < steps[k]["tick"]]
            self.assertFalse(np.array_equal(X[near], base[near]))            # within the bound the future is read, as declared

    def test_nothing_crosses_a_segment_break(self):
        rng = np.random.default_rng(1)
        steps = self.steps["syn_bea_03"]                                     # a cut at the start and a frame gap at 20 s
        segs = sorted({s["seg"] for s in steps})
        self.assertGreaterEqual(len(segs), 3)
        base = derived(steps)
        for target in segs:
            changed = copy.deepcopy(steps)
            for s in changed:
                if s["seg"] == target:
                    self.scramble(s, rng)
            X = derived(changed)
            others = [i for i, s in enumerate(steps) if s["seg"] != target]
            np.testing.assert_array_equal(X[others], base[others])
            grids, base_grids = ft.grid(ft.arrays(changed), 30), ft.grid(ft.arrays(steps), 30)
            for g, b, seg in zip(grids, base_grids, segs):
                if seg != target:
                    np.testing.assert_array_equal(g["X"], b["X"])

    def test_no_label_or_weight_is_read(self):
        steps = self.steps["syn_ind_00"]
        changed = copy.deepcopy(steps)
        for s in changed:
            s["y"], s["w"] = v.STATES["UNKNOWN"], 0.0
        np.testing.assert_array_equal(derived(changed), derived(steps))
        for g, b in zip(ft.grid(ft.arrays(changed), 30), ft.grid(ft.arrays(steps), 30)):
            np.testing.assert_array_equal(g["X"], b["X"])

    def test_every_value_is_finite(self):
        for steps in self.steps.values():
            self.assertTrue(np.isfinite(derived(steps)).all())


class Grid(unittest.TestCase):
    def test_cells_missing_rows_and_shared_cells(self):
        S = v.STATES
        at = lambda tick, **kw: {**step(tick / v.TIMESCALE, **kw), "tick": tick}
        steps = [at(1000, y=S["ACTIVE_RALLY"], has_ball=1, max_conf=0.5),
                 at(1020, y=S["ACTIVE_RALLY"], dt=0.0333, has_ball=1, max_conf=0.6),
                 at(1045, y=S["ACTIVE_RALLY"], dt=0.0417, has_ball=1, max_conf=0.7),      # cell 2 …
                 at(1058, y=S["NON_RALLY"], dt=0.0217, has_ball=1, max_conf=0.8),         # … shared: the later step is kept
                 at(1120, y=S["NON_RALLY"], dt=0.1033, n_dets=1, max_conf=0.9)]           # cells 3–5 are empty
        (g,) = ft.grid(ft.arrays(steps), 30)
        self.assertEqual(g["cell"].tolist(), [0, 1, 2, 2, 6])
        self.assertEqual(g["X"].shape, (7, 19))
        self.assertEqual(g["X"][:, -1].tolist(), [0, 0, 0, 1, 1, 1, 0])                   # cell_missing
        self.assertEqual(g["X"][:, I["max_conf"]].tolist(), [0.5, 0.6, 0.8, 0, 0, 0, 0.9])
        self.assertEqual(g["y"].tolist(), [1, 1, 0, S["UNKNOWN"], S["UNKNOWN"], S["UNKNOWN"], 0])
        self.assertEqual(g["w"].tolist(), [1, 1, 1, 0, 0, 0, 1])
        np.testing.assert_allclose(g["X"][3:6, I["dt"]], 1 / 30)                          # a missing row's dt is the period
        self.assertEqual(g["X"][3:6, :18].sum() - 3 / 30, 0.0)                            # and nothing else
        self.assertAlmostEqual(g["X"][0, I["dt"]], 1 / 30)                                # the recording's first step: null → the period
        self.assertEqual(g["X"][6, I["dt"]], 0.1033)

    def test_one_grid_per_segment(self):
        steps = [step(0.0), step(1 / 30, dt=1 / 30), step(5.0, seg=1, dt=4.9667), step(5.1, seg=1, dt=0.1)]
        grids = ft.grid(ft.arrays(steps), 30)
        self.assertEqual([(g["start"], g["stop"], len(g["y"])) for g in grids], [(0, 2, 2), (2, 4, 4)])
        self.assertAlmostEqual(grids[1]["X"][0, I["dt"]], 1 / 30)             # not the 4.97 s behind the break
        self.assertEqual(grids[1]["X"][3, I["dt"]], 0.1)

    def test_a_grid_needs_whole_ticks_per_cell(self):
        with self.assertRaises(ValueError):
            ft.grid(ft.arrays([step(0.0)]), 7)

    def test_windows_answer_for_every_cell_once_with_context(self):
        for cells in (1, 62, 449, 450, 451, 600, 749, 750, 751, 1801, 9000):
            answered = np.zeros(cells, dtype=int)
            for start, lo, hi in ft.windows(cells):
                self.assertEqual(start % ft.HOP, 0)
                self.assertTrue(start <= lo < hi <= min(cells, start + ft.WINDOW), (cells, start, lo, hi))
                answered[lo:hi] += 1
                # 150 cells of context inside the window on each side, unless the segment itself ends there
                self.assertTrue(lo == 0 or lo - start >= 150)
                self.assertTrue(hi == cells or start + ft.WINDOW - hi >= 150)
            self.assertTrue((answered == 1).all(), cells)
        self.assertEqual(ft.window_cells(300, 451).tolist()[:152], list(range(300, 451)) + [450])
        self.assertEqual(set(ft.window_cells(300, 451).tolist()[151:]), {450})            # the last cell, repeated


if __name__ == "__main__":
    unittest.main()
