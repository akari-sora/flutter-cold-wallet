param(
    [string]$Sdk = "$env:LOCALAPPDATA\Android\Sdk",
    [string]$Jdk = 'C:\Program Files\Eclipse Adoptium\jdk-21.0.9.10-hotspot',
    [string]$BuildToolsVersion = '36.0.0',
    [string]$PlatformVersion = 'android-36',
    [string]$DebugKeystore = "$env:USERPROFILE\.android\debug.keystore"
)
$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$outputRoot = Join-Path $projectRoot 'target\qr-core\public-review-observer'
$stage = Join-Path $outputRoot ([Guid]::NewGuid().ToString('N'))
$classes = Join-Path $stage 'classes'
$hostClasses = Join-Path $stage 'host-tests'
$dex = Join-Path $stage 'dex'
$tools = Join-Path $Sdk "build-tools\$BuildToolsVersion"
$androidJar = Join-Path $Sdk "platforms\$PlatformVersion\android.jar"
foreach ($required in @($androidJar, $DebugKeystore, "$Jdk\bin\javac.exe", "$Jdk\bin\jar.exe", "$tools\aapt2.exe", "$tools\d8.bat", "$tools\zipalign.exe", "$tools\apksigner.bat")) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing existing build tool: $required" }
}
New-Item -ItemType Directory -Force -Path $classes, $hostClasses, $dex | Out-Null
$priorJavaHome = $env:JAVA_HOME
$priorPath = $env:PATH
function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Build command failed: $Exe (exit $LASTEXITCODE)" }
}
try {
    $env:JAVA_HOME = $Jdk
    $env:PATH = "$Jdk\bin;$priorPath"
    $sources = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.java' -Recurse | ForEach-Object FullName)
    $gate = Join-Path $PSScriptRoot 'src\com\coldwallet\test\publicreviewobserver\ReviewGate.java'
    $gateTest = Join-Path $PSScriptRoot 'test\com\coldwallet\test\publicreviewobserver\ReviewGateTest.java'
    Invoke-Checked "$Jdk\bin\javac.exe" @('-encoding', 'UTF-8', '-Xlint:all', '-d', $hostClasses, $gate, $gateTest)
    Invoke-Checked "$Jdk\bin\java.exe" @('-cp', $hostClasses, 'com.coldwallet.test.publicreviewobserver.ReviewGateTest')
    Invoke-Checked "$Jdk\bin\javac.exe" (@('-encoding', 'UTF-8', '--release', '8', '-Xlint:all,-options', '-classpath', $androidJar, '-d', $classes) + $sources)
    $classFiles = @(Get-ChildItem -LiteralPath $classes -Filter '*.class' -Recurse | ForEach-Object FullName)
    Invoke-Checked "$tools\d8.bat" (@('--release', '--min-api', '26', '--lib', $androidJar, '--output', $dex) + $classFiles)
    $unsigned = Join-Path $stage 'unsigned.apk'
    $aligned = Join-Path $stage 'aligned.apk'
    $apk = Join-Path $outputRoot 'public-review-observer-test-only.apk'
    Invoke-Checked "$tools\aapt2.exe" @('link', '-o', $unsigned, '--manifest', (Join-Path $PSScriptRoot 'AndroidManifest.xml'), '-I', $androidJar)
    Invoke-Checked "$Jdk\bin\jar.exe" @('--update', '--file', $unsigned, '--no-manifest', '-C', $dex, 'classes.dex')
    Invoke-Checked "$tools\zipalign.exe" @('-f', '4', $unsigned, $aligned)
    Invoke-Checked "$tools\apksigner.bat" @('sign', '--ks', $DebugKeystore, '--ks-key-alias', 'androiddebugkey', '--ks-pass', 'pass:android', '--key-pass', 'pass:android', '--out', $apk, $aligned)
    Invoke-Checked "$tools\apksigner.bat" @('verify', '--verbose', $apk)
    Invoke-Checked "$tools\zipalign.exe" @('-c', '4', $apk)
    $manifestAudit = & "$tools\aapt2.exe" dump xmltree $apk --file AndroidManifest.xml
    if ($LASTEXITCODE -ne 0) { throw 'Manifest inspection failed' }
    if (($manifestAudit -join "`n") -match 'E: (uses-permission|activity|activity-alias|service|receiver|provider)') { throw 'Unexpected permission or application component' }
    $manifestAudit | Set-Content -LiteralPath (Join-Path $outputRoot 'manifest-audit.txt') -Encoding UTF8
    Get-FileHash -Algorithm SHA256 -LiteralPath $apk | Format-List
    Write-Output 'Build, read-only gate host tests, APK signature, alignment, and component audit passed. No device was accessed.'
} finally {
    $env:JAVA_HOME = $priorJavaHome
    $env:PATH = $priorPath
}
