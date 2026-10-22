# verify_package.ps1: recompute an L2 package's canonical digest on the desktop
# and compare it with the one its own l2-manifest.json records (D-018 section 9).
#
#     powershell -File verify_package.ps1 -Package D:\RallyLabStaging\Scratch-exports\<name>
#
# The digest is the one RallyLab's preflight wrote: for every regular file
# under the package except l2-manifest.json (a record cannot hold its own
# hash), in byte order of its relative path, one line
#     <sha256 lowercase>  ./<relative path with forward slashes>
# followed by a newline, and SHA-256 over all those lines. The same as
#     find . -type f ! -name l2-manifest.json -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256
# Besides the digest, every file the record lists (preflight.files: path,
# sha256, bytes) is reconciled with what is on disk: a missing, extra, or
# changed file is named. -Report <path> also writes the result as JSON (the
# only thing this script ever writes, and only where told).
# Exit 0 when everything matches, 1 when it doesn't, 2 when the package or
# record is missing or unreadable.
param([Parameter(Mandatory = $true)][string]$Package, [switch]$Lines, [string]$Report)

$ErrorActionPreference = 'Stop'
$record = Join-Path $Package 'l2-manifest.json'
if (-not (Test-Path -LiteralPath $Package -PathType Container)) { Write-Output "no package folder at $Package"; exit 2 }
if (-not (Test-Path -LiteralPath $record -PathType Leaf)) { Write-Output "no l2-manifest.json in $Package (not a preflighted lineage package)"; exit 2 }
$preflight = (Get-Content -LiteralPath $record -Raw -Encoding UTF8 | ConvertFrom-Json).preflight
$expected = $preflight.digest
if (-not $expected) { Write-Output "l2-manifest.json has no preflight.digest"; exit 2 }
$listed = @{}
foreach ($f in @($preflight.files)) { $listed[$f.path] = $f }

$root = (Get-Item -LiteralPath $Package).FullName.TrimEnd('\')
$files = Get-ChildItem -LiteralPath $root -Recurse -File -Force |
    Where-Object { $_.FullName -ne (Join-Path $root 'l2-manifest.json') } |
    ForEach-Object { $_.FullName.Substring($root.Length + 1).Replace('\', '/') }
# Byte order of the UTF-8 path, as the Mac sorts it (LC_ALL=C): ordinal on code units is the same for ASCII names.
$files = [string[]]@($files)
[array]::Sort($files, [System.StringComparer]::Ordinal)

$sha = [System.Security.Cryptography.SHA256]::Create()
$sb = [System.Text.StringBuilder]::new()
$n = 0
$changed = @(); $extra = @()
foreach ($rel in $files) {
    $full = Join-Path $root ($rel.Replace('/', '\'))
    $stream = [System.IO.File]::OpenRead($full)
    try { $hash = ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join ''; $bytes = $stream.Length } finally { $stream.Dispose() }
    [void]$sb.Append($hash).Append('  ./').Append($rel).Append("`n")
    if ($Lines) { Write-Output "$hash  ./$rel" }
    if ($listed.ContainsKey($rel)) {
        if ($listed[$rel].sha256 -ne $hash -or [int64]$listed[$rel].bytes -ne $bytes) { $changed += $rel }
        $listed.Remove($rel)
    } else { $extra += $rel }
    $n++
}
$missing = @($listed.Keys | Sort-Object)
$bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
$digest = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
$sha.Dispose()

$ok = ($digest -eq $expected) -and ($changed.Count -eq 0) -and ($extra.Count -eq 0) -and ($missing.Count -eq 0)
$result = [ordered]@{
    package = $root; verifiedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); host = $env:COMPUTERNAME
    filesOnDisk = $n; filesInRecord = @($preflight.files).Count
    digestComputed = $digest; digestRecorded = $expected; digestMatches = ($digest -eq $expected)
    changed = @($changed); extra = @($extra); missing = @($missing); passed = $ok
}
if ($Report) { [System.IO.File]::WriteAllText($Report, ($result | ConvertTo-Json -Depth 4), [System.Text.UTF8Encoding]::new($false)) }   # no BOM
if ($ok) {
    Write-Output "digest OK: $digest over $n files matches l2-manifest.json; every listed file present with its recorded hash and size"
    exit 0
} else {
    Write-Output "VERIFICATION FAILED - the package is not the one preflighted; do not train on it"
    if ($digest -ne $expected) { Write-Output "  digest: computed $digest over $n files, l2-manifest.json says $expected" }
    foreach ($c in $changed) { Write-Output "  changed: $c" }
    foreach ($e in $extra) { Write-Output "  extra (not in the record): $e" }
    foreach ($m in $missing) { Write-Output "  missing (in the record, not on disk): $m" }
    exit 1
}
