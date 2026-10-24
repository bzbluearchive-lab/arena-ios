# preflight_esp.ps1 - static self-check for the display-only (skeleton / gear / loot) build
#
# ASCII only on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI, so non-ASCII
# characters can break parsing. All messages are English by design. Same checks as
# tools/preflight_esp.py (that one runs on macOS CI where python3 exists).
#
# Usage (from the arena-ios directory):
#   powershell -ExecutionPolicy Bypass -File tools/preflight_esp.ps1

param([switch]$Quiet)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Makefile = Join-Path $Root 'Makefile.legacy-tweak'

$script:OkList   = New-Object System.Collections.Generic.List[string]
$script:WarnList = New-Object System.Collections.Generic.List[string]
$script:FailList = New-Object System.Collections.Generic.List[string]

function Add-Ok([string]$m)   { $script:OkList.Add($m) }
function Add-Warn([string]$m) { $script:WarnList.Add($m) }
function Add-Fail([string]$m) { $script:FailList.Add($m) }

if (-not (Test-Path $Makefile)) {
    Write-Host '[FAIL] Makefile.legacy-tweak not found'
    exit 1
}
$mk = Get-Content -Raw -LiteralPath $Makefile

# ---------------------------------------------------------------- 1. FILES list
$filesSection = ''
$m = [regex]::Match($mk, 'ARCheat_FILES\s*=\s*((?:.|\n)*?)(?:\r?\n){2}')
if ($m.Success) { $filesSection = $m.Groups[1].Value }

$files = @()
foreach ($tok in ($filesSection -replace '\\\s*\r?\n', ' ' -split '\s+')) {
    $t = $tok.Trim()
    if ($t -and -not $t.StartsWith('#')) { $files += $t }
}

if ($files.Count -eq 0) {
    Add-Fail 'ARCheat_FILES not found or empty in Makefile.legacy-tweak'
} else {
    $missing = @()
    foreach ($f in $files) {
        if (-not (Test-Path (Join-Path $Root $f))) { $missing += $f }
    }
    if ($missing.Count -gt 0) {
        foreach ($f in $missing) { Add-Fail "FILES entry missing on disk: $f" }
    } else {
        Add-Ok "FILES: $($files.Count) entries all present"
    }
}

# ---------------------------------------------------------------- 2. includes
$incMissing = @()
$vendorDeps = @()
$vendorDir = Join-Path $Root 'vendor/imgui'
# same -I directories the Makefile uses
$incDirs = @('', 'src', 'vendor', 'vendor/imgui', 'vendor/imgui/backends') |
    ForEach-Object { if ($_ -eq '') { $Root } else { Join-Path $Root $_ } }
foreach ($f in $files) {
    $p = Join-Path $Root $f
    if (-not (Test-Path $p)) { continue }
    $dir = Split-Path -Parent $p
    $text = Get-Content -Raw -LiteralPath $p
    foreach ($hit in [regex]::Matches($text, '(?m)^\s*#\s*(?:include|import)\s+"([^"]+)"')) {
        $inc = $hit.Groups[1].Value
        $found = $false
        foreach ($d in (@($dir) + $incDirs)) {
            if (Test-Path ([System.IO.Path]::GetFullPath((Join-Path $d $inc)))) { $found = $true; break }
        }
        if ($found) { continue }
        # third-party headers come from vendor/ and are fetched by CI; not a hard failure
        if ($inc -match '^imgui' -and -not (Test-Path $vendorDir)) {
            if ($vendorDeps -notcontains $inc) { $vendorDeps += $inc }
            continue
        }
        $incMissing += "$f -> $inc"
    }
}
if ($vendorDeps.Count -gt 0) {
    Add-Warn ('vendor headers not fetched yet (CI fetches them): ' + ($vendorDeps -join ', '))
}
if ($incMissing.Count -gt 0) {
    foreach ($x in $incMissing) { Add-Fail "unresolved include: $x" }
} else {
    Add-Ok 'all project-local includes resolve'
}

# ---------------------------------------------------------------- 3. invariants
$writeSites = @()
foreach ($f in $files) {
    $p = Join-Path $Root $f
    if (-not (Test-Path $p)) { continue }
    $n = 0
    foreach ($line in (Get-Content -LiteralPath $p)) {
        $n++
        if ($line -match 'mem::wr\(' -and -not $line.TrimStart().StartsWith('//')) {
            $writeSites += "${f}:$n"
        }
    }
}
if ($writeSites.Count -gt 0) {
    Add-Fail ('memory-write call sites found (display-only promises zero writes): ' + ($writeSites -join ', '))
} else {
    Add-Ok 'zero-write invariant holds: no mem::wr() call site'
}

if ($filesSection -match 'Aim\.mm') {
    Add-Fail 'Aim.mm is in FILES - the write path would be linked into the binary'
} else {
    Add-Ok 'Aim.mm not linked (no memory-write code in the binary)'
}

if ($mk -match 'AR_ALLOW_INLINE_HOOK=0') {
    Add-Ok 'AR_ALLOW_INLINE_HOOK=0: no anonymous executable memory allocation'
} else {
    Add-Fail 'missing -DAR_ALLOW_INLINE_HOOK=0 in Makefile'
}

foreach ($need in @('-std=c++17', '-fobjc-arc')) {
    if ($mk -match [regex]::Escape($need)) { Add-Ok "compile flag present: $need" }
    else { Add-Fail "compile flag missing: $need" }
}

if (($mk -match [regex]::Escape('-Wl,-x')) -and ($mk -match [regex]::Escape('-fvisibility=hidden'))) {
    Add-Ok 'symbol stripping flags present (-fvisibility=hidden + -Wl,-x)'
} else {
    Add-Warn 'symbol stripping flags incomplete (-fvisibility=hidden / -Wl,-x)'
}

$banned = @('ARCheat', 'aimbot', 'wallhack')
$hits = @()
foreach ($f in $files) {
    $p = Join-Path $Root $f
    if (-not (Test-Path $p)) { continue }
    $n = 0
    foreach ($line in (Get-Content -LiteralPath $p)) {
        $n++
        $s = $line.Trim()
        if ($s.StartsWith('//') -or $s.StartsWith('*') -or $s.StartsWith('/*')) { continue }
        foreach ($b in $banned) {
            if ($s.Contains($b) -and -not $s.Contains('archeat-') -and -not $s.Contains('ARCheat.dylib')) {
                $hits += "${f}:$n $b"
                break
            }
        }
    }
}
if ($hits.Count -gt 0) {
    Add-Warn ('possible plaintext fingerprint (verify manually): ' + (($hits | Select-Object -First 8) -join '; '))
} else {
    Add-Ok 'no bare cheat wording in source text'
}

# ---------------------------------------------------------------- 4. environment
$vendor = Join-Path $Root 'vendor/imgui'
$needed = @('imgui.h', 'imgui.cpp', 'imgui_draw.cpp', 'imgui_tables.cpp', 'imgui_widgets.cpp',
    'backends/imgui_impl_metal.h', 'backends/imgui_impl_metal.mm')
if (-not (Test-Path $vendor)) {
    Add-Warn 'vendor/imgui missing (CI fetches it; run tools/fetch-imgui.sh before a local build)'
} else {
    $miss = @()
    foreach ($n in $needed) { if (-not (Test-Path (Join-Path $vendor $n))) { $miss += $n } }
    if ($miss.Count -gt 0) { Add-Warn ('vendor/imgui incomplete: ' + ($miss -join ', ')) }
    else { Add-Ok 'vendor/imgui complete' }
}

if (-not $env:THEOS) {
    Add-Warn 'THEOS not set (export THEOS=~/theos before a local build; CI sets it)'
} else {
    Add-Ok "THEOS=$($env:THEOS)"
}

# ---------------------------------------------------------------- output
foreach ($l in $script:OkList)   { Write-Host "  [ok]   $l" -ForegroundColor Green }
foreach ($l in $script:WarnList) { Write-Host "  [warn] $l" -ForegroundColor Yellow }
foreach ($l in $script:FailList) { Write-Host "  [FAIL] $l" -ForegroundColor Red }

Write-Host ''
Write-Host ("preflight: {0} ok / {1} warn / {2} fail" -f $script:OkList.Count, $script:WarnList.Count, $script:FailList.Count)
if ($script:FailList.Count -gt 0) {
    Write-Host '=> fix FAIL items first, the build will not compile otherwise'
    exit 1
}
Write-Host '=> static checks passed, ready to compile'
exit 0
