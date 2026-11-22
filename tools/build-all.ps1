# ============================================================================
# Windows 一键构建（当前可构建的部分）：
#   1. 构建 LSPosed 兼容 APK（compat/build.ps1，需要 Android Studio + Android SDK）
#   2. 从上游 release 准备 3 个设备无关运行时二进制（tools/fetch-upstream.ps1）
#   3. 组装 KernelSU 模块 zip（tools/package.mjs，需要 Node.js 18+）
#
# 内核模块（4 个 .ko）必须在 Linux 上按 BUILD-MODULES.md 编译后放到
# build/out/kernel-modules/；没有它们时本脚本默认生成"预览包"（安装器会安全中止），
# 加 -RequireKernelModules 则直接报错。
#
# 用法（Windows PowerShell 5.1 和 PowerShell 7 都支持）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-all.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-all.ps1 -RequireKernelModules -Firmware C:\path\s26u-amss20.bin
# ============================================================================
param(
  [switch]$RequireKernelModules,
  [switch]$SkipCompat,
  [switch]$SkipUpstream,
  [string]$Firmware = '',
  [string]$OutDir = ''
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

# 选择当前可用的 PowerShell 宿主（很多机器只装了 5.1，没有 pwsh 7）
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
  $HostExe = 'pwsh'
} else {
  $HostExe = Join-Path $PSHOME 'powershell.exe'
}
Write-Host "PowerShell host: $HostExe"

if (-not $SkipCompat) {
  Write-Host '=== [1/3] 构建 LSPosed 兼容 APK ==='
  & $HostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'compat/build.ps1')
  if ($LASTEXITCODE -ne 0) { throw 'compat/build.ps1 失败' }
}
if (-not $SkipUpstream) {
  Write-Host '=== [2/3] 准备上游运行时二进制 ==='
  & $HostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tools/fetch-upstream.ps1')
  if ($LASTEXITCODE -ne 0) { throw 'fetch-upstream.ps1 失败' }
}

Write-Host '=== [3/3] 校验内核模块并打包 ==='
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw '未找到 node，请安装 Node.js 18+ 后重试' }
$nodeArgs = @('tools/package.mjs', '--profile', 'haotian', '--inputs', 'build/out', '--upstream', 'upstream')
if ($OutDir) { $nodeArgs += @('--out', $OutDir) }
if ($Firmware) {
  if (-not (Test-Path $Firmware)) { throw "固件不存在: $Firmware" }
  $nodeArgs += @('--firmware', (Resolve-Path $Firmware).Path)
}
if (-not $RequireKernelModules) { $nodeArgs += '--allow-missing-kernel-modules' }
& node @nodeArgs
if ($LASTEXITCODE -ne 0) { throw 'package.mjs 失败' }
Write-Host '完成，产物在 dist/ 目录。'
