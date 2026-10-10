#!/bin/zsh
# Train multi-frame models on the desktop GPU from the Mac, over SSH.
#
#   scripts/desktop_training/desktop.sh train [package] [--size 512|768|1024] [--from-scratch] [--color] [--epochs N] [--name NAME]
#                                              [--aug] [--occluded] [--qfl] [--mine] [--seed N]
#       send the package (default: the newest multi-frame export) and the
#       current trainer, start training detached, return right away
#   scripts/desktop_training/desktop.sh status        what's running, the last lines of the log, GPU use
#   scripts/desktop_training/desktop.sh wait NAME     follow the log until the run finishes
#   scripts/desktop_training/desktop.sh fetch NAME [--no-score]
#       bring back bring_back/NAME, add it to RallyLab and score it (RallyLab's
#       own Train on Desktop passes --no-score and does that part itself)
#   scripts/desktop_training/desktop.sh run [args]    train + wait + fetch
#
# Needs the "bsc-desktop" host in ~/.ssh/config (key-only SSH to the PC).
# Old packages on the desktop are removed before a new one is sent (disk).

set -euo pipefail
HOST=bsc-desktop
REMOTE='C:\BallTraining'
PY='C:\BallTraining\.venv\Scripts\python.exe'
SCRIPT=${0:A}
HERE=${SCRIPT:h}
REPO=${HERE:h:h}
PROJECT=${RALLYLAB_PROJECT:-Test1}
EXPORTS=~/Movies/RallyLab/Projects/$PROJECT/exports
INCOMING=~/Movies/RallyLab/Projects/$PROJECT/incoming
RALLYLAB=~/Library/Developer/Xcode/DerivedData/BumpSetCut-fzkpvtfecvgvhyapswwhkuwgrslu/Build/Products/Debug/RallyLab.app/Contents/MacOS/RallyLab

say() { print -r -- "$*" }
die() { print -r -- "❌ $*" >&2; exit 1 }
remote() { ssh -o BatchMode=yes -o LogLevel=ERROR $HOST "$@" }

newest_package() {
    ls -td $EXPORTS/*-multiframe-*.zip(N) 2>/dev/null | head -1
}

cmd_train() {
    local package="" size=512 epochs=60 name="" scratch="" color="" opts=()
    while (( $# )); do
        case $1 in
            --size) size=$2; shift 2 ;;
            --from-scratch) scratch=--from-scratch; shift ;;
            --color) color=--color; shift ;;
            --aug|--occluded|--qfl|--mine) opts+=($1); shift ;;
            --seed) opts+=(--seed $2); shift 2 ;;
            --epochs) epochs=$2; shift 2 ;;
            --name) name=$2; shift 2 ;;
            *) package=$1; shift ;;
        esac
    done
    [[ -n $package ]] || package=$(newest_package)
    [[ -f $package ]] || die "No multi-frame package zip (export one in RallyLab's Models tab)."
    local zip=${package:t} stem=${package:t:r}
    [[ -n $name ]] || name="heat_${stem##*-multiframe-}_${size}${scratch:+_scratch}${color:+_color}"

    say "Package: $zip  →  run \"$name\" (${size}, ${epochs} epochs${scratch:+, from scratch})"
    if remote "if (Test-Path '$REMOTE\\$zip') { 'yes' } else { 'no' }" | grep -q yes; then
        say "Already on the desktop."
    else
        say "Freeing space: removing older packages on the desktop…"
        remote "Get-ChildItem '$REMOTE' -Filter '*-multiframe-*.zip' | Where-Object Name -ne '$zip' | Remove-Item -Force;
                Get-ChildItem '$REMOTE\\prepared' -Directory -Filter '*-multiframe-*' -ErrorAction SilentlyContinue | Where-Object Name -ne '$stem' | Remove-Item -Recurse -Force"
        say "Sending $(du -h $package | cut -f1) over the network…"
        scp -o BatchMode=yes -o LogLevel=ERROR $package "$HOST:C:/BallTraining/$zip"
    fi
    scp -o BatchMode=yes -o LogLevel=ERROR $HERE/train_heatmap_model.py "$HOST:C:/BallTraining/train_heatmap_model.py"
    remote "if (Test-Path '$REMOTE\\runs\\heatmap\\$name') { 'exists' }" | grep -q exists && die "Run \"$name\" already exists on the desktop — pass --name."

    # Started through WMI so it isn't tied to this SSH session: it keeps
    # training after we disconnect (and survives the Mac going to sleep).
    local log="$REMOTE\\$name.log"
    remote "\$cmd = 'cmd /c cd /d $REMOTE && set PYTHONUNBUFFERED=1 && \"$PY\" train_heatmap_model.py $zip --size $size --epochs $epochs --name $name $scratch $color ${opts[*]} > \"$log\" 2>&1';
            \$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = \$cmd; CurrentDirectory = '$REMOTE' };
            if (\$r.ReturnValue -ne 0) { throw \"start failed: \$(\$r.ReturnValue)\" }; 'started pid ' + \$r.ProcessId"
    say "Training on the desktop. Follow it with: $SCRIPT wait $name"
}

cmd_status() {
    remote "\$p = Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object CommandLine -like '*train_heatmap_model*';
            if (\$p) { \$p | ForEach-Object { 'running: ' + (\$_.CommandLine -replace '.*train_heatmap_model.py ', '') } } else { 'no training running' };
            nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader;
            \$l = Get-ChildItem '$REMOTE\\heat_*.log' | Sort-Object LastWriteTime | Select-Object -Last 1;
            if (\$l) { '--- ' + \$l.Name; Get-Content \$l.FullName -Tail 8 -Encoding UTF8 }"
}

cmd_wait() {
    local name=${1:?name}
    local log="$REMOTE\\$name.log" last="" tail=""
    while true; do
        tail=$(remote "if (Test-Path '$log') { Get-Content '$log' -Tail 3 -Encoding UTF8 } else { 'waiting for the log…' }" 2>/dev/null | tr -d '\r' || print "(connection hiccup)")
        if [[ $tail != "$last" ]]; then say "$tail" | grep -v '^$' | tail -1; last=$tail; fi
        if print -r -- "$tail" | grep -q "Done. Copy"; then say "✅ Finished."; return 0; fi
        if print -r -- "$tail" | grep -q "❌\|Traceback\|Error"; then
            remote "Get-Content '$log' -Tail 25 -Encoding UTF8"; die "Training stopped with an error."
        fi
        if ! remote "Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object CommandLine -like '*--name $name*'" | grep -q python; then
            remote "Get-Content '$log' -Tail 3 -Encoding UTF8" | grep -q "Done. Copy" && { say "✅ Finished."; return 0; }
            remote "Get-Content '$log' -Tail 25 -Encoding UTF8"; die "Training isn't running and didn't finish."
        fi
        sleep 30
    done
}

cmd_fetch() {
    local name=${1:?name} score=${2:-}
    mkdir -p $INCOMING
    rm -rf $INCOMING/$name
    scp -r -o BatchMode=yes -o LogLevel=ERROR "$HOST:C:/BallTraining/bring_back/$name" $INCOMING/
    scp -o BatchMode=yes -o LogLevel=ERROR "$HOST:C:/BallTraining/$name.log" $INCOMING/$name/ 2>/dev/null || true
    say "Brought back $INCOMING/$name"
    tr -d '\r' < $INCOMING/$name/$name.log 2>/dev/null | grep -A8 "^Best" | head -9 || true
    [[ $score != --no-score ]] || return 0
    [[ -x $RALLYLAB ]] || { say "RallyLab isn't built — add $INCOMING/$name in the Models tab."; return 0; }
    local backup=$(mktemp)
    defaults export app.BumpSetCut.RallyLab $backup
    $RALLYLAB --project $PROJECT --add-heat $INCOMING/$name --evaluate-heat 2>&1 | grep -E "Saved|Scor|^  |❌" || true
    defaults import app.BumpSetCut.RallyLab $backup
    rm -f $backup
}

cmd_run() {
    local out name
    out=$(cmd_train "$@" | tee /dev/stderr)
    name=$(print -r -- "$out" | sed -n 's/.*→  run "\([^"]*\)".*/\1/p')
    cmd_wait $name
    cmd_fetch $name
}

case ${1:-} in
    train) shift; cmd_train "$@" ;;
    status) cmd_status ;;
    wait) shift; cmd_wait "$@" ;;
    fetch) shift; cmd_fetch "$@" ;;
    run) shift; cmd_run "$@" ;;
    *) sed -n '2,15p' $SCRIPT; exit 2 ;;
esac
