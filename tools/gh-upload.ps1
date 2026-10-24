# gh-upload.ps1 - create a private repo and upload the whole project via GitHub API (no git needed)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tools\gh-upload.ps1 -Token "ghp_xxx"
#   powershell -ExecutionPolicy Bypass -File tools\gh-upload.ps1 -DryRun
#
# ASCII only on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI, so non-ASCII
# characters can break parsing. All messages are English by design.

param(
    [string]$Token,
    [string]$RepoName = 'arena-ios',
    [string]$Owner,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$exclude = '(^|\\)(build|\.theos|build-logs|\.git|out)(\\|$)'

function Get-RepoFiles {
    Get-ChildItem $root -Recurse -File -Force |
        Where-Object { $_.FullName.Replace($root + '\', '') -notmatch $exclude } |
        ForEach-Object {
            [pscustomobject]@{
                Rel  = $_.FullName.Replace($root + '\', '') -replace '\\', '/'
                Full = $_.FullName
            }
        } | Sort-Object Rel
}

$files = @(Get-RepoFiles)
if ($files.Count -eq 0) { throw "No files found under: $root" }

if ($DryRun) {
    $total = ($files | ForEach-Object { (Get-Item $_.Full).Length } | Measure-Object -Sum).Sum
    "files=$($files.Count) size=$([math]::Round($total/1KB,1))KB"
    foreach ($f in $files) { "  $($f.Rel)" }
    exit 0
}

if (-not $Token) { throw "Missing -Token" }

$api = 'https://api.github.com'
$hdr = @{
    Authorization          = "token $Token"
    'User-Agent'           = 'arena-ios-uploader'
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

"=== 1/3 verify token ==="
try {
    $me = Invoke-RestMethod -Uri "$api/user" -Headers $hdr -Method Get
} catch {
    throw "token invalid: $($_.Exception.Message)"
}
$login = if ($Owner) { $Owner } else { $me.login }
"login=$login"

"=== 2/3 create repo $login/$RepoName ==="
$exists = $false
try {
    $null = Invoke-RestMethod -Uri "$api/repos/$login/$RepoName" -Headers $hdr -Method Get
    $exists = $true
    "repo exists, writing into it"
} catch {
    if ($_.Exception.Response.StatusCode.value__ -ne 404) {
        "head repo check returned: $($_.Exception.Response.StatusCode.value__)"
    }
}

if (-not $exists) {
    $body = @{
        name        = $RepoName
        private     = $true
        auto_init   = $false
        description = 'iOS overlay research project'
    } | ConvertTo-Json
    try {
        $repo = Invoke-RestMethod -Uri "$api/user/repos" -Headers $hdr -Method Post `
                                  -Body ([Text.Encoding]::UTF8.GetBytes($body))
        "created: $($repo.html_url)"
    } catch {
        throw "create repo failed (token needs 'repo' scope): $($_.Exception.Message)"
    }
}

"=== 3/3 upload $($files.Count) files ==="
$i = 0
$fail = @()
foreach ($f in $files) {
    $i++
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.Full))
    $uri = "$api/repos/$login/$RepoName/contents/$($f.Rel)"
    $payload = @{ message = "add $($f.Rel)"; content = $b64 } | ConvertTo-Json -Depth 3

    try {
        $null = Invoke-RestMethod -Uri $uri -Headers $hdr -Method Put `
                                  -Body ([Text.Encoding]::UTF8.GetBytes($payload))
        "  [$i/$($files.Count)] ok   $($f.Rel)"
    } catch {
        $code = $_.Exception.Response.StatusCode.value__
        if ($code -eq 422) {
            try {
                $cur = Invoke-RestMethod -Uri $uri -Headers $hdr -Method Get
                $p2 = @{ message = "update $($f.Rel)"; content = $b64; sha = $cur.sha } | ConvertTo-Json -Depth 3
                $null = Invoke-RestMethod -Uri $uri -Headers $hdr -Method Put `
                                          -Body ([Text.Encoding]::UTF8.GetBytes($p2))
                "  [$i/$($files.Count)] overwrite $($f.Rel)"
            } catch {
                $fail += $f.Rel
                "  [$i/$($files.Count)] FAIL $($f.Rel) :: $($_.Exception.Message)"
            }
        } else {
            $fail += $f.Rel
            "  [$i/$($files.Count)] FAIL $($f.Rel) :: HTTP $code $($_.Exception.Message)"
        }
    }
}

""
if ($fail.Count) {
    "FAILED=$($fail.Count)"
    $fail | ForEach-Object { "  $_" }
} else {
    "ALL_UPLOADED"
}
""
"repo_url=https://github.com/$login/$RepoName"
"actions_url=https://github.com/$login/$RepoName/actions"
