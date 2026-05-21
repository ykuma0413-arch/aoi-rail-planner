<#
.SYNOPSIS
  Push aoi-rail-planner to GitHub and trigger cloud APK build.
.USAGE
  1. Sign up at https://github.com/signup (if needed)
  2. Run: gh auth login
  3. Run: .\push-to-github.ps1
#>
param(
    [string]$RepoName = "aoi-rail-planner",
    [switch]$Private
)

$ErrorActionPreference = "Stop"
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Push aoi-rail-planner to GitHub" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host ""

# Check auth
gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[NG] Not logged in to GitHub." -ForegroundColor Red
    Write-Host "     Run this first:" -ForegroundColor Yellow
    Write-Host "         gh auth login" -ForegroundColor White
    Write-Host ""
    Write-Host "     Then choose:" -ForegroundColor Cyan
    Write-Host "       Account  : GitHub.com"
    Write-Host "       Protocol : HTTPS"
    Write-Host "       Auth Git : Yes"
    Write-Host "       Method   : Login with a web browser"
    exit 1
}
Write-Host "[OK] GitHub authenticated" -ForegroundColor Green

# Create repo
$visibility = if ($Private) { "--private" } else { "--public" }
Write-Host ""
Write-Host "Creating repository: $RepoName ($($visibility -replace '--',''))..." -ForegroundColor Cyan

$createOutput = gh repo create $RepoName $visibility --source=. --remote=origin --description "Aoi Rail Planner MVP" 2>&1
if ($LASTEXITCODE -ne 0) {
    $outStr = $createOutput | Out-String
    if ($outStr -match "already exists") {
        Write-Host "[WARN] Repository already exists. Resetting remote and pushing." -ForegroundColor Yellow
        $username = (gh api user --jq .login).Trim()
        $remoteUrl = "https://github.com/$username/$RepoName.git"
        git remote remove origin 2>$null
        git remote add origin $remoteUrl
    } else {
        Write-Host "[NG] Failed to create repository:" -ForegroundColor Red
        Write-Host $outStr
        exit 1
    }
}

# Push
Write-Host ""
Write-Host "Pushing code..." -ForegroundColor Cyan
git branch -M main
git push -u origin main
if ($LASTEXITCODE -ne 0) {
    Write-Host "[NG] Push failed" -ForegroundColor Red
    exit 1
}

# Show URLs
$username = (gh api user --jq .login).Trim()
$repoUrl = "https://github.com/$username/$RepoName"
$actionsUrl = "$repoUrl/actions"

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Green
Write-Host "  Done!" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Repository : $repoUrl" -ForegroundColor White
Write-Host "Build URL  : $actionsUrl" -ForegroundColor White
Write-Host ""
Write-Host "APK download steps:" -ForegroundColor Cyan
Write-Host "  1. Open Actions URL in browser"
Write-Host "  2. Wait for 'Build Android APK' to finish (green check, 5-10 min)"
Write-Host "  3. Scroll to 'Artifacts' section"
Write-Host "  4. Download 'aoi-rail-planner-debug-apk.zip'"
Write-Host "  5. Unzip and copy app-debug.apk to your phone"
Write-Host "  6. Enable 'Install unknown apps' on phone and tap the APK"
Write-Host ""
Write-Host "Open Actions page now? (Y/N)" -ForegroundColor Yellow
$ans = Read-Host
if ($ans -match "^[Yy]") {
    Start-Process $actionsUrl
}