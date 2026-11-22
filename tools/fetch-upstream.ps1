# ============================================================================
# 获取上游 pandora-airdrop v1.0.0 release 里的"设备无关"运行时二进制
#   owly-xosd / wonder-init / xos-bridge.zip
# 这三件是上游作者编译发布的（本仓库不重新分发），官方 release 地址：
#   https://github.com/AdenXie/pandora-airdrop/releases/tag/v1.0.0
# 使用本脚本 = 你自己从上游下载，放到 upsteam/ 目录供打包器使用。
#
# 用法：pwsh -File tools/fetch-upstream.ps1 [-Dest upstream]
# ============================================================================
param(
  [string]$Dest = (Join-Path (Split-Path -Parent $PSScriptRoot) 'upstream'),
  [string]$ReleaseUrl = 'https://github.com/AdenXie/pandora-airdrop/releases/download/v1.0.0/pandora-airdrop-v1.0.0.zip',
  [string]$ExpectedSha256 = 'dfa2d81829ebca155fa768721e73a18d44a59cb0f9c0918edd8e6549ad65fe39'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
$zip = Join-Path $Dest 'pandora-airdrop-v1.0.0.zip'

function Get-Sha([string]$p) { (Get-FileHash -Path $p -Algorithm SHA256).Hash.ToLower() }

if (-not (Test-Path $zip) -or (Get-Sha $zip) -ne $ExpectedSha256) {
  $mirrors = @(
    $ReleaseUrl,
    ("https://gh-proxy.com/" + $ReleaseUrl),
    ("https://ghfast.top/" + $ReleaseUrl),
    ("https://cdn.jsdelivr.net/gh/AdenXie/pandora-airdrop@v1.0.0/" ) # 占位：release 资产不走 jsDelivr
  )
  $ok = $false
  foreach ($u in $mirrors) {
    if ($u -notmatch 'releases/download') { continue }
    try {
      Write-Host "下载: $u"
      Invoke-WebRequest -Uri $u -OutFile $zip -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -UseBasicParsing -TimeoutSec 300
      if ((Get-Sha $zip) -eq $ExpectedSha256) { $ok = $true; break }
      Write-Warning "SHA-256 不匹配，尝试下一个镜像"
    } catch {
      Write-Warning "失败: $($_.Exception.Message)"
    }
  }
  if (-not $ok) { throw "上游 release 下载失败。请手动下载后解压，把 payload 目录内容放到 $Dest" }
}
Write-Host "SHA-256 校验通过: $ExpectedSha256"

$tmp = Join-Path $Dest '_extract'
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
Expand-Archive -Path $zip -DestinationPath $tmp -Force
$payload = Join-Path $tmp 'payload'
if (-not (Test-Path $payload)) { throw "release zip 结构异常：没有 payload/ 目录" }
foreach ($f in 'owly-xosd', 'wonder-init', 'xos-bridge.zip') {
  Copy-Item (Join-Path $payload $f) (Join-Path $Dest $f) -Force
  Write-Host ("  -> {0} ({1} bytes, sha256={2})" -f $f, (Get-Item (Join-Path $Dest $f)).Length, (Get-Sha (Join-Path $Dest $f)))
}
Remove-Item -Recurse -Force $tmp
Write-Host "完成：$Dest"
