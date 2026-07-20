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

Write-Host "== publishing self-contained exe (v$version) =="
dotnet publish $proj -c Release -r $Runtime --self-contained true `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
if (-not (Test-Path $exe)) { throw "publish produced no exe at $exe" }

Write-Host "== building MSI =="
wix build $wxs -arch x64 -d "Version=$version" -d "ExePath=$exe" -d "IconPath=$icon" -o $msi
if ($LASTEXITCODE -ne 0) { throw "wix build failed ($LASTEXITCODE)" }

$sha = (Get-FileHash $msi -Algorithm SHA256).Hash
Write-Host ""
Write-Host "MSI:    $msi"
Write-Host ("SIZE:   {0:N1} MB" -f ((Get-Item $msi).Length / 1MB))
Write-Host "SHA256: $sha"
