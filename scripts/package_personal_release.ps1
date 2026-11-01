param(
    [string]$Flutter = 'flutter',
    [switch]$Build
)

$ErrorActionPreference = 'Stop'
$repo = Resolve-Path (Join-Path $PSScriptRoot '..')
$output = Join-Path $repo 'release'
$windowsBuild = Join-Path $repo 'build\windows\x64\runner\Release'
$apk = Join-Path $repo 'build\app\outputs\flutter-apk\app-release.apk'
$signingProperties = Join-Path $repo 'android\key.properties'

if (-not (Test-Path $signingProperties)) {
    throw 'Missing android/key.properties; a personal release requires a fixed signing key.'
}
$storeFileLine = Get-Content $signingProperties |
    Where-Object { $_ -match '^\s*storeFile\s*=' } |
    Select-Object -First 1
if (-not $storeFileLine) { throw 'key.properties does not configure storeFile.' }
$storeFile = ($storeFileLine -replace '^\s*storeFile\s*=\s*', '').Trim()
$keystore = [System.IO.Path]::GetFullPath(
    (Join-Path (Join-Path $repo 'android\app') $storeFile)
)
if (-not (Test-Path $keystore)) { throw "Personal signing file not found: $keystore" }

Push-Location $repo
try {
    if ($Build) {
        & $Flutter build windows --release --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Windows Release build failed.' }

        # flutter test can leave an ignored plugin registrant that includes the
        # dev-only integration_test plugin. Recreate it for the Android release
        # variant so javac does not try to link a test-only plugin into the APK.
        $generatedPluginRegistrant = Join-Path $repo 'android\app\src\main\java\io\flutter\plugins\GeneratedPluginRegistrant.java'
        if (Test-Path $generatedPluginRegistrant) {
            Remove-Item -LiteralPath $generatedPluginRegistrant -Force
        }

        & $Flutter build apk --release --target-platform android-arm64 --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'Android Release APK build failed.' }
    }
    if (-not (Test-Path (Join-Path $windowsBuild 'NipaPlay.exe'))) {
        throw "Windows Release directory not found: $windowsBuild"
    }
    if (-not (Test-Path $apk)) { throw "Android APK not found: $apk" }

    New-Item -ItemType Directory -Force -Path $output | Out-Null
    $windowsZip = Join-Path $output 'NipaPlay-Personal-Windows-Portable.zip'
    $androidCopy = Join-Path $output 'NipaPlay-Personal-Android.apk'
    if (Test-Path $windowsZip) { Remove-Item -LiteralPath $windowsZip -Force }
    Compress-Archive -Path (Join-Path $windowsBuild '*') -DestinationPath $windowsZip -CompressionLevel Optimal
    Copy-Item -LiteralPath $apk -Destination $androidCopy -Force

    Write-Host "Windows portable archive: $windowsZip"
    Write-Host "Android APK: $androidCopy"
} finally {
    Pop-Location
}
