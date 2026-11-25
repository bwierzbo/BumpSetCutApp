"""R2: the preregistration's small non-causal TCN over the 30 Hz grid view (`grid_v1`), in PyTorch on the CPU.

Architecture (§3): linear 19 → 32 (the 18 raw columns and `cell_missing`), five residual blocks — one 1-D
convolution each, kernel 5, dilations 1, 2, 4, 8, 16, 32 channels, GELU, dropout 0.1 — and a 1×1 head to one
logit per cell. Receptive field 125 cells, ±62 (±2.07 s). 26,433 parameters.

Training (§3, §4): AdamW, learning rate 1e-3, weight decay 1e-2, batches of 16 windows, weighted binary
cross-entropy with the contract's `w`; deterministic algorithms, one thread, the seed given. Each 600-cell
window is trained on the cells it answers for at scoring (`features.windows`), so a cell carries loss once per
epoch, with the context it will have when it is scored; a cell past a segment's end repeats the last cell and
carries none. Standardisation (mean and standard deviation per column over the training cells with `w` = 1) is
part of the model.

Augmentation, training windows only (§4):
- correlated detection dropout — with probability 0.1 per window, one run of 3–15 cells (0.1–0.5 s) loses its
  detections: `has_ball`, `max_conf`, `sel_x`, `sel_y`, `sel_size`, `r2`, `grav` nulled and the counts zeroed,
  and with them the three columns the contract ties to those — `is_projectile` 0, `ball_y_any` and
  `y_above_net` null — so an augmented row is still a row the pipeline could have written;
- confidence jitter — every cell with a detection gets `max_conf` + U(−0.05, 0.05), clipped to [0, 1].
Time is not stretched (labels are ticks).
"""

from __future__ import annotations

import copy
import os
import sys

import numpy as np
import torch
from torch import nn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import features as ft  # noqa: E402
import validate_dataset as v  # noqa: E402

CHANNELS, KERNEL, DILATIONS, DROPOUT = 32, 5, (1, 2, 4, 8, 16), 0.1
LEARNING_RATE, WEIGHT_DECAY, BATCH, MAX_EPOCHS = 1e-3, 1e-2, 16, 40
LOOKAHEAD_SEC = 2.1
DROPOUT_PROBABILITY, DROPOUT_CELLS, CONFIDENCE_JITTER = 0.1, (3, 15), 0.05
_I = v.FEATURE_INDEX
_NULLED = [_I[n] for n in ("has_ball", "max_conf", "sel_x", "sel_y", "sel_size", "r2", "grav", "is_projectile", "ball_y_any", "y_above_net",
                           "n_court_dets", "n_dets", "n_cands", "n_cands_proj", "n_cands_rejected")]


class Block(nn.Module):
    def __init__(self, dilation: int):
        super().__init__()
        self.conv = nn.Conv1d(CHANNELS, CHANNELS, KERNEL, dilation=dilation, padding=dilation * (KERNEL - 1) // 2)
        self.act, self.drop = nn.GELU(), nn.Dropout(DROPOUT)

    def forward(self, x):
        return x + self.drop(self.act(self.conv(x)))


class TCN(nn.Module):
    def __init__(self, mean: np.ndarray, std: np.ndarray):
        super().__init__()
        self.register_buffer("mean", torch.tensor(mean, dtype=torch.float32))
        self.register_buffer("std", torch.tensor(std, dtype=torch.float32))
        self.inp = nn.Linear(len(ft.GRID_NAMES), CHANNELS)
        self.blocks = nn.Sequential(*(Block(d) for d in DILATIONS))
        self.head = nn.Conv1d(CHANNELS, 1, 1)

    def forward(self, x):                                   # x: windows × cells × 19, raw units
        h = self.inp((x - self.mean) / self.std).transpose(1, 2)
        return self.head(self.blocks(h)).squeeze(1)         # windows × cells, logits


def deterministic(seed: int):
    torch.use_deterministic_algorithms(True)
    torch.set_num_threads(1)
    torch.manual_seed(seed)


def window_set(grids: list) -> dict:
    """Every window of a list of segment grids as arrays: X (windows × 600 × 19), y (1 for ACTIVE_RALLY), and
    weight — the cell's `w` where the window answers for the cell, 0 elsewhere. `where` maps each window back:
    (grid index, keep_from, keep_to, window start)."""
    X, y, weight, where = [], [], [], []
    for gi, g in enumerate(grids):
        cells = len(g["y"])
        for start, lo, hi in ft.windows(cells):
            pick = ft.window_cells(start, cells)
            answers = (np.arange(start, start + ft.WINDOW) >= lo) & (np.arange(start, start + ft.WINDOW) < hi)
            X.append(g["X"][pick])
            y.append((g["y"][pick] == v.STATES["ACTIVE_RALLY"]).astype(np.float32))
            weight.append(np.where(answers, g["w"][pick], 0.0))
            where.append((gi, lo, hi, start))
    return {"X": np.array(X, dtype=np.float32).reshape(len(X), ft.WINDOW, len(ft.GRID_NAMES)),
            "y": np.array(y, dtype=np.float32).reshape(len(y), ft.WINDOW),
            "weight": np.array(weight, dtype=np.float32).reshape(len(weight), ft.WINDOW), "where": where}


def standardisation(ws: dict) -> tuple:
    """Mean and standard deviation per column over the cells that carry loss (a constant column gets 1)."""
    rows = ws["X"][ws["weight"] > 0].astype(np.float64)
    if not len(rows):
        raise ValueError("no training cell carries loss weight")
    std = rows.std(axis=0)
    return rows.mean(axis=0), np.where(std > 0, std, 1.0)


def augment(X: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """A training batch with the preregistration's augmentation applied (the module docstring)."""
    X = X.copy()
    conf = X[:, :, _I["max_conf"]]
    seen = X[:, :, _I["n_dets"]] > 0
    conf[seen] = np.clip(conf[seen] + rng.uniform(-CONFIDENCE_JITTER, CONFIDENCE_JITTER, int(seen.sum())), 0.0, 1.0)
    for i in range(len(X)):
        if rng.random() < DROPOUT_PROBABILITY:
            run = int(rng.integers(DROPOUT_CELLS[0], DROPOUT_CELLS[1] + 1))
            at = int(rng.integers(0, ft.WINDOW - run + 1))
            X[i, at:at + run, _NULLED] = 0.0
    return X


def loss_of(model: TCN, ws: dict, indices) -> torch.Tensor:
    """Weighted binary cross-entropy over the given windows: Σ weight · BCE / Σ weight."""
    weight = torch.from_numpy(ws["weight"][indices])
    logits = model(torch.from_numpy(ws["X"][indices]))
    per_cell = nn.functional.binary_cross_entropy_with_logits(logits, torch.from_numpy(ws["y"][indices]), reduction="none")
    return (per_cell * weight).sum() / weight.sum()


def fit(train: dict, seed: int, epochs: int, validation: dict | None = None) -> dict:
    """Train for `epochs` epochs. With `validation`, the returned model is the epoch with the lowest validation
    loss (the earliest on a tie) and `epochs` its number; without, the last epoch's."""
    deterministic(seed)
    rng = np.random.default_rng(seed)
    model = TCN(*standardisation(train))
    optimiser = torch.optim.AdamW(model.parameters(), lr=LEARNING_RATE, weight_decay=WEIGHT_DECAY)
    carrying = np.flatnonzero(train["weight"].sum(axis=1) > 0)          # a window with no weighted cell has no loss
    best = {"loss": None, "epochs": epochs, "state": None, "history": []}
    for epoch in range(1, epochs + 1):
        model.train()
        order = rng.permutation(carrying)
        for at in range(0, len(order), BATCH):
            picks = np.sort(order[at:at + BATCH])
            batch = {"X": augment(train["X"][picks], rng).astype(np.float32), "y": train["y"][picks], "weight": train["weight"][picks]}
            optimiser.zero_grad()
            loss_of(model, batch, slice(None)).backward()
            optimiser.step()
        if validation is not None:
            model.eval()
            with torch.no_grad():
                val = float(loss_of(model, validation, slice(None)))
            best["history"].append(val)
            if best["loss"] is None or val < best["loss"]:
                best.update(loss=val, epochs=epoch, state=copy.deepcopy(model.state_dict()))
    if validation is not None:
        model.load_state_dict(best["state"])
    model.eval()
    return {"model": model, "epochs": best["epochs"], "validationLoss": best["loss"], "history": best["history"]}


def cell_logits(model: TCN, grids: list) -> list:
    """Per segment grid, the logit of every cell — each from the window that answers for it."""
    ws = window_set(grids)
    out = [np.zeros(len(g["y"])) for g in grids]
    with torch.no_grad():
        logits = model(torch.from_numpy(ws["X"])).numpy()
    for row, (gi, lo, hi, start) in zip(logits, ws["where"]):
        out[gi][lo:hi] = row[lo - start:hi - start]
    return out


def parameters(model: TCN) -> int:
    return sum(p.numel() for p in model.parameters())
