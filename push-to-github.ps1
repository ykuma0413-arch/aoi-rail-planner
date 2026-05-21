<#
.SYNOPSIS
  あおいレールプランナーを GitHub にプッシュして
  クラウドビルドで Android APK を作成するスクリプト。

.USAGE
  1. https://github.com/signup でアカウント作成（持っていない場合）
  2. PowerShell で以下を順に実行:
       gh auth login              # ブラウザで GitHub にログイン
       .\push-to-github.ps1        # このスクリプト

.PARAMETERS
  -RepoName  リポジトリ名（既定: aoi-rail-planner）
  -Private   非公開リポジトリで作成する場合に指定
#>
param(
    [string]$RepoName = "aoi-rail-planner",
    [switch]$Private
)

$ErrorActionPreference = "Stop"
$env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("PATH","User")

# ---- 認証状態を確認 ----
$authStatus = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ GitHub にログインしていません。" -ForegroundColor Red
    Write-Host "   次のコマンドを実行してから再度このスクリプトを実行してください:" -ForegroundColor Yellow
    Write-Host "       gh auth login" -ForegroundColor White
    Write-Host ""
    Write-Host "   gh auth login の手順:" -ForegroundColor Cyan
    Write-Host "     - What account do you want to log into? → GitHub.com"
    Write-Host "     - What is your preferred protocol? → HTTPS"
    Write-Host "     - Authenticate Git with your GitHub credentials? → Yes"
    Write-Host "     - How would you like to authenticate? → Login with a web browser"
    Write-Host "     - 表示された 8桁のコードをコピーしてブラウザに入力"
    exit 1
}

Write-Host "✅ GitHub 認証済み" -ForegroundColor Green

# ---- リポジトリ作成 ----
$visibility = if ($Private) { "--private" } else { "--public" }
Write-Host "`n📦 リポジトリを作成中: $RepoName ($($visibility -replace '--',''))..." -ForegroundColor Cyan

$createOutput = gh repo create $RepoName $visibility --source=. --remote=origin --description "おまかせAIレールプランナー" 2>&1
if ($LASTEXITCODE -ne 0) {
    if ($createOutput -match "already exists") {
        Write-Host "⚠️  リポジトリは既に存在します。リモートを設定して push します。" -ForegroundColor Yellow
        $username = (gh api user --jq .login).Trim()
        $remoteUrl = "https://github.com/$username/$RepoName.git"
        git remote remove origin 2>$null
        git remote add origin $remoteUrl
    } else {
        Write-Host "❌ リポジトリ作成失敗: $createOutput" -ForegroundColor Red
        exit 1
    }
}

# ---- プッシュ ----
Write-Host "`n📤 コードをプッシュ中..." -ForegroundColor Cyan
git branch -M main
git push -u origin main

if ($LASTEXITCODE -ne 0) {
    Write-Host "❌ プッシュ失敗" -ForegroundColor Red
    exit 1
}

# ---- ワークフロー起動 ----
$username = (gh api user --jq .login).Trim()
$repoUrl = "https://github.com/$username/$RepoName"
$actionsUrl = "$repoUrl/actions"

Write-Host "`n🎉 完了！" -ForegroundColor Green
Write-Host ""
Write-Host "リポジトリ : $repoUrl" -ForegroundColor White
Write-Host "ビルド進捗 : $actionsUrl" -ForegroundColor White
Write-Host ""
Write-Host "📱 APK 取得手順:" -ForegroundColor Cyan
Write-Host "  1. 上記の Actions URL をブラウザで開く"
Write-Host "  2. 'Build Android APK' ワークフローが緑✓になるまで待機（5〜10分）"
Write-Host "  3. 完了後、ページ下部 'Artifacts' から"
Write-Host "     'aoi-rail-planner-debug-apk.zip' をダウンロード"
Write-Host "  4. zip を展開して app-debug.apk を取り出す"
Write-Host "  5. APK をスマホに転送（Googleドライブ・メール・USB等）"
Write-Host "  6. スマホで開き「提供元不明のアプリ」を許可してインストール"
Write-Host ""
Write-Host "Actions ページを今すぐ開きますか？ [Y/N]" -ForegroundColor Yellow
$ans = Read-Host
if ($ans -match "^[YyＹｙ]") {
    Start-Process $actionsUrl
}
