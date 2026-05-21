<#
.SYNOPSIS
  あおいレールプランナー - Windows セットアップスクリプト
  Flutter SDK + Python + Azure Functions Core Tools をインストールし、
  プロジェクトの初期化を実行します。

.USAGE
  管理者権限の PowerShell で実行:
    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
    .\setup.ps1
#>

$ErrorActionPreference = "Stop"
$FLUTTER_VERSION = "3.22.2"
$FLUTTER_ZIP_URL = "https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_${FLUTTER_VERSION}-stable.zip"
$FLUTTER_INSTALL_DIR = "$env:USERPROFILE\flutter"
$PROJECT_ROOT = $PSScriptRoot

Write-Host "=====================================================" -ForegroundColor Cyan
Write-Host "  おまかせAIレールプランナー セットアップ" -ForegroundColor Cyan
Write-Host "=====================================================" -ForegroundColor Cyan

# ---- 1. Flutter SDK ----
function Install-Flutter {
    if (Get-Command flutter -ErrorAction SilentlyContinue) {
        $ver = (flutter --version 2>&1 | Select-String "Flutter").ToString()
        Write-Host "✅ Flutter already installed: $ver" -ForegroundColor Green
        return
    }

    Write-Host "`n📦 Flutter SDK をダウンロード中... (約500MB)" -ForegroundColor Yellow
    $zipPath = "$env:TEMP\flutter_windows.zip"

    try {
        Invoke-WebRequest -Uri $FLUTTER_ZIP_URL -OutFile $zipPath -UseBasicParsing
        Write-Host "📂 展開中: $FLUTTER_INSTALL_DIR"
        Expand-Archive -Path $zipPath -DestinationPath (Split-Path $FLUTTER_INSTALL_DIR) -Force
        Remove-Item $zipPath

        # PATH に追加
        $flutterBin = "$FLUTTER_INSTALL_DIR\bin"
        $currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
        if ($currentPath -notlike "*$flutterBin*") {
            [Environment]::SetEnvironmentVariable(
                "PATH", "$currentPath;$flutterBin", "User"
            )
            $env:PATH = "$env:PATH;$flutterBin"
            Write-Host "✅ Flutter PATH に追加: $flutterBin" -ForegroundColor Green
        }
    } catch {
        Write-Host "❌ Flutterダウンロード失敗: $_" -ForegroundColor Red
        Write-Host "   手動インストール: https://docs.flutter.dev/get-started/install/windows"
        exit 1
    }
}

# ---- 2. Python 3.11 ----
function Install-Python {
    if (Get-Command python -ErrorAction SilentlyContinue) {
        $ver = python --version 2>&1
        Write-Host "✅ Python already installed: $ver" -ForegroundColor Green
        return
    }

    Write-Host "`n📦 Python 3.11 をインストール中..." -ForegroundColor Yellow
    winget install Python.Python.3.11 --accept-source-agreements --accept-package-agreements
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH", "User")
}

# ---- 3. Azure Functions Core Tools ----
function Install-AzFuncTools {
    if (Get-Command func -ErrorAction SilentlyContinue) {
        Write-Host "✅ Azure Functions Core Tools already installed" -ForegroundColor Green
        return
    }

    Write-Host "`n📦 Azure Functions Core Tools をインストール中..." -ForegroundColor Yellow
    winget install Microsoft.Azure.FunctionsCoreTools --accept-source-agreements --accept-package-agreements
}

# ---- 4. Flutter pub get ----
function Init-Flutter {
    Write-Host "`n📦 Flutter パッケージを取得中..." -ForegroundColor Yellow
    Push-Location "$PROJECT_ROOT\frontend_flutter"
    try {
        flutter pub get
        Write-Host "✅ flutter pub get 完了" -ForegroundColor Green
    } catch {
        Write-Host "⚠️  flutter pub get 失敗: $_" -ForegroundColor Yellow
    } finally {
        Pop-Location
    }
}

# ---- 5. Python 仮想環境 + バックエンド依存パッケージ ----
function Init-Backend {
    Write-Host "`n📦 Pythonバックエンド環境を初期化中..." -ForegroundColor Yellow
    Push-Location "$PROJECT_ROOT\backend_azure_functions"
    try {
        python -m venv .venv
        & ".venv\Scripts\python.exe" -m pip install --upgrade pip
        & ".venv\Scripts\pip.exe" install -r requirements.txt
        Write-Host "✅ バックエンド依存パッケージ インストール完了" -ForegroundColor Green
    } catch {
        Write-Host "⚠️  バックエンド初期化失敗: $_" -ForegroundColor Yellow
    } finally {
        Pop-Location
    }
}

# ---- 6. .env 作成 ----
function Setup-EnvFiles {
    if (-not (Test-Path "$PROJECT_ROOT\.env")) {
        Copy-Item "$PROJECT_ROOT\.env.example" "$PROJECT_ROOT\.env"
        Write-Host "📝 .env を作成しました。値を入力してください: $PROJECT_ROOT\.env" -ForegroundColor Cyan
    }
    if (-not (Test-Path "$PROJECT_ROOT\backend_azure_functions\local.settings.json")) {
        Write-Host "⚠️  local.settings.json の AZURE_OPENAI_KEY 等を入力してください。" -ForegroundColor Yellow
    }
}

# ---- 実行 ----
Install-Python
Install-AzFuncTools
Install-Flutter
Init-Flutter
Init-Backend
Setup-EnvFiles

Write-Host "`n=====================================================" -ForegroundColor Green
Write-Host "  セットアップ完了！" -ForegroundColor Green
Write-Host "=====================================================" -ForegroundColor Green
Write-Host @"

次のコマンドでアプリを起動できます:

  # Flutterアプリ実行（エミュレータが必要）
  cd frontend_flutter
  flutter run --dart-define=API_BASE_URL=https://... --dart-define=FUNC_KEY=...

  # バックエンドローカル実行
  cd backend_azure_functions
  func start

  # YOLOモデル訓練（学習データ配置後）
  cd tools/train
  python train_yolo.py --epochs 100 --device cuda
  python convert_to_tflite.py

"@ -ForegroundColor White
