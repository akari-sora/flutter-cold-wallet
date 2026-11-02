param([string]$OutputDirectory = '', [switch]$SkipFlutter)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (!$OutputDirectory) { $OutputDirectory = Join-Path $repo 'target/qr-core' }
$rustBin = Join-Path $env:USERPROFILE '.rustup/toolchains/1.96.1-x86_64-pc-windows-msvc/bin'
if (Test-Path -LiteralPath $rustBin) { $env:PATH = "$rustBin;$env:USERPROFILE\.cargo\bin;$env:PATH" }
if (!$env:ANDROID_NDK_HOME) { $env:ANDROID_NDK_HOME = Join-Path $env:LOCALAPPDATA 'Android/Sdk/ndk/27.0.12077973' }
Push-Location $repo
try {
    foreach ($app in @('wallet', 'vault')) {
        & cargo ndk -t arm64-v8a -t x86_64 -o "apps/$app/android/app/src/main/jniLibs" build --locked --release -p "${app}_ffi" --no-default-features
        if ($LASTEXITCODE -ne 0) { throw "Native $app build failed" }
    }
    if (!$SkipFlutter) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        foreach ($app in @('wallet', 'vault')) {
            Push-Location "apps/$app"
            try {
                & flutter build apk --release --target-platform android-arm64,android-x64
                if ($LASTEXITCODE -ne 0) { throw "Flutter $app build failed" }
                Copy-Item -LiteralPath 'build/app/outputs/flutter-apk/app-release.apk' -Destination (Join-Path $OutputDirectory "$app-qr-local-test.apk") -Force
            } finally { Pop-Location }
        }
        Get-ChildItem -LiteralPath $OutputDirectory -Filter '*.apk' | Get-FileHash -Algorithm SHA256 | Select-Object Path,Hash
    }
} finally { Pop-Location }
