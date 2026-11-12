#!/usr/bin/env python3
"""Writes review.html into a court-review folder (RallyLab --player-lab-court ... --make-review): a local page to label
each detected person and count missed players, then export the filled persons.csv and frames.csv. Stdlib only; the
page needs no network. Labels are the reviewer's own; the page fills nothing in by itself.

usage: make_review_page.py <review-folder>
"""
import csv
import html
import json
import os
import sys

LABELS = [
    ("near_court", "Near court"), ("far_court", "Far court"), ("near_serving_area", "Near serving"), ("far_serving_area", "Far serving"),
    ("player_off_court", "Player off court"), ("spectator", "Spectator"), ("adjacent_court", "Adjacent court"),
    ("referee_or_other", "Referee/other"), ("duplicate_or_not_a_person", "Duplicate / not a person"), ("unsure", "Unsure"),
]


def read(path):
    with open(path, newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def build(folder):
    persons = read(os.path.join(folder, "persons.csv"))
    frames = read(os.path.join(folder, "frames.csv"))
    data = {"labels": LABELS, "persons": persons, "frames": frames,
            "personsHeader": list(persons[0].keys()) if persons else [], "framesHeader": list(frames[0].keys()) if frames else []}
    page = PAGE.replace("__DATA__", json.dumps(data).replace("</", "<\\/")).replace("__TITLE__", html.escape(os.path.basename(folder.rstrip("/"))))
    out = os.path.join(folder, "review.html")
    with open(out, "w", encoding="utf-8") as f:
        f.write(page)
    return out


PAGE = r"""<!doctype html><html lang=en><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<title>Court Review Sheet</title>
<style>
:root{--bg:#fff;--fg:#1b1d21;--mute:#5f6670;--line:#d9dde3;--card:#f6f7f9;--acc:#0b6bcb;--ok:#1a7f37}
@media (prefers-color-scheme:dark){:root{--bg:#121417;--fg:#e8eaed;--mute:#9aa1ab;--line:#2c3138;--card:#1a1d21;--acc:#6db3ff;--ok:#57c27a}}
body{background:var(--bg);color:var(--fg);font:14px/1.45 -apple-system,system-ui,sans-serif;margin:0 auto;max-width:1300px;padding:16px}
h1{font-size:20px;margin:0 0 4px} .m{color:var(--mute);font-size:12px}
.bar{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);padding:8px 0;z-index:5;display:flex;gap:10px;flex-wrap:wrap;align-items:center}
button{font:inherit;padding:5px 10px;border-radius:6px;border:1px solid var(--line);background:var(--card);color:var(--fg);cursor:pointer}
button.primary{background:var(--acc);color:#fff;border-color:var(--acc)}
.frame{display:grid;grid-template-columns:minmax(0,3fr) minmax(260px,1fr);gap:12px;border:1px solid var(--line);border-radius:10px;padding:10px;margin:14px 0;background:var(--card)}
@media (max-width:800px){.frame{grid-template-columns:1fr}}
.pic{position:relative} .pic img{width:100%;display:block;border-radius:6px}
.hit{position:absolute;border:2px solid transparent;cursor:pointer} .hit.sel{border-color:#fff;box-shadow:0 0 0 2px #000}
.hit.done{background:rgba(26,127,55,.18)}
table{border-collapse:collapse;width:100%;font-size:12px} td{padding:2px 4px;border-bottom:1px solid var(--line)}
tr.sel td{background:rgba(11,107,203,.15)} select,input{font:inherit;max-width:100%} input[type=number]{width:4em}
.keys{font-size:12px;color:var(--mute)} kbd{border:1px solid var(--line);border-radius:3px;padding:0 3px}
</style></head><body>
<h1>Court review — __TITLE__</h1>
<p class=m>Label every numbered box: what is this person? Then count players of this game with no box at all. Your labels are saved in this browser as you go; export the two CSVs into the review folder when done. Nothing is pre-filled.</p>
<div class=bar><label>Reviewer <input id=reviewer placeholder="your name" size=14></label>
<span id=progress class=m></span><button class=primary id=export>Export persons.csv + frames.csv</button>
<span class=keys>Click a box (or row), then press <kbd>1</kbd>–<kbd>9</kbd>, <kbd>0</kbd>=unsure · <kbd>↓</kbd>/<kbd>↑</kbd> next/previous</span></div>
<div id=frames></div>
<script>
const D = __DATA__;
const KEY = "court-review:" + document.title + ":" + location.pathname;
let state = {};
try { state = JSON.parse(localStorage.getItem(KEY) || "{}"); } catch (e) { state = {}; }
const save = () => { try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) {} };
const pid = p => p.recording + "|" + p.tick + "|" + p.track;
const fid = f => f.recording + "|" + f.tick;
const rev = document.getElementById("reviewer");
rev.value = state.reviewer || ""; rev.oninput = () => { state.reviewer = rev.value; save(); };
const order = [];
let current = null;
function select(id) {
  document.querySelectorAll(".sel").forEach(e => e.classList.remove("sel"));
  current = id;
  document.querySelectorAll('[data-id="' + CSS.escape(id) + '"]').forEach(e => e.classList.add("sel"));
  const row = document.querySelector('tr[data-id="' + CSS.escape(id) + '"]');
  if (row) row.scrollIntoView({block: "nearest"});
}
function setLabel(id, v) {
  state["p:" + id] = v; save();
  const sel = document.querySelector('select[data-id="' + CSS.escape(id) + '"]'); if (sel) sel.value = v;
  document.querySelectorAll('.hit[data-id="' + CSS.escape(id) + '"]').forEach(e => e.classList.toggle("done", !!v));
  progress();
}
function progress() {
  const n = D.persons.filter(p => state["p:" + pid(p)]).length;
  const f = D.frames.filter(x => state["n:" + fid(x)] !== undefined && state["f:" + fid(x)] !== undefined).length;
  document.getElementById("progress").textContent = n + "/" + D.persons.length + " people labelled · " + f + "/" + D.frames.length + " frames counted";
}
const host = document.getElementById("frames");
for (const f of D.frames) {
  const ps = D.persons.filter(p => p.recording === f.recording && p.tick === f.tick);
  const wrap = document.createElement("section"); wrap.className = "frame";
  const pic = document.createElement("div"); pic.className = "pic";
  const img = document.createElement("img"); img.src = f.image; img.loading = "lazy"; pic.appendChild(img);
  for (const p of ps) {
    const id = pid(p); order.push(id);
    const x = +p.box_x, y = +p.box_y, w = +p.box_w, h = +p.box_h;
    const b = document.createElement("div"); b.className = "hit" + (state["p:" + id] ? " done" : ""); b.dataset.id = id;
    b.style.left = (Math.max(0, x) * 100) + "%"; b.style.width = (Math.min(1, x + w) - Math.max(0, x)) * 100 + "%";
    b.style.top = ((1 - Math.min(1, y + h)) * 100) + "%"; b.style.height = (Math.min(1, y + h) - Math.max(0, y)) * 100 + "%";
    b.onclick = () => select(id); pic.appendChild(b);
  }
  const side = document.createElement("div");
  side.innerHTML = '<div class=m>' + f.recording + ' · ' + f.interval + ' · t=' + f.t + ' s</div>';
  const t = document.createElement("table");
  for (const p of ps) {
    const id = pid(p);
    const tr = document.createElement("tr"); tr.dataset.id = id; tr.onclick = () => select(id);
    const opts = '<option value="">—</option>' + D.labels.map((l, i) => '<option value="' + l[0] + '">' + (i < 9 ? (i + 1) : 0) + ' ' + l[1] + '</option>').join("");
    tr.innerHTML = '<td>#' + p.track + '</td><td><select data-id="' + id + '">' + opts + '</select></td>';
    const s = tr.querySelector("select"); s.value = state["p:" + id] || ""; s.onchange = () => setLabel(id, s.value);
    t.appendChild(tr);
  }
  side.appendChild(t);
  const miss = document.createElement("div");
  miss.innerHTML = '<p class=m>Players of this game with <b>no box</b>:</p><label>near <input type=number min=0 size=3 data-k=n></label> <label>far <input type=number min=0 size=3 data-k=f></label>';
  miss.querySelectorAll("input").forEach(inp => {
    const k = inp.dataset.k + ":" + fid(f); if (state[k] !== undefined) inp.value = state[k];
    inp.oninput = () => { if (inp.value === "") delete state[k]; else state[k] = inp.value; save(); progress(); };
  });
  side.appendChild(miss);
  wrap.appendChild(pic); wrap.appendChild(side); host.appendChild(wrap);
}
document.addEventListener("keydown", e => {
  if (e.target.tagName === "INPUT") return;
  if (!current) return;
  const i = order.indexOf(current);
  if (e.key === "ArrowDown" || e.key === "ArrowUp") { e.preventDefault(); const j = i + (e.key === "ArrowDown" ? 1 : -1); if (order[j]) select(order[j]); return; }
  const n = "1234567890".indexOf(e.key);
  if (n >= 0 && D.labels[n]) { setLabel(current, D.labels[n][0]); if (order[i + 1]) select(order[i + 1]); }
});
function csvCell(v) { v = String(v ?? ""); return /[",\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v; }
function download(name, rows) {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(new Blob([rows.map(r => r.map(csvCell).join(",")).join("\n") + "\n"], {type: "text/csv"}));
  a.download = name; a.click();
}
document.getElementById("export").onclick = () => {
  const who = rev.value.trim();
  if (!who) { rev.focus(); rev.placeholder = "name needed to export"; return; }
  download("persons.csv", [D.personsHeader].concat(D.persons.map(p => D.personsHeader.map(h =>
    h === "label" ? (state["p:" + pid(p)] || "") : h === "reviewer" ? (state["p:" + pid(p)] ? who : "") : p[h]))));
  download("frames.csv", [D.framesHeader].concat(D.frames.map(f => D.framesHeader.map(h =>
    h === "missed_near_players" ? (state["n:" + fid(f)] ?? "") : h === "missed_far_players" ? (state["f:" + fid(f)] ?? "") :
    h === "reviewer" ? ((state["n:" + fid(f)] !== undefined || state["f:" + fid(f)] !== undefined) ? who : "") : f[h]))));
};
progress();
</script></body></html>"""


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    print(build(sys.argv[1]))
