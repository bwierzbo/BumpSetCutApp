#!/usr/bin/env python3
"""Visual provenance review for Task B.1 (decisions D-015 §2, §4; D-016).

Builds a local HTML page where the owner can look at representative frames of
each final-test candidate next to the training recordings that look like the
same outing, and of the Dianne Gan recordings (Q3), and record venue, session
and camera per recording plus a "same outing?" verdict per group.

Reads (never writes): <project>/project.json, <project>/manifests/manifest.json,
<project>/sessions/*.json, <project>/scrub_proxies/<video>.mp4 (RallyLab's
960-px review copies; the original footage is not touched or needed).

Writes only under <out> (default <project>/manifests/provenance-review/):
  frames/<video>/f<i>.jpg   representative frames (proxy resolution); source.json beside them records
                            which proxy, duration and times they came from (stale frames are remade)
  index.html                the review page (open locally)
  artifact.html             the same page for publishing as a private claude.ai artifact
                            (answers go to the artifact's store: answers/<video>, groups/<group>)
  mapping.json, mapping.md  thumbnail → recording, with timestamps and metadata
  groups.json               the groups as built (for reproducibility)
The owner's answers are never written here by this script: the page keeps a
draft in the browser and exports provenance-answers.json on demand, which the
owner saves separately (e.g. <out>/answers/). Nothing is inferred or confirmed.

Usage:
  scripts/provenance_review.py [--project ~/Movies/RallyLab/Projects/Scratch]
                               [--out DIR] [--frames 5] [--groups groups.json]
  scripts/provenance_review.py --answers provenance-answers.json [--project …]
      prints the `RallyLab --set-provenance` commands that the owner's
      *confirmed* answers would need, and the unsure/unknown ones as comments.
      Dry run only: it writes nothing and runs nothing.
Requires ffmpeg/ffprobe on PATH (not for --answers).
"""
import argparse, html, json, os, shlex, subprocess, sys
from datetime import datetime, timezone
from pathlib import Path

# The groups from docs/ml-roadmap/PROVENANCE_QUESTIONS_2026-10-21.md (Q1 and Q3).
# Edit or pass --groups to review others. Roles are descriptive only.
DEFAULT_GROUPS = [
    {"id": "Q1-bch_extra_self_05", "question": "Q1", "candidate": "bch_extra_self_05",
     "others": ["bch_extra_self_31", "bch_extra_self_30", "bch_extra_self_29"]},
    {"id": "Q1-bch_extra_self_18", "question": "Q1", "candidate": "bch_extra_self_18",
     "others": ["bch_extra_self_10", "bch_extra_self_02"]},
    {"id": "Q1-grs_extra_self_06", "question": "Q1", "candidate": "grs_extra_self_06",
     "others": ["grs_extra_self_12"]},
    {"id": "Q1-grs_extra_self_07", "question": "Q1", "candidate": "grs_extra_self_07",
     "others": ["grs_extra_self_02"]},
    {"id": "Q1-grs_extra_self_14", "question": "Q1", "candidate": "grs_extra_self_14",
     "others": ["grs_extra_self_15", "grs_extra_self_16"]},
    {"id": "Q1-grs_extra_self_21", "question": "Q1", "candidate": "grs_extra_self_21",
     "others": ["grs_extra_self_20"]},
    {"id": "Q1-ind_extra_self_09", "question": "Q1", "candidate": "ind_extra_self_09",
     "others": ["ind_extra_self_06"]},
    {"id": "Q3-dianne-gan", "question": "Q3", "candidate": None,
     "others": ["bch_onl_sun_land_onl_03", "bch_onl_sun_land_onl_03_v2", "grs_onl_sun_land_onl_04", "grs_sid_shade_land_self_02_v2"],
     "title": "Q3 — Dianne Gan recordings (legacy_holdout vs train)",
     "ask": "Are the two beach recordings (legacy_holdout) and the two grass recordings (train) from the same venue? Give a venueId for each venue you recognise."},
]

QUESTION_TEXT = {
    "Q1": "Were the candidate and the neighbouring training recordings filmed in the same outing (same venue, same day)? "
          "If yes, the candidate is not independent of training. Fill venue / session / camera for every recording you can; mark unknown otherwise.",
    "Q3": "",
}


def run(cmd):
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def probe(path):
    out = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
               "stream=width,height,r_frame_rate:format=duration", "-of", "json", str(path)])
    j = json.loads(out)
    st = j["streams"][0]
    num, den = st["r_frame_rate"].split("/")
    return {"width": st["width"], "height": st["height"],
            "fps": round(int(num) / int(den), 3) if int(den) else None,
            "duration": round(float(j["format"]["duration"]), 2)}


def extract(proxy, dest, n):
    """Frames at centred bins (10 %, 30 %, 50 %, 70 %, 90 % for n=5). Existing frames are reused only
    when source.json next to them records the same proxy (path, size, mtime), duration and times;
    otherwise every frame is made again, so a changed --frames or a replaced proxy never keeps stale images."""
    info = probe(proxy)
    st = proxy.stat()
    times = [round(info["duration"] * (i + 0.5) / n, 2) for i in range(n)]
    stamp = {"proxy": str(proxy), "size": st.st_size, "mtime": int(st.st_mtime), "duration": info["duration"],
             "frames": n, "times": times}
    marker = dest / "source.json"
    files = [{"file": f"f{i}.jpg", "time_s": t} for i, t in enumerate(times, 1)]
    current = None
    try:
        current = json.load(open(marker))
    except (OSError, ValueError):
        pass
    if current != stamp or not all((dest / f["file"]).exists() for f in files):
        dest.mkdir(parents=True, exist_ok=True)
        for old in dest.glob("f*.jpg"):
            old.unlink()
        for f in files:
            run(["ffmpeg", "-v", "error", "-y", "-ss", str(f["time_s"]), "-i", str(proxy), "-frames:v", "1", "-q:v", "3", str(dest / f["file"])])
        json.dump(stamp, open(marker, "w"), indent=1)
    return info, files


def load_project(project):
    p = json.load(open(project / "project.json"))
    sources = {}
    for c in p["clips"]:
        for v in c["videos"]:
            name = v.get("videoId") or c["id"]
            sources[name] = {"card": c["id"], "surface": c["environment"], "camera_card": c.get("camera"),
                             "lighting": c.get("lighting"), "orientation": c.get("orientation"), "card_split": c.get("split"),
                             "kind": v["kind"], "origin": v["origin"], "title": v.get("title"), "uploader": v.get("uploader"),
                             "license": v.get("license"), "fetchedAt": v.get("fetchedAt"), "start": v.get("start"),
                             "length": v.get("length"), "clipFile": v.get("clipFile"), "fingerprint": v.get("fingerprint"),
                             "sourceId": v.get("sourceId"), "sessionId": v.get("sessionId"), "venueId": v.get("venueId")}
    return sources


def load_manifest(project):
    m = project / "manifests" / "manifest.json"
    if not m.exists():
        return {}
    return {v["video"]: v for v in json.load(open(m))["videos"]}


def load_session(project, name):
    f = project / "sessions" / f"{name}.json"
    if not f.exists():
        return {}
    s = json.load(open(f))
    tracks = s.get("tracks") or []
    return {"addedAt": s.get("addedAt"), "frames": len(s.get("frames") or []),
            "machineTracks": sum(1 for t in tracks if t.get("machine")), "ralliesMarked": s.get("ralliesMarked")}


def role_of(name, group, manifest):
    if group.get("candidate") == name:
        return "candidate"
    split = (manifest.get(name) or {}).get("split")
    return {"train": "training", "legacy_holdout": "legacy holdout", "tune": "tune", "dev_val": "dev_val",
            "final_test_candidate": "candidate", "final_test": "final test"}.get(split, split or "?")


def build(project, out, n_frames, groups):
    sources = load_project(project)
    manifest = load_manifest(project)
    out.mkdir(parents=True, exist_ok=True)
    mapping = []
    built = []
    for g in groups:
        names = ([g["candidate"]] if g.get("candidate") else []) + g["others"]
        recs = []
        for name in names:
            src = sources.get(name, {})
            man = manifest.get(name, {})
            ses = load_session(project, name)
            proxy = project / "scrub_proxies" / f"{name}.mp4"
            rec = {"video": name, "role": role_of(name, g, manifest), "split": man.get("split"),
                   "exposure": sorted({e["kind"] for e in man.get("exposure", [])}),
                   "proxy": str(proxy.relative_to(project)) if proxy.exists() else None, "frames": [], "probe": None,
                   "meta": {**src, **ses}}
            if proxy.exists():
                info, files = extract(proxy, out / "frames" / name, n_frames)
                rec["probe"] = info
                rec["frames"] = files
                for fr in files:
                    mapping.append({"thumbnail": f"frames/{name}/{fr['file']}", "video": name, "time_s": fr["time_s"],
                                    "proxy": rec["proxy"], "source_file": os.path.basename(src.get("clipFile") or ""),
                                    "origin": src.get("origin"), "split": man.get("split"), "group": g["id"]})
            recs.append(rec)
        built.append({**g, "recordings": recs})
    json.dump(built, open(out / "groups.json", "w"), indent=1)
    json.dump(mapping, open(out / "mapping.json", "w"), indent=1)
    write_mapping_md(out, built, project)
    write_html(out, built, n_frames, project)
    write_html(out, built, n_frames, project, artifact=True)
    return built


def write_mapping_md(out, built, project):
    lines = ["# Thumbnail → recording mapping", "",
             f"Generated {datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')} from `{project}` review proxies (`scrub_proxies/`, 960 px). "
             "Frame times are seconds into the proxy, which is the same cut as the footage file. Nothing here is a provenance claim.", "",
             "| Group | Video | Role | Split | Source file | Origin | Proxy | Frames (s) | Exposure |", "|---|---|---|---|---|---|---|---|---|"]
    for g in built:
        for r in g["recordings"]:
            m = r["meta"]
            origin = m.get("origin") or ""
            origin_md = f"[link]({origin})" if origin.startswith("http") else os.path.basename(origin)
            lines.append(f"| {g['id']} | `{r['video']}` | {r['role']} | {r['split'] or '?'} | {os.path.basename(m.get('clipFile') or '') or '—'} | {origin_md} | "
                         f"{r['proxy'] or 'missing'} | {', '.join(str(f['time_s']) for f in r['frames']) or '—'} | {', '.join(r['exposure']) or 'none'} |")
    (out / "mapping.md").write_text("\n".join(lines) + "\n")


CSS = """
/* layout: one column of review groups; candidate first, neighbours below; sticky status bar */
:root{--bg:#fbfaf7;--fg:#1c1a16;--mut:#6b655b;--line:#dcd7cc;--cand:#fff1d2;--acc:#1f5fa8;--acc-soft:rgba(31,95,168,.08);--ok:#2f7d4f;--font:"IBM Plex Sans",-apple-system,system-ui,sans-serif;--mono:"IBM Plex Mono",ui-monospace,Menlo,monospace}
@media(prefers-color-scheme:dark){:root:not([data-theme="light"]){--bg:#171613;--fg:#ece8df;--mut:#a39c8f;--line:#38352e;--cand:#3a2d10;--acc:#7fb3f0;--acc-soft:rgba(127,179,240,.12);--ok:#7fcf9a;color-scheme:dark}}
:root[data-theme="dark"]{--bg:#171613;--fg:#ece8df;--mut:#a39c8f;--line:#38352e;--cand:#3a2d10;--acc:#7fb3f0;--acc-soft:rgba(127,179,240,.12);--ok:#7fcf9a;color-scheme:dark}
body{margin:0;padding-block:0 32px;padding-inline:16px;font:14px/1.45 var(--font);background:var(--bg);color:var(--fg)}
h1{font-size:20px;margin:12px 0 4px;text-wrap:balance} h2{font-size:16px;margin:28px 0 6px;padding-top:12px;border-top:1px solid var(--line);text-wrap:balance}
code,.mono{font-family:var(--mono);font-size:12.5px}
.hint{color:var(--mut)} .q{margin:6px 0 10px;padding:8px 10px;border-left:3px solid var(--acc);background:var(--acc-soft)}
.rec{display:grid;grid-template-columns:260px minmax(0,1fr);gap:12px;align-items:start;padding:10px;border:1px solid var(--line);border-radius:8px;margin:8px 0}
.rec.candidate{background:var(--cand)}
.meta{font-size:12.5px;min-width:0;overflow-wrap:anywhere} .meta b{font-size:14px} .meta div{margin:1px 0} .meta a{color:var(--acc)}
.frames{display:flex;flex-wrap:wrap;gap:6px;min-width:0} .frames img{height:170px;width:auto;max-width:100%;border-radius:4px;cursor:zoom-in;border:1px solid var(--line)} .frames.portrait img{height:300px}
.form{grid-column:1/-1;display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:8px;margin-top:6px}
label{display:block;font-size:12px;color:var(--mut)} input[type=text],textarea,select{width:100%;box-sizing:border-box;padding:8px;border:1px solid var(--line);border-radius:4px;background:var(--bg);color:var(--fg);font:inherit;font-size:16px}
input:focus,select:focus,textarea:focus,button:focus-visible{outline:2px solid var(--acc);outline-offset:1px}
.group-answer{margin:8px 0 0;padding:10px;border:1px dashed var(--line);border-radius:8px}
.bar{position:sticky;top:env(safe-area-inset-top,0px);background:var(--bg);padding:8px 0;border-bottom:1px solid var(--line);z-index:2;display:flex;gap:8px;flex-wrap:wrap;align-items:center}
button{padding:7px 12px;border:1px solid var(--acc);background:var(--acc);color:#fff;border-radius:6px;font:inherit;cursor:pointer} button.sec{background:transparent;color:var(--acc)}
#lb{display:none;position:fixed;inset:0;background:rgba(0,0,0,.92);z-index:9;align-items:center;justify-content:center;flex-direction:column;gap:8px} #lb img{max-width:96vw;max-height:88vh} #lb div{color:#ddd;font-size:13px}
.role{display:inline-block;padding:1px 6px;border-radius:10px;font-size:11px;background:var(--line)}
.saved{color:var(--ok)}
@media(max-width:640px){.rec{grid-template-columns:1fr}.frames img{height:150px}.frames.portrait img{height:260px}}
@media(prefers-reduced-motion:no-preference){.frames img{transition:transform .15s}.frames img:hover{transform:scale(1.02)}}
"""

INTRO = """<p class="hint">Frames are from RallyLab's 960-px review proxies of each recording; tap a frame to enlarge. Nothing on this page is pre-filled or inferred: every field starts empty and <em>unknown</em> is always acceptable. Only answers with status <em>confirmed</em> will ever be written to the project, with <code>--set-provenance</code> in a reviewed PR; <em>unsure</em> and <em>unknown</em> are recorded as such and never confirm anything.</p>"""

LOCAL_HEAD = """<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Scratch Provenance Review</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;600&family=IBM+Plex+Mono&display=swap">
<style>{css}</style></head><body>
<div class="bar"><strong>Provenance review — Task B.1</strong>
<button class="sec" onclick="save()">Save draft (browser)</button>
<button onclick="exportAnswers()">Download answers JSON</button>
<button class="sec" onclick="document.getElementById('f').click()">Load answers JSON</button><input id="f" type="file" accept="application/json" style="display:none" onchange="loadAnswers(this)">
<span id="status" class="hint"></span></div>
<h1>Visual provenance review</h1>
{intro}
<p class="hint">Your answers stay in this browser until you download them. Project: <code>{project}</code>. Candidates are shaded. Split and exposure are from the current manifest.</p>
"""

ARTIFACT_HEAD = """<title>Scratch Provenance Review</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;600&family=IBM+Plex+Mono&display=swap">
<style>{css}</style>
<div class="bar"><strong>Provenance review — Task B.1</strong>
<button class="sec" onclick="copyAnswers()">Copy answers as JSON</button>
<span id="status" class="hint">loading saved answers…</span></div>
<h1>Visual provenance review</h1>
{intro}
<p class="hint">Answers save to this page's private store as you type (the status line confirms each save) and are read back by Claude Code; nothing else sees them. Project on the Mac: <code>{project}</code>. Candidates are shaded. Split and exposure are from the current manifest.</p>
"""

LOCAL_SCRIPT = """
<h2>Export</h2><p class="hint">Download answers JSON writes <code>provenance-answers.json</code> with every field as you left it (empty = not answered). Keep it outside the frames folder, e.g. <code>answers/</code> next to this page, and hand it over.</p>
<script>
const KEY='bumpsetcut.provenance.answers.v1';
function fields(){return [...document.querySelectorAll('[data-k]')]}
function collect(){const a={};for(const f of fields()){a[f.dataset.k]=f.value}return a}
function apply(a){for(const f of fields()){if(a[f.dataset.k]!==undefined)f.value=a[f.dataset.k]}}
function save(){try{localStorage.setItem(KEY,JSON.stringify(collect()));st('draft saved in this browser')}catch(e){st('could not save draft: '+e)}}
function exportAnswers(){const a=collect();const out={schema:'provenance-answers/1',exportedAt:new Date().toISOString(),answers:a};const b=new Blob([JSON.stringify(out,null,1)],{type:'application/json'});const u=URL.createObjectURL(b);const l=document.createElement('a');l.href=u;l.download='provenance-answers.json';l.click();URL.revokeObjectURL(u);save();st('downloaded provenance-answers.json')}
function loadAnswers(inp){const r=new FileReader();r.onload=()=>{try{const j=JSON.parse(r.result);apply(j.answers||j);st('answers loaded')}catch(e){st('not a valid answers file')}};r.readAsText(inp.files[0])}
function zoom(img,cap){document.getElementById('lbi').src=img.src;document.getElementById('lbc').textContent=cap;document.getElementById('lb').style.display='flex'}
function st(m){document.getElementById('status').textContent=m}
try{const d=localStorage.getItem(KEY);if(d){apply(JSON.parse(d));st('draft restored from this browser')}}catch(e){}
for(const f of fields()){f.addEventListener('change',save)}
</script></body></html>"""

# Artifact store layout: one document per recording at answers/<video> and one per group at groups/<groupId>,
# each holding its fields plus updatedAt. Claude reads them with the ArtifactData tool.
ARTIFACT_SCRIPT = """
<script>
function fields(){return [...document.querySelectorAll('[data-k]')]}
function collect(){const a={};for(const f of fields()){a[f.dataset.k]=f.value}return a}
function apply(a){for(const f of fields()){if(a[f.dataset.k]!==undefined)f.value=a[f.dataset.k]}}
function zoom(img,cap){document.getElementById('lbi').src=img.src;document.getElementById('lbc').textContent=cap;document.getElementById('lb').style.display='flex'}
function st(m,ok){const s=document.getElementById('status');s.textContent=m;s.className=ok?'saved':'hint'}
function copyAnswers(){const out={schema:'provenance-answers/1',exportedAt:new Date().toISOString(),answers:collect()};const t=JSON.stringify(out,null,1);navigator.clipboard.writeText(t).then(()=>st('answers copied to the clipboard',true)).catch(()=>{const ta=document.createElement('textarea');ta.value=t;document.body.appendChild(ta);ta.select();st('select and copy the text below');});}
function docKey(k){if(k.startsWith('group.')){const [,gid,field]=k.split('.',3);return ['groups/'+gid,field]}const i=k.lastIndexOf('.');return ['answers/'+k.slice(0,i),k.slice(i+1)]}
function docFields(path){const o={};for(const f of fields()){const [p,field]=docKey(f.dataset.k);if(p===path)o[field]=f.value}return o}
let db=null;const queue={};const timers={};
function flush(path){const data={...docFields(path),updatedAt:new Date().toISOString()};queue[path]=(queue[path]||Promise.resolve()).then(()=>db.doc(path).set(data)).then(()=>st('saved '+path.split('/')[1]+' · '+new Date().toLocaleTimeString(),true)).catch(e=>st('not saved ('+(e.code||e)+'); keep the page open and retry, or copy answers as JSON'))}
function scheduleSave(path){clearTimeout(timers[path]);timers[path]=setTimeout(()=>flush(path),700)}
function setReadOnly(msg){for(const f of fields()){f.disabled=true}st(msg)}
(async()=>{db=await window.claude?.use?.('db');if(!db){setReadOnly('this view cannot save answers; open the page from your claude.ai account');return}
 const user=await window.claude.use('user');const w=user?await user.can('data.write'):null;if(w===false){setReadOnly('read-only view: only the owner can answer');return}
 try{const a={};for(const col of ['answers','groups']){const snap=await db.collection(col).get();for(const d of snap.docs){const body=d.data()||{};for(const [k,v] of Object.entries(body)){if(k==='updatedAt')continue;a[col==='groups'?'group.'+d.id+'.'+k:d.id+'.'+k]=v}}}
  apply(a);const n=Object.values(a).filter(Boolean).length;st(n?('loaded '+n+' saved values'):'no answers saved yet',n>0)}catch(e){st('could not load saved answers ('+(e.code||e)+')')}
 for(const f of fields()){f.addEventListener('input',()=>scheduleSave(docKey(f.dataset.k)[0]));f.addEventListener('change',()=>scheduleSave(docKey(f.dataset.k)[0]))}
})();
</script>"""


def write_html(out, built, n_frames, project, artifact=False):
    esc = html.escape
    head = (ARTIFACT_HEAD if artifact else LOCAL_HEAD).format(css=CSS, intro=INTRO, project=esc(str(project)))
    parts = [head, '<div id="lb" onclick="this.style.display=\'none\'"><img id="lbi" src="" alt=""><div id="lbc"></div></div>']
    for g in built:
        title = g.get("title") or f"{g['question']} — candidate {g['candidate']}"
        ask = g.get("ask") or QUESTION_TEXT.get(g["question"], "")
        parts.append(f'<h2 id="{esc(g["id"])}">{esc(title)}</h2>')
        if ask:
            parts.append(f'<div class="q">{esc(ask)}</div>')
        for r in g["recordings"]:
            m = r["meta"]
            origin = m.get("origin") or ""
            origin_html = f'<a href="{esc(origin)}" target="_blank" rel="noopener">{esc(origin)}</a>' if origin.startswith("http") else esc(os.path.basename(origin))
            probe = r["probe"] or {}
            parts.append(f'<div class="rec {"candidate" if r["role"] == "candidate" else ""}" data-video="{esc(r["video"])}">')
            parts.append('<div class="meta">')
            parts.append(f'<b class="mono">{esc(r["video"])}</b> <span class="role">{esc(r["role"])}</span>')
            parts.append(f'<div>split: <b>{esc(r["split"] or "?")}</b> · card: {esc(m.get("card") or "—")} ({esc(m.get("surface") or "?")}, {esc(m.get("camera_card") or "?")}, {esc(m.get("lighting") or "?")})</div>')
            parts.append(f'<div>source file: {esc(os.path.basename(m.get("clipFile") or "") or "—")}</div>')
            parts.append(f'<div>origin: {origin_html}</div>')
            if m.get("title") and m.get("kind") == "link":
                parts.append(f'<div>title: {esc(m["title"])} · uploader: {esc(m.get("uploader") or "—")}</div>')
            parts.append(f'<div>fetched: {esc((m.get("fetchedAt") or "—")[:19])} · added to dataset: {esc((m.get("addedAt") or "—")[:19])}</div>')
            if probe:
                parts.append(f'<div>proxy: {probe["width"]}×{probe["height"]}, {probe["duration"]} s, {probe["fps"]} fps · cut: start {m.get("start")} s, length {m.get("length")} s</div>')
            parts.append(f'<div>machine tracks: {m.get("machineTracks", "—")} · exposure: {esc(", ".join(r["exposure"]) or "none")}</div>')
            parts.append(f'<div>confirmed now: venue {esc(m.get("venueId") or "—")} · session {esc(m.get("sessionId") or "—")} · source {esc(m.get("sourceId") or "—")}</div>')
            portrait = bool(probe) and probe["height"] > probe["width"]
            parts.append(f'</div><div class="frames{" portrait" if portrait else ""}">')
            if r["frames"]:
                for fr in r["frames"]:
                    src = f'frames/{r["video"]}/{fr["file"]}'
                    parts.append(f'<img src="{esc(src)}" loading="lazy" alt="{esc(r["video"])} at {fr["time_s"]} s" onclick="zoom(this,\'{esc(r["video"])} — {fr["time_s"]} s\')">')
            else:
                parts.append('<span class="hint">no review proxy on this Mac</span>')
            parts.append('</div>')
            v = esc(r["video"])
            parts.append(f'''<div class="form">
<div><label for="{v}-venue">venueId (your stable name, e.g. beach-huntington-pier)</label><input id="{v}-venue" type="text" autocapitalize="none" autocorrect="off" data-k="{v}.venueId"></div>
<div><label for="{v}-session">sessionId (outing: date + tag, e.g. 2026-07-14-pm)</label><input id="{v}-session" type="text" autocapitalize="none" autocorrect="off" data-k="{v}.sessionId"></div>
<div><label for="{v}-camera">camera / mount</label><input id="{v}-camera" type="text" data-k="{v}.camera"></div>
<div><label for="{v}-status">status</label><select id="{v}-status" data-k="{v}.status"><option value="">—</option><option value="confirmed">confirmed (I know this)</option><option value="unsure">unsure</option><option value="unknown">unknown</option></select></div>
<div style="grid-column:1/-1"><label for="{v}-notes">notes</label><input id="{v}-notes" type="text" data-k="{v}.notes"></div>
</div></div>''')
        gid = esc(g["id"])
        parts.append(f'''<div class="group-answer"><label for="{gid}-same"><b>Same outing?</b> Do the recordings in this group come from the same venue and session?</label>
<select id="{gid}-same" data-k="group.{gid}.sameOuting"><option value="">—</option><option value="same">yes — same venue and session</option><option value="same-venue">same venue, different session</option><option value="different">different venues</option><option value="unknown">unknown</option></select>
<label for="{gid}-pref" style="margin-top:6px">If the candidate is not independent, what would you prefer?</label>
<select id="{gid}-pref" data-k="group.{gid}.preference"><option value="">—</option><option value="drop-candidate">drop the candidate (stays protected, never final test)</option><option value="move-training">move the training recordings out of train (needs their own exposure review)</option><option value="n/a">not applicable</option></select>
<label for="{gid}-notes" style="margin-top:6px">group notes</label><textarea id="{gid}-notes" rows="2" data-k="group.{gid}.notes"></textarea></div>''')
    parts.append(ARTIFACT_SCRIPT if artifact else LOCAL_SCRIPT)
    (out / ("artifact.html" if artifact else "index.html")).write_text("\n".join(parts))


def print_answer_plan(answers_path, project):
    """Dry run: translate an exported provenance-answers.json into the CLI calls it implies."""
    doc = json.load(open(answers_path))
    if doc.get("schema") != "provenance-answers/1":
        sys.exit(f"{answers_path}: not a provenance-answers/1 file")
    answers = doc["answers"]
    per_video, groups = {}, {}
    for key, value in answers.items():
        value = (value or "").strip()
        if key.startswith("group."):
            _, gid, field = key.split(".", 2)
            groups.setdefault(gid, {})[field] = value
        else:
            video, field = key.rsplit(".", 1)
            per_video.setdefault(video, {})[field] = value
    print(f"# answers exported {doc.get('exportedAt')}; dry run, nothing written")
    for video, f in sorted(per_video.items()):
        status = f.get("status") or "(no status)"
        if status == "confirmed" and (f.get("venueId") or f.get("sessionId")):
            args = []
            if f.get("venueId"):
                args += ["--venue-id", f["venueId"]]
            if f.get("sessionId"):
                args += ["--session-id", f["sessionId"]]
            note = f"   # camera: {f['camera']}" if f.get("camera") else ""
            print(shlex.join(["RallyLab", "--project", project.name, "--set-provenance", video] + args) + note)
        else:
            print(f"# {video}: {status}; venue={f.get('venueId') or '—'} session={f.get('sessionId') or '—'} — not applied"
                  + (f" ({f['notes']})" if f.get("notes") else ""))
    for gid, f in sorted(groups.items()):
        print(f"# group {gid}: same outing = {f.get('sameOuting') or '—'}; preference = {f.get('preference') or '—'}"
              + (f"; notes: {f['notes']}" if f.get("notes") else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--project", default=os.path.expanduser("~/Movies/RallyLab/Projects/Scratch"))
    ap.add_argument("--out", default=None)
    ap.add_argument("--frames", type=int, default=5)
    ap.add_argument("--groups", default=None, help="JSON file with the groups (default: the Q1/Q3 groups of 2026-10-21)")
    ap.add_argument("--answers", default=None, help="dry run: print the --set-provenance commands an exported answers file implies")
    a = ap.parse_args()
    project = Path(a.project).expanduser()
    if a.answers:
        print_answer_plan(a.answers, project)
        return
    out = Path(a.out).expanduser() if a.out else project / "manifests" / "provenance-review"
    groups = json.load(open(a.groups)) if a.groups else DEFAULT_GROUPS
    for tool in ("ffmpeg", "ffprobe"):
        if subprocess.run(["which", tool], capture_output=True).returncode != 0:
            sys.exit(f"{tool} not found on PATH")
    built = build(project, out, a.frames, groups)
    n = sum(len(r["frames"]) for g in built for r in g["recordings"])
    missing = [r["video"] for g in built for r in g["recordings"] if not r["frames"]]
    print(f"{len(built)} groups, {sum(len(g['recordings']) for g in built)} recordings, {n} frames → {out}/index.html")
    if missing:
        print("no proxy for:", ", ".join(missing))


if __name__ == "__main__":
    main()
