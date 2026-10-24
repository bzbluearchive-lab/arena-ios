# gh-fetch-artifact.ps1 —— 等 Actions 跑完，把构建产物下载到本地
#
# 用法：
#   .\tools\gh-fetch-artifact.ps1 -Token "ghp_xxx" -Repo arena-ios
#
# 做什么：
#   1. 找最新一次 workflow run
#   2. 等它变成 completed（最多 15 分钟）
#   3. 下载 ARHost-release 产物 zip
#   4. 解压到 arena-ios\out\ ，把 ARHost.ipa 单独摊在 out 根目录方便取

param(
    [Parameter(Mandatory = $true)][string]$Token,
    [string]$Repo = 'arena-ios',
    [string]$Owner,
    [int]$TimeoutMinutes = 15
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$outDir = Join-Path $root 'out'

$api = 'https://api.github.com'
$hdr = @{
    Authorization          = "token $Token"
    'User-Agent'           = 'arena-ios-fetcher'
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}

$me = Invoke-RestMethod -Uri "$api/user" -Headers $hdr -Method Get
if (-not $Owner) { $Owner = $me.login }
"仓库: $Owner/$Repo"

# ---------- 1. 等 run 出现并完成 ----------
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$run = $null
while ((Get-Date) -lt $deadline) {
    $runs = Invoke-RestMethod -Uri "$api/repos/$Owner/$Repo/actions/runs?per_page=5" -Headers $hdr -Method Get
    if ($runs.workflow_runs.Count -gt 0) {
        $run = $runs.workflow_runs[0]
        "run #$($run.run_number)  status=$($run.status)  conclusion=$($run.conclusion)"
        if ($run.status -eq 'completed') { break }
    } else {
        "还没出现 workflow run（等 GitHub 建索引）"
    }
    Start-Sleep -Seconds 15
}

if (-not $run) { throw "超时：没有出现任何 workflow run" }
if ($run.status -ne 'completed') { throw "超时：run 仍未完成（$($run.status)）" }

"结论: $($run.conclusion)"
"详情: $($run.html_url)"
""
if ($run.conclusion -ne 'success') {
    "构建没有成功。用这个命令看失败步骤的日志："
    "  gh-fetch-artifact.ps1 无法展示日志，请把上面的详情链接里的红叉步骤内容发给我"
    exit 1
}

# ---------- 2. 下载产物 ----------
$arts = Invoke-RestMethod -Uri "$api/repos/$Owner/$Repo/actions/runs/$($run.id)/artifacts" -Headers $hdr -Method Get
if ($arts.artifacts.Count -eq 0) { throw "这次 run 没有任何 artifacts" }

$art = $arts.artifacts | Where-Object { $_.name -eq 'ARHost-release' } | Select-Object -First 1
if (-not $art) { $art = $arts.artifacts[0] }
"产物: $($art.name)  $([math]::Round($art.size_in_bytes/1KB,1)) KB"

if (Test-Path $outDir) { Remove-Item $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir | Out-Null

$zipPath = Join-Path $outDir 'ARHost-release.zip'
Invoke-WebRequest -Uri $art.archive_download_url -Headers $hdr -OutFile $zipPath -Method Get
"已下载: $zipPath"

Expand-Archive -Path $zipPath -DestinationPath $outDir -Force
"已解压到: $outDir"
""
"=== 内容 ==="
Get-ChildItem $outDir -Recurse -File | ForEach-Object {
    "  {0,-45} {1,10:N1} KB" -f $_.FullName.Replace($outDir + '\', ''), ($_.Length / 1KB)
}

$ipa = Get-ChildItem $outDir -Recurse -Filter '*.ipa' | Select-Object -First 1
""
if ($ipa) {
    $dst = Join-Path $outDir 'ARHost.ipa'
    if ($ipa.FullName -ne $dst) { Copy-Item $ipa.FullName $dst -Force }
    "可以直接传给 iPad 的文件："
    "  $dst"
} else {
    "没有找到 .ipa，检查构建日志里的『构建』步骤"
}
