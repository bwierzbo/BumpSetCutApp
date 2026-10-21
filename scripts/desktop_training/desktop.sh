#!/bin/zsh
# Train multi-frame models on the desktop GPU from the Mac, over SSH.
#
#   scripts/desktop_training/desktop.sh train [package] [--size 512|768|1024] [--from-scratch] [--color] [--epochs N] [--name NAME]
#                                              [--aug] [--occluded] [--qfl] [--mine] [--pseudo] [--seed N]
#                                              [--batch N] [--lr X] [--workers N] [--resume]
#                                              [--score-only C:\BallTraining\runs\heatmap\RUN\best.pt]
#       send the package (default: the newest multi-frame export) and the
#       current trainer, start training detached, return right away
#       (--score-only: score that checkpoint on the package's val windows
#       instead of training, for paired_compare.py; `wait`, `fetch` and
#       `run` work as for training — fetch brings the metrics and adds no model)
#   scripts/desktop_training/desktop.sh queue [same as train]
#       the same, but the run waits its turn: jobs run one after another
#       (queue_runner.ps1 on the desktop), after any training already on the GPU
#   scripts/desktop_training/desktop.sh status        what's running, the queue, the last lines of the log, GPU use
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
PROJECT=${RALLYLAB_PROJECT:-Scratch}
EXPORTS=~/Movies/RallyLab/Projects/$PROJECT/exports
INCOMING=~/Movies/RallyLab/Projects/$PROJECT/incoming
RALLYLAB=~/Library/Developer/Xcode/DerivedData/BumpSetCut-fzkpvtfecvgvhyapswwhkuwgrslu/Build/Products/Debug/RallyLab.app/Contents/MacOS/RallyLab

say() { print -r -- "$*" }
die() { print -r -- "❌ $*" >&2; exit 1 }
remote() { ssh -o BatchMode=yes -o LogLevel=ERROR $HOST "$@" }

newest_package() {
    ls -td $EXPORTS/*-multiframe-*.zip(N) 2>/dev/null | head -1
}

# The train/queue arguments → T_package T_zip T_name T_args (the trainer's
# arguments after the package, --name apart).
parse_train() {
    local package="" size=512 epochs=60 name="" scratch="" color="" opts=()
    while (( $# )); do
        case $1 in
            --size) size=$2; shift 2 ;;
            --from-scratch) scratch=--from-scratch; shift ;;
            --color) color=--color; shift ;;
            --aug|--occluded|--qfl|--mine|--pseudo|--resume) opts+=($1); shift ;;
            --seed|--batch|--lr|--workers|--score-only) opts+=($1 $2); shift 2 ;;
            --epochs) epochs=$2; shift 2 ;;
            --name) name=$2; shift 2 ;;
            *) package=$1; shift ;;
        esac
    done
    [[ -n $package ]] || package=$(newest_package)
    [[ -f $package ]] || die "No multi-frame package zip (export one in RallyLab's Models tab)."
    local stem=${package:t:r}
    [[ -n $name ]] || name="heat_${stem##*-multiframe-}_${size}${scratch:+_scratch}${color:+_color}"
    T_package=$package; T_zip=${package:t}; T_name=$name
    T_args="--size $size --epochs $epochs $scratch $color ${opts[*]}"
    T_summary="${size}, ${epochs} epochs${scratch:+, from scratch}${color:+, colour}${opts:+, ${opts[*]}}"
}

# The package and the current trainer on the desktop (the package only once).
send_package() {
    local zip=$T_zip stem=${T_package:t:r}
    if remote "if (Test-Path '$REMOTE\\$zip') { 'yes' } else { 'no' }" | grep -q yes; then
        say "Already on the desktop."
    else
        say "Freeing space: removing older packages on the desktop…"
        remote "Get-ChildItem '$REMOTE' -Filter '*-multiframe-*.zip' | Where-Object Name -ne '$zip' | Remove-Item -Force;
                Get-ChildItem '$REMOTE\\prepared' -Directory -Filter '*-multiframe-*' -ErrorAction SilentlyContinue | Where-Object Name -ne '$stem' | Remove-Item -Recurse -Force"
        say "Sending $(du -h $T_package | cut -f1) over the network…"
        scp -o BatchMode=yes -o LogLevel=ERROR $T_package "$HOST:C:/BallTraining/$zip"
    fi
    scp -o BatchMode=yes -o LogLevel=ERROR $HERE/train_heatmap_model.py "$HOST:C:/BallTraining/train_heatmap_model.py"
    scp -o BatchMode=yes -o LogLevel=ERROR $HERE/queue_runner.ps1 "$HOST:C:/BallTraining/queue_runner.ps1"
    # Not `… && die`: under set -e a failed last-command-of-a-list ends the function with 1, which ends the script.
    if remote "if (Test-Path '$REMOTE\\runs\\heatmap\\$T_name') { 'exists' }" | grep -q exists; then
        die "Run \"$T_name\" already exists on the desktop — pass --name."
    fi
}

cmd_train() {
    local T_package T_zip T_name T_args T_summary
    parse_train "$@"
    say "Package: $T_zip  →  run \"$T_name\" ($T_summary)"
    send_package
    # Started through WMI so it isn't tied to this SSH session: it keeps
    # training after we disconnect (and survives the Mac going to sleep).
    local log="$REMOTE\\$T_name.log"
    remote "\$cmd = 'cmd /c cd /d $REMOTE && set PYTHONUNBUFFERED=1 && \"$PY\" train_heatmap_model.py $T_zip $T_args --name $T_name > \"$log\" 2>&1';
            \$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = \$cmd; CurrentDirectory = '$REMOTE' };
            if (\$r.ReturnValue -ne 0) { throw \"start failed: \$(\$r.ReturnValue)\" }; 'started pid ' + \$r.ProcessId"
    say "Training on the desktop. Follow it with: $SCRIPT wait $T_name"
}

# Queue the run: a line for queue_runner.ps1, which is started if it isn't up.
cmd_queue() {
    local T_package T_zip T_name T_args T_summary
    parse_train "$@"
    say "Package: $T_zip  →  run \"$T_name\" ($T_summary), queued"
    send_package
    remote "Add-Content '$REMOTE\\queue.txt' '$T_name|$T_zip|$T_args';
            \$up = Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { \$_.CommandLine -like '*-File*queue_runner.ps1*' -and \$_.ProcessId -ne \$PID };
            if (\$up) { 'runner already up' } else {
              \$cmd = 'cmd /c powershell -NoProfile -ExecutionPolicy Bypass -File $REMOTE\\queue_runner.ps1 > $REMOTE\\queue_runner.out 2>&1';
              \$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = \$cmd; CurrentDirectory = '$REMOTE' };
              if (\$r.ReturnValue -ne 0) { throw \"runner start failed: \$(\$r.ReturnValue)\" }; 'runner started pid ' + \$r.ProcessId }"
    say "Queued. Follow it with: $SCRIPT wait $T_name   (the queue: $SCRIPT status)"
}

cmd_status() {
    remote "\$p = Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object CommandLine -like '*train_heatmap_model*';
            if (\$p) { \$p | ForEach-Object { 'running: ' + (\$_.CommandLine -replace '.*train_heatmap_model.py ', '') } | Select-Object -Unique } else { 'no training running' };
            \$q = if (Test-Path '$REMOTE\\queue.txt') { @(Get-Content '$REMOTE\\queue.txt' | Where-Object { \$_.Trim() -ne '' }) } else { @() };
            \$up = Get-CimInstance Win32_Process -Filter \"Name='powershell.exe'\" | Where-Object { \$_.CommandLine -like '*-File*queue_runner.ps1*' -and \$_.ProcessId -ne \$PID };
            'queue: ' + \$q.Count + ' waiting' + \$(if (\$up) { ' (runner up)' } else { '' });
            \$q | ForEach-Object { '  ' + \$_ };
            nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total --format=csv,noheader;
            \$l = Get-ChildItem '$REMOTE\\*.log' | Where-Object Name -notlike 'queue_runner*' | Sort-Object LastWriteTime | Select-Object -Last 1;
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
    if [[ ! -f $INCOMING/$name/best.pt ]]; then
        say "Scored only (--score-only): metrics in $INCOMING/$name/metrics.json, no model to add."
        return 0
    fi
    [[ $score != --no-score ]] || return 0
    [[ -x $RALLYLAB ]] || { say "RallyLab isn't built — add $INCOMING/$name in the Models tab."; return 0; }
    local backup=$(mktemp)
    defaults export app.BumpSetCut.RallyLab $backup
    $RALLYLAB --project $PROJECT --add-heat $INCOMING/$name 2>&1 | grep -E "Saved|❌" || true
    $RALLYLAB --project $PROJECT --score-heat 2>&1 | grep -E "F1|frames|ms a window|❌" || true
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
    queue) shift; cmd_queue "$@" ;;
    status) cmd_status ;;
    wait) shift; cmd_wait "$@" ;;
    fetch) shift; cmd_fetch "$@" ;;
    run) shift; cmd_run "$@" ;;
    *) sed -n '2,19p' $SCRIPT; exit 2 ;;
esac
