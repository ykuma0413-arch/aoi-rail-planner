<#
.SYNOPSIS
  Rebuild APK with backend URL via GitHub Actions and publish as v0.1.2.

.USAGE
  After running deploy-backend.ps1:
    .\rebuild-apk-with-backend.ps1
#>
param(
    [string]$Tag = "v0.1.2-mvp",
    [string]$ReleaseTitle = "MVP v0.1.2 - Azure backend connected"
)

$ErrorActionPreference = "Stop"
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")

if (-not (Test-Path ".env.azure")) {
    Write-Host "[NG] .env.azure not found. Run deploy-backend.ps1 first." -ForegroundColor Red
    exit 1
}

# Load values
$lines = Get-Content ".env.azure"
$values = @{}
foreach ($line in $lines) {
    if ($line -match "^([^=]+)=(.+)$") {
        $values[$Matches[1]] = $Matches[2]
    }
}
$apiUrl = $values["API_BASE_URL"]
$funcKey = $values["FUNC_KEY"]

Write-Host "Triggering APK build with:" -ForegroundColor Cyan
Write-Host "  API_BASE_URL : $apiUrl"
Write-Host "  FUNC_KEY     : (hidden, length=$($funcKey.Length))"
Write-Host ""

# Trigger workflow_dispatch with inputs
gh workflow run "Build Android APK" `
    -f api_base_url=$apiUrl `
    -f func_key=$funcKey 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[NG] Failed to trigger workflow" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Build triggered" -ForegroundColor Green
Write-Host ""

# Wait for the run to start, get its ID
Start-Sleep -Seconds 8
$runId = (gh run list --workflow "Build Android APK" --limit 1 --json databaseId --jq ".[0].databaseId").Trim()
Write-Host "Run ID: $runId" -ForegroundColor Cyan
Write-Host "Watching..." -ForegroundColor Cyan
gh run watch $runId --exit-status
if ($LASTEXITCODE -ne 0) {
    Write-Host "[NG] Build failed" -ForegroundColor Red
    exit 1
}

# Download new APK
Write-Host ""
Write-Host "Downloading new APK..." -ForegroundColor Cyan
if (Test-Path "apk_download") { Remove-Item "apk_download" -Recurse -Force }
if (Test-Path "aoi-rail-planner.apk") { Remove-Item "aoi-rail-planner.apk" -Force }
gh run download $runId --dir apk_download --name aoi-rail-planner-debug-apk
$apk = Get-ChildItem "apk_download" -Filter "*.apk" -Recurse | Select-Object -First 1
Copy-Item $apk.FullName -Destination "aoi-rail-planner.apk" -Force
Write-Host "[OK] APK downloaded" -ForegroundColor Green

# Publish release
Write-Host ""
Write-Host "Publishing GitHub release..." -ForegroundColor Cyan
$notesFile = New-TemporaryFile
@"
# Aoi Rail Planner MVP $Tag

## Backend connected!

- API_BASE_URL : $apiUrl
- Build with Azure Functions backend URL hardcoded into APK
- AI layout generation now works end-to-end

## Install
Replace v0.1.1 with this version. Tap APK on phone.
"@ | Out-File $notesFile -Encoding UTF8

# Delete existing release of same tag, if any
gh release delete $Tag --yes 2>$null

gh release create $Tag aoi-rail-planner.apk `
    --title $ReleaseTitle `
    --notes-file $notesFile.FullName
Remove-Item $notesFile -Force

$username = (gh api user --jq .login).Trim()
$apkUrl = "https://github.com/$username/aoi-rail-planner/releases/download/$Tag/aoi-rail-planner.apk"
Write-Host ""
Write-Host "Done!" -ForegroundColor Green
Write-Host "New APK URL: $apkUrl" -ForegroundColor White

# Regenerate QR code
Add-Type -AssemblyName System.Web
$encoded = [System.Web.HttpUtility]::UrlEncode($apkUrl)
$qrUrl = "https://api.qrserver.com/v1/create-qr-code/?size=500x500&data=$encoded"
Invoke-WebRequest -Uri $qrUrl -OutFile "apk-qrcode-$Tag.png" -UseBasicParsing
Write-Host "QR code: $PWD\apk-qrcode-$Tag.png" -ForegroundColor White
Start-Process "$PWD\apk-qrcode-$Tag.png"