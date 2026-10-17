# queue_runner.ps1: runs the training jobs queued in C:\BallTraining\queue.txt
# one after another, then exits. desktop.sh queue appends a job and starts
# this (detached) when it isn't running; a job is one line:
#     NAME|PACKAGE.zip|<train_heatmap_model.py arguments>
# A job starts only when no other training is on the GPU (a chain started
# some other way included). Done jobs go to queue_done.txt with their exit
# code; the runner's own log is queue_runner.log.
$root = 'C:\BallTraining'
$queue = "$root\queue.txt"
$done = "$root\queue_done.txt"
$py = "$root\.venv\Scripts\python.exe"
Set-Location $root
$env:PYTHONUNBUFFERED = '1'

function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Add-Content "$root\queue_runner.log" }
function TrainingBusy {
    $p = Get-CimInstance Win32_Process -Filter "Name='python.exe'" | Where-Object { $_.CommandLine -like '*train_heatmap_model*' }
    return [bool]$p
}

Log "runner up"
while ($true) {
    $lines = @()
    if (Test-Path $queue) { $lines = @(Get-Content $queue | Where-Object { $_.Trim() -ne '' }) }
    if ($lines.Count -eq 0) { Log "queue empty, runner down"; break }
    while (TrainingBusy) { Start-Sleep 60 }
    # Take the first job; leave the rest (re-read, in case more were queued meanwhile).
    $lines = @(Get-Content $queue | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -eq 0) { continue }
    $job = $lines[0]
    Set-Content $queue ($lines | Select-Object -Skip 1)
    $parts = $job -split '\|', 3
    if ($parts.Count -lt 3) { Log "bad job line: $job"; continue }
    $name, $zip, $args = $parts
    if (Test-Path "$root\runs\heatmap\$name\best.pt") { Log "skip $name (done before)"; continue }
    $log = "$root\$name.log"
    Log "start $name : $zip $args"
    & cmd /c "`"$py`" train_heatmap_model.py $zip $args --name $name > `"$log`" 2>&1"
    Log "exit $name : $LASTEXITCODE"
    "$name|$LASTEXITCODE|$(Get-Date -Format 'yyyy-MM-dd HH:mm')" | Add-Content $done
}
