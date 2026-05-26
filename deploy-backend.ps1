<#
.SYNOPSIS
  Deploy aoi-rail-planner backend to Azure Functions (consumption plan, free tier).

.USAGE
  1. az login
  2. .\deploy-backend.ps1

.PARAMETERS
  -ResourceGroup  Resource group name (default: rg-aoi-rail)
  -Location       Azure region (default: japaneast)
  -AppName        Function App name (default: aoi-rail-func + random suffix)
#>
param(
    [string]$ResourceGroup = "rg-aoi-rail",
    [string]$Location = "japaneast",
    [string]$AppName = ""
)

$ErrorActionPreference = "Continue"
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")

# ---- Auto-suffix for globally unique name ----
if ([string]::IsNullOrEmpty($AppName)) {
    $suffix = -join ((97..122) + (48..57) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
    $AppName = "aoi-rail-$suffix"
}
$StorageName = ("aoirailstor" + $AppName.Substring($AppName.Length - 6)).ToLower() -replace '[^a-z0-9]', ''

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  Deploy Aoi Rail Backend to Azure" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  ResourceGroup : $ResourceGroup" -ForegroundColor White
Write-Host "  Location      : $Location" -ForegroundColor White
Write-Host "  Function App  : $AppName" -ForegroundColor White
Write-Host "  Storage       : $StorageName" -ForegroundColor White
Write-Host ""

# ---- Check login ----
Write-Host "[1/8] Checking Azure login..." -ForegroundColor Cyan
$accountJson = az account show 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host "[NG] Not logged in. Run: az login" -ForegroundColor Red
    exit 1
}
$account = $accountJson | ConvertFrom-Json
Write-Host "      OK: $($account.user.name) / $($account.name)" -ForegroundColor Green

# ---- Resource group ----
Write-Host "[2/8] Creating resource group..." -ForegroundColor Cyan
az group create --name $ResourceGroup --location $Location --output none
if ($LASTEXITCODE -ne 0) { Write-Host "[NG] failed" -ForegroundColor Red; exit 1 }
Write-Host "      OK" -ForegroundColor Green

# ---- Storage account ----
Write-Host "[3/8] Creating storage account ($StorageName)..." -ForegroundColor Cyan
az storage account create `
    --name $StorageName `
    --resource-group $ResourceGroup `
    --location $Location `
    --sku Standard_LRS `
    --kind StorageV2 `
    --output none
if ($LASTEXITCODE -ne 0) { Write-Host "[NG] failed" -ForegroundColor Red; exit 1 }
Write-Host "      OK" -ForegroundColor Green

# ---- Function App (Linux + Python 3.11 + Consumption) ----
Write-Host "[4/8] Creating Function App ($AppName)..." -ForegroundColor Cyan
az functionapp create `
    --name $AppName `
    --resource-group $ResourceGroup `
    --storage-account $StorageName `
    --consumption-plan-location $Location `
    --runtime python `
    --runtime-version 3.11 `
    --functions-version 4 `
    --os-type Linux `
    --output none
if ($LASTEXITCODE -ne 0) { Write-Host "[NG] failed" -ForegroundColor Red; exit 1 }
Write-Host "      OK" -ForegroundColor Green

# ---- App settings ----
Write-Host "[5/8] Configuring app settings..." -ForegroundColor Cyan
az functionapp config appsettings set `
    --name $AppName `
    --resource-group $ResourceGroup `
    --settings `
        "FUNCTIONS_WORKER_RUNTIME=python" `
        "AzureWebJobsFeatureFlags=EnableWorkerIndexing" `
        "CURRENT_MAU=0" `
        "AFFILIATE_BASE_URL=https://www.amazon.co.jp/s?k=" `
    --output none
if ($LASTEXITCODE -ne 0) { Write-Host "[NG] failed" -ForegroundColor Red; exit 1 }
Write-Host "      OK (OpenAI/Cosmos keys can be added later via az functionapp config appsettings)" -ForegroundColor Green

# ---- Spending alert ($5) ----
Write-Host "[6/8] Setting up spending budget alert..." -ForegroundColor Cyan
$subId = $account.id
$budgetName = "aoi-rail-budget"
$startDate = (Get-Date).ToString("yyyy-MM-01")
$endDate = (Get-Date).AddYears(5).ToString("yyyy-MM-dd")

$budgetJson = @{
    properties = @{
        category = "Cost"
        amount = 5
        timeGrain = "Monthly"
        timePeriod = @{
            startDate = $startDate
            endDate = $endDate
        }
        notifications = @{
            actual_GreaterThan_80_Percent = @{
                enabled = $true
                operator = "GreaterThan"
                threshold = 80
                contactEmails = @($account.user.name)
                thresholdType = "Actual"
            }
        }
    }
} | ConvertTo-Json -Depth 10 -Compress

try {
    $budgetJson | az rest --method put `
        --url "https://management.azure.com/subscriptions/$subId/resourceGroups/$ResourceGroup/providers/Microsoft.Consumption/budgets/${budgetName}?api-version=2021-10-01" `
        --body "@-" 2>&1 | Out-Null
    Write-Host "      OK (alert at \$5/month)" -ForegroundColor Green
} catch {
    Write-Host "      WARN: budget alert failed (non-critical)" -ForegroundColor Yellow
}

# ---- Deploy code ----
Write-Host "[7/8] Deploying code (this takes 2-5 min)..." -ForegroundColor Cyan
Push-Location backend_azure_functions
try {
    func azure functionapp publish $AppName --python --build remote 2>&1 | Tee-Object -Variable deployOutput | Select-Object -Last 5
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[NG] Deployment failed" -ForegroundColor Red
        exit 1
    }
} finally {
    Pop-Location
}
Write-Host "      OK" -ForegroundColor Green

# ---- Get function URL + key ----
Write-Host "[8/8] Fetching Function URL and master key..." -ForegroundColor Cyan
$funcKey = (az functionapp keys list --name $AppName --resource-group $ResourceGroup --query "functionKeys.default" -o tsv).Trim()
$funcUrl = "https://$AppName.azurewebsites.net/api"

Write-Host ""
Write-Host "=====================================================" -ForegroundColor Green
Write-Host "  Deployment Complete!" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  API_BASE_URL : $funcUrl" -ForegroundColor White
Write-Host "  FUNC_KEY     : $funcKey" -ForegroundColor White
Write-Host ""

# ---- Save to .env for next step ----
$envContent = @"
API_BASE_URL=$funcUrl
FUNC_KEY=$funcKey
"@
Set-Content -Path ".env.azure" -Value $envContent -Encoding UTF8
Write-Host "  -> values saved to .env.azure" -ForegroundColor Cyan

# ---- Smoke test ----
Write-Host ""
Write-Host "Smoke test (config endpoint)..." -ForegroundColor Cyan
try {
    $testUrl = "$funcUrl/config?code=$funcKey"
    $response = Invoke-RestMethod -Uri $testUrl -Method Get -TimeoutSec 30
    Write-Host "  Response:" -ForegroundColor White
    $response | ConvertTo-Json -Depth 5 | Write-Host
    Write-Host "[OK] Backend is alive!" -ForegroundColor Green
} catch {
    Write-Host "[WARN] First request might cold-start, retry in 1 min" -ForegroundColor Yellow
    Write-Host "       Error: $_"
}

Write-Host ""
Write-Host "Next: rebuild APK with these values via GitHub Actions" -ForegroundColor Cyan
Write-Host "      .\rebuild-apk-with-backend.ps1" -ForegroundColor White