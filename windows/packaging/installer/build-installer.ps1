#requires -version 5
<#
  Builds the AnywhereLLM Windows installer (.msi):
   1. publishes the self-contained single-file exe
   2. packs it into a per-user MSI with WiX (Start-Menu shortcut + uninstall entry)

  Prereqs: .NET SDK 10, WiX 7  (dotnet tool install --global wix)
  Output:  packaging/installer/AnywhereLLM-<version>-x64.msi (+ printed SHA256)
#>
param([string]$Runtime = "win-x64")
$ErrorActionPreference = "Stop"

$repo    = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$version = (Get-Content (Join-Path $repo "VERSION") -Raw).Trim()
$proj    = Join-Path $repo "windows\AnywhereLLM.App\AnywhereLLM.App.csproj"
$icon    = Join-Path $repo "windows\AnywhereLLM.App\Resources\AppIcon.ico"
$exe     = Join-Path $repo "windows\AnywhereLLM.App\bin\Release\net10.0-windows\$Runtime\publish\AnywhereLLM.exe"
$wxs     = Join-Path $PSScriptRoot "AnywhereLLM.wxs"
$msi     = Join-Path $PSScriptRoot "AnywhereLLM-$version-x64.msi"
$zip     = Join-Path $PSScriptRoot "AnywhereLLM-$version-win-x64.zip"
$sums    = Join-Path $PSScriptRoot "SHA256SUMS.txt"

Write-Host "== publishing self-contained exe (v$version) =="
dotnet publish $proj -c Release -r $Runtime --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
if (-not (Test-Path $exe)) { throw "publish produced no exe at $exe" }

Write-Host "== building MSI =="
wix build $wxs -arch x64 -d "Version=$version" -d "ExePath=$exe" -d "IconPath=$icon" -o $msi
if ($LASTEXITCODE -ne 0) { throw "wix build failed ($LASTEXITCODE)" }

Write-Host "== packaging portable zip (self-update asset) =="
# The self-updater downloads this zip (just the self-contained exe) and swaps it in
# place — no installer. The MSI stays first-install only.
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $exe -DestinationPath $zip
if (-not (Test-Path $zip)) { throw "zip packaging failed at $zip" }

# SHA256SUMS.txt (two-space sha256sum format, LF endings) — the updater verifies the
# downloaded zip against this before swapping. MSI included for manual verification.
$lines = foreach ($f in @($zip, $msi)) {
    $h = (Get-FileHash $f -Algorithm SHA256).Hash.ToLower()
    "$h  $([System.IO.Path]::GetFileName($f))"
}
[System.IO.File]::WriteAllText($sums, ($lines -join "`n") + "`n")

Write-Host ""
Write-Host "MSI:    $msi"
Write-Host "ZIP:    $zip"
Write-Host "SUMS:   $sums"
Write-Host ("MSI SIZE: {0:N1} MB" -f ((Get-Item $msi).Length / 1MB))
Write-Host ("ZIP SIZE: {0:N1} MB" -f ((Get-Item $zip).Length / 1MB))
Get-Content $sums | ForEach-Object { Write-Host $_ }
