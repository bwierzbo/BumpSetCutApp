"""A synthetic rally-classifier dataset large enough for five grouped folds, written with the validator's own
builder (`validate_dataset.write_synthetic`), and the files a trainer run needs beside it. Shared by the
`test_rally_classifier_*` suites; nothing here touches a real recording.
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "rally_classifier"))
import validate_dataset as v  # noqa: E402

SURFACES = ("beach", "grass", "indoor")
RALLIES = [[(4, 11), (18, 27), (36, 44)], [(6, 13), (22, 31)], [(5, 10), (16, 24), (30, 37), (45, 53)], [(8, 17), (26, 35), (44, 52)]]


def specs(groups_per_surface: int = 5) -> list:
    """`groups_per_surface` groups on each surface; some hold a second recording, one recording is restricted
    (edited, no negatives), one has a missed serve, one a cut and a frame gap, one a replay span, one no net."""
    out = []
    for si, surface in enumerate(SURFACES):
        for g in range(groups_per_surface):
            n = si * groups_per_surface + g
            rid, group = f"syn_{surface[:3]}_{g:02d}", f"g-{surface[:3]}-{g:02d}"
            spec = dict(rid=rid, group=group, split="train", fold=None, surface=surface, recording_type="continuous", negatives="standard",
                        coverage="declared_complete", rallies=RALLIES[n % len(RALLIES)])
            if n == 1:
                spec.update(recording_type="edited", negatives="restricted", restricted_reasons=["edited recording"])
            if n == 2:
                spec.update(rallies=[(4, 11), (36, 44)], excluded=[(20, 23, "missedServe")])
            if n == 3:
                spec.update(rallies=[(8, 17), (26, 35), (44, 52)], cuts=[(0, 3)], gap_at=20.0)
            if n == 4:
                spec.update(rallies=[(6, 13), (22, 31)], tb=[(50, 55, "replay", "proposed")])
            if n == 5:
                spec.update(net=False, coverage="stage1_complete", nra=[(14, 16)], short_pair=[(55.0, 56.5), (58.0, 59.5)])
            out.append(spec)
            if g == 0:          # a second recording of the same group
                out.append(dict(spec, rid=rid + "_v2", rallies=RALLIES[(n + 1) % len(RALLIES)]))
    return out


def write(folder: str, groups_per_surface: int = 5, seed: int = 7, name: str = "Synthetic-rally-classifier") -> str:
    """Write the dataset under `folder` and return its path."""
    dataset = os.path.join(folder, name)
    v.write_synthetic(dataset, seed=seed, specs=specs(groups_per_surface))
    return dataset


def write_closure(folder: str, dataset: str) -> str:
    """The external withheld-closure file: the manifest's own closure, as the exporter would hand it over."""
    closure = v.load_manifest(dataset)["withheld"]
    path = os.path.join(folder, "closure.json")
    with open(path, "w") as fh:
        json.dump({k: closure[k] for k in ("names", "sourceIds", "fingerprints")}, fh)
    return path


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8") as fh:
        return fh.read()


def read_json(path: str):
    return json.loads(read_text(path))
