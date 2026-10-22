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
# Exit 0 when it matches, 1 when it doesn't, 2 when the package or record is
# missing or unreadable. Nothing is written.
param([Parameter(Mandatory = $true)][string]$Package, [switch]$Lines)

$ErrorActionPreference = 'Stop'
$record = Join-Path $Package 'l2-manifest.json'
if (-not (Test-Path -LiteralPath $Package -PathType Container)) { Write-Output "no package folder at $Package"; exit 2 }
if (-not (Test-Path -LiteralPath $record -PathType Leaf)) { Write-Output "no l2-manifest.json in $Package (not a preflighted lineage package)"; exit 2 }
$expected = (Get-Content -LiteralPath $record -Raw -Encoding UTF8 | ConvertFrom-Json).preflight.digest
if (-not $expected) { Write-Output "l2-manifest.json has no preflight.digest"; exit 2 }

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
foreach ($rel in $files) {
    $stream = [System.IO.File]::OpenRead((Join-Path $root ($rel.Replace('/', '\'))))
    try { $hash = ($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) -join '' } finally { $stream.Dispose() }
    [void]$sb.Append($hash).Append('  ./').Append($rel).Append("`n")
    if ($Lines) { Write-Output "$hash  ./$rel" }
    $n++
}
$bytes = [System.Text.Encoding]::UTF8.GetBytes($sb.ToString())
$digest = ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
$sha.Dispose()

if ($digest -eq $expected) {
    Write-Output "digest OK: $digest over $n files matches l2-manifest.json"
    exit 0
} else {
    Write-Output "digest MISMATCH: computed $digest over $n files, l2-manifest.json says $expected - the package is not the one preflighted; do not train on it"
    exit 1
}
