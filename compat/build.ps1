#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Build the Haotian-XOS-Compat LSPosed module APK on Windows (no Gradle).

.DESCRIPTION
    Same manual toolchain flow as the upstream pandora-airdrop compat/build.sh:
        javac --release 8  ->  d8  ->  aapt2 compile/link  ->  debug keystore
        ->  apksigner sign/verify  ->  dist/Haotian-XOS-Compat.apk

    Optional environment variables (sensible defaults are auto-detected):
        JAVA_HOME       JDK to use            (default: Android Studio bundled JBR)
        ANDROID_HOME / ANDROID_SDK_ROOT       Android SDK root
        BUILD_TOOLS     build-tools directory (default: <sdk>\build-tools\36.0.0)
        SDK_STUB        android.jar           (default: android-37.0, fallback 36.1)
        SIGN_KEYSTORE   keystore path         (default: %USERPROFILE%\.haotian-xoscompat.jks)

    The script exits non-zero with a clear message when any step fails.

    Run it from this directory:
        .\build.ps1
    If script execution is disabled by policy, use:
        powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$CompatDir = $PSScriptRoot
Set-Location -LiteralPath $CompatDir
$BuildDir = Join-Path $CompatDir 'build'
$DistDir = Join-Path $CompatDir 'dist'

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Stop-Build([string]$Message) {
    Write-Host ''
    Write-Host "BUILD FAILED: $Message" -ForegroundColor Red
    exit 1
}

function Invoke-Native([string]$Label, [string]$FilePath, [string[]]$Arguments) {
    Write-Host "    $Label"
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        Stop-Build "$Label failed (exit code $LASTEXITCODE)"
    }
}

# --- JDK (d8.bat / apksigner.bat / keytool all need JAVA_HOME) --------------------------------
$JavaHome = $env:JAVA_HOME
if ([string]::IsNullOrWhiteSpace($JavaHome) -or
    -not (Test-Path -LiteralPath (Join-Path $JavaHome 'bin\javac.exe'))) {
    $javaCandidates = @(
        'C:\Program Files\Android\Android Studio\jbr',
        'C:\Program Files\Java\jdk-21',
        'C:\Program Files\Java\jdk-17'
    )
    $JavaHome = $null
    foreach ($candidate in $javaCandidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'bin\javac.exe')) {
            $JavaHome = $candidate
            break
        }
    }
    if (-not $JavaHome) {
        Stop-Build 'JDK not found. Set JAVA_HOME to a JDK 17+ install (e.g. C:\Program Files\Android\Android Studio\jbr).'
    }
}
$env:JAVA_HOME = $JavaHome
$env:PATH = (Join-Path $JavaHome 'bin') + ';' + $env:PATH
$Javac = Join-Path $JavaHome 'bin\javac.exe'
$Keytool = Join-Path $JavaHome 'bin\keytool.exe'
if (-not (Test-Path -LiteralPath $Javac)) { Stop-Build "javac.exe not found: $Javac" }
if (-not (Test-Path -LiteralPath $Keytool)) { Stop-Build "keytool.exe not found: $Keytool" }

# --- Android SDK / build-tools / android.jar ---------------------------------------------------
$SdkRoot = $env:ANDROID_SDK_ROOT
if ([string]::IsNullOrWhiteSpace($SdkRoot)) { $SdkRoot = $env:ANDROID_HOME }
if ([string]::IsNullOrWhiteSpace($SdkRoot)) {
    $defaultSdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk'
    if (Test-Path -LiteralPath $defaultSdk) { $SdkRoot = $defaultSdk }
}
if ([string]::IsNullOrWhiteSpace($SdkRoot) -or -not (Test-Path -LiteralPath $SdkRoot)) {
    Stop-Build 'Android SDK not found. Set ANDROID_HOME (or ANDROID_SDK_ROOT).'
}

$BuildToolsDir = $env:BUILD_TOOLS
if ([string]::IsNullOrWhiteSpace($BuildToolsDir)) {
    $BuildToolsDir = Join-Path $SdkRoot 'build-tools\36.0.0'
}
$Aapt2 = Join-Path $BuildToolsDir 'aapt2.exe'
$D8 = Join-Path $BuildToolsDir 'd8.bat'
$ApkSigner = Join-Path $BuildToolsDir 'apksigner.bat'
foreach ($tool in @($Aapt2, $D8, $ApkSigner)) {
    if (-not (Test-Path -LiteralPath $tool)) { Stop-Build "build tool not found: $tool" }
}

$SdkStub = $env:SDK_STUB
if ([string]::IsNullOrWhiteSpace($SdkStub)) {
    foreach ($platform in @('android-37.0', 'android-36.1', 'android-36', 'android-35')) {
        $candidate = Join-Path $SdkRoot "platforms\$platform\android.jar"
        if (Test-Path -LiteralPath $candidate) { $SdkStub = $candidate; break }
    }
}
if ([string]::IsNullOrWhiteSpace($SdkStub) -or -not (Test-Path -LiteralPath $SdkStub)) {
    Stop-Build 'android.jar not found. Set SDK_STUB to an SDK platforms/<api>/android.jar.'
}

# --- sources -----------------------------------------------------------------------------------
$StubDir = Join-Path $CompatDir 'stubs'
$MainSrcDir = Join-Path $CompatDir 'src\org\haotian\xoscompat'
$StubSources = @(Get-ChildItem -LiteralPath $StubDir -Recurse -File -Filter '*.java' |
        Sort-Object FullName | ForEach-Object { $_.FullName })
$MainSources = @(Get-ChildItem -LiteralPath $MainSrcDir -File -Filter '*.java' |
        Sort-Object Name | ForEach-Object { $_.FullName })
if ($StubSources.Count -eq 0) { Stop-Build "no Xposed API stub sources under $StubDir" }
if ($MainSources.Count -eq 0) { Stop-Build "no module sources under $MainSrcDir" }

Write-Host "    JAVA_HOME  = $JavaHome"
Write-Host "    SDK_STUB   = $SdkStub"
Write-Host "    BUILD_TOOLS= $BuildToolsDir"

# --- clean -------------------------------------------------------------------------------------
Write-Step 'Cleaning build/ and dist/'
foreach ($dir in @($BuildDir, $DistDir)) {
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
}
$StubOut = Join-Path $BuildDir 'stubs'
$ClassesOut = Join-Path $BuildDir 'classes'
$DexOut = Join-Path $BuildDir 'dex'
foreach ($dir in @($StubOut, $ClassesOut, $DexOut, $DistDir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

# --- compile -----------------------------------------------------------------------------------
Write-Step 'Compiling Xposed API stubs (javac --release 8)'
$stubArgs = @('--release', '8', '-encoding', 'UTF-8', '-Xlint:-options', '-d', $StubOut) + $StubSources
Invoke-Native 'javac stubs' $Javac $stubArgs

Write-Step 'Compiling module sources (javac --release 8)'
$mainClassPath = $StubOut + ';' + $SdkStub
$mainArgs = @('--release', '8', '-encoding', 'UTF-8', '-Xlint:-options',
        '-cp', $mainClassPath, '-d', $ClassesOut) + $MainSources
Invoke-Native 'javac module' $Javac $mainArgs

# --- dex ---------------------------------------------------------------------------------------
Write-Step 'Dexing module classes (d8)'
$ModuleClassesDir = Join-Path $ClassesOut 'org\haotian\xoscompat'
$ClassFiles = @(Get-ChildItem -LiteralPath $ModuleClassesDir -File -Filter '*.class' |
        Sort-Object Name | ForEach-Object { $_.FullName })
if ($ClassFiles.Count -eq 0) { Stop-Build "no compiled classes under $ModuleClassesDir" }
$d8Args = @('--lib', $SdkStub, '--classpath', $StubOut, '--min-api', '33',
        '--output', $DexOut) + $ClassFiles
Invoke-Native 'd8' $D8 $d8Args
$DexFile = Join-Path $DexOut 'classes.dex'
if (-not (Test-Path -LiteralPath $DexFile)) { Stop-Build "d8 produced no classes.dex at $DexFile" }

# --- resources + manifest ----------------------------------------------------------------------
Write-Step 'Compiling resources (aapt2 compile)'
$ResZip = Join-Path $BuildDir 'res.zip'
Invoke-Native 'aapt2 compile' $Aapt2 @('compile', '--dir', (Join-Path $CompatDir 'res'), '-o', $ResZip)

Write-Step 'Linking APK resources + manifest (aapt2 link)'
$UnsignedApk = Join-Path $BuildDir 'unsigned.apk'
$aapt2LinkArgs = @('link', '-I', $SdkStub, '--manifest',
        (Join-Path $CompatDir 'AndroidManifest.xml'), '-A', (Join-Path $CompatDir 'assets'),
        '-o', $UnsignedApk, $ResZip)
Invoke-Native 'aapt2 link' $Aapt2 $aapt2LinkArgs
if (-not (Test-Path -LiteralPath $UnsignedApk)) { Stop-Build "aapt2 link produced no APK at $UnsignedApk" }

Write-Step 'Adding classes.dex to the APK'
# ZipArchive/ZipFile live in different assemblies on Windows PowerShell 5.1 and PowerShell 7;
# load whichever is available and fail clearly if the API cannot be resolved.
foreach ($assemblyName in @('System.IO.Compression', 'System.IO.Compression.FileSystem',
        'System.IO.Compression.ZipFile')) {
    try {
        Add-Type -AssemblyName $assemblyName -ErrorAction Stop
    } catch {
        # Optional on newer runtimes where the type is already reachable.
    }
}
$zipFileType = ([System.Management.Automation.PSTypeName]'System.IO.Compression.ZipFile').Type
if ($null -eq $zipFileType) {
    Stop-Build 'System.IO.Compression.ZipFile is unavailable in this PowerShell runtime'
}
try {
    $zip = [System.IO.Compression.ZipFile]::Open(
            $UnsignedApk, [System.IO.Compression.ZipArchiveMode]::Update)
} catch {
    Stop-Build "cannot open unsigned APK: $($_.Exception.Message)"
}
try {
    $existing = $zip.GetEntry('classes.dex')
    if ($null -ne $existing) { $existing.Delete() }
    $entry = $zip.CreateEntry('classes.dex', [System.IO.Compression.CompressionLevel]::Optimal)
    $entryStream = $entry.Open()
    try {
        $dexStream = [System.IO.File]::OpenRead($DexFile)
        try {
            $dexStream.CopyTo($entryStream)
        } finally {
            $dexStream.Dispose()
        }
    } finally {
        $entryStream.Dispose()
    }
} finally {
    $zip.Dispose()
}

# --- keystore + signing ------------------------------------------------------------------------
$Keystore = $env:SIGN_KEYSTORE
if ([string]::IsNullOrWhiteSpace($Keystore)) {
    $Keystore = Join-Path $env:USERPROFILE '.haotian-xoscompat.jks'
}
if (-not (Test-Path -LiteralPath $Keystore)) {
    Write-Step "Generating local debug keystore: $Keystore"
    $keytoolArgs = @('-genkeypair', '-keystore', $Keystore,
            '-storepass', 'haotian-local', '-keypass', 'haotian-local',
            '-alias', 'haotian', '-dname', 'CN=HaotianXosCompat',
            '-keyalg', 'RSA', '-keysize', '2048', '-validity', '3650')
    Invoke-Native 'keytool genkeypair' $Keytool $keytoolArgs
}

$FinalApk = Join-Path $DistDir 'Haotian-XOS-Compat.apk'
Write-Step 'Signing APK (apksigner)'
$signArgs = @('sign', '--ks', $Keystore, '--ks-pass', 'pass:haotian-local',
        '--ks-key-alias', 'haotian', '--out', $FinalApk, $UnsignedApk)
Invoke-Native 'apksigner sign' $ApkSigner $signArgs
if (-not (Test-Path -LiteralPath $FinalApk)) { Stop-Build "apksigner produced no APK at $FinalApk" }
Get-ChildItem -LiteralPath $DistDir -Filter '*.idsig' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue

Write-Step 'Verifying signature (apksigner verify)'
$verifyOutput = & $ApkSigner verify --verbose --print-certs $FinalApk 2>&1
if ($LASTEXITCODE -ne 0) {
    $verifyOutput | Write-Host
    Stop-Build 'apksigner verify failed'
}
$verifyOutput | Write-Host

# --- self checks -------------------------------------------------------------------------------
Write-Step 'Self-check: manifest package / version'
$badging = & $Aapt2 dump badging $FinalApk 2>&1
if ($LASTEXITCODE -ne 0) {
    $badging | Write-Host
    Stop-Build 'aapt2 dump badging failed'
}
$packageLine = $badging | Where-Object { $_ -match "^package: name='" } | Select-Object -First 1
if ($null -eq $packageLine) { Stop-Build 'could not read the package line from aapt2 dump badging' }
$packageLine = [string]$packageLine
if ($packageLine -notmatch "name='org\.haotian\.xoscompat'") {
    Stop-Build "APK package is not org.haotian.xoscompat: $packageLine"
}
if ($packageLine -notmatch "versionCode='2'") {
    Stop-Build "APK versionCode is not 2: $packageLine"
}
if ($packageLine -notmatch "versionName='0\.2\.0'") {
    Stop-Build "APK versionName is not 0.2.0: $packageLine"
}
Write-Host "    $packageLine"
$labelLine = $badging | Where-Object { $_ -match '^application-label:' } | Select-Object -First 1
if ($null -ne $labelLine) { Write-Host "    $labelLine" }

Write-Step 'Self-check: assets/xposed_init + classes.dex'
$zipRead = $null
try {
    $zipRead = [System.IO.Compression.ZipFile]::OpenRead($FinalApk)
    $initEntry = $zipRead.GetEntry('assets/xposed_init')
    $dexEntry = $zipRead.GetEntry('classes.dex')
    if ($null -eq $initEntry) { Stop-Build 'assets/xposed_init is missing from the APK' }
    if ($null -eq $dexEntry) { Stop-Build 'classes.dex is missing from the APK' }
    $reader = New-Object System.IO.StreamReader($initEntry.Open())
    try {
        $initText = $reader.ReadToEnd().Trim()
    } finally {
        $reader.Dispose()
    }
    $dexLength = $dexEntry.Length
} catch {
    Stop-Build "APK inspection failed: $($_.Exception.Message)"
} finally {
    if ($null -ne $zipRead) { $zipRead.Dispose() }
}
if ($initText -ne 'org.haotian.xoscompat.Hook') {
    Stop-Build "assets/xposed_init must contain org.haotian.xoscompat.Hook, found: '$initText'"
}
Write-Host "    assets/xposed_init = $initText"
Write-Host "    classes.dex size   = $dexLength bytes"

Write-Step 'SHA-256'
$sha256 = (Get-FileHash -LiteralPath $FinalApk -Algorithm SHA256).Hash.ToLowerInvariant()
$apkSize = (Get-Item -LiteralPath $FinalApk).Length

Write-Host ''
Write-Host 'BUILD OK' -ForegroundColor Green
Write-Host "    APK      : $FinalApk"
Write-Host "    size     : $apkSize bytes"
Write-Host "    sha256   : $sha256"
exit 0
