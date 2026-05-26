# ☁️ Azure バックエンドデプロイ手順

## 全体像

```
[1] Azure アカウント作成（あなた / 5〜10分）
        ↓
[2] az login（あなた / 1分）
        ↓
[3] deploy-backend.ps1 実行（私が全部やる）
        ↓
[4] Function URL を取得し APK 再ビルド（私が全部やる）
        ↓
[5] 新APKをスマホに入れて AIレイアウト生成 動作確認
```

---

## Step 1: Azure 無料アカウント作成（あなたの作業）

### 1-1. 必要なもの
- Microsoft アカウント（Hotmail / Outlook / Live のいずれか。なければ作成画面で同時に作れます）
- 電話番号（SMS 認証用）
- クレジットカード（**本人確認のみ。料金請求はされません**）

### 1-2. サインアップ
1. <https://azure.microsoft.com/ja-jp/free> を開く
2. 「**無料で始める**」をクリック
3. Microsoft アカウントでサインイン（または新規作成）
4. 個人情報入力（氏名・住所など）
5. 電話番号で SMS 認証
6. クレジットカード入力（本人確認のみ）
7. 利用規約同意 → サインアップ完了

### 1-3. 無料枠の中身
| サービス | 無料分 | 期間 |
|---|---|---|
| Azure Functions (Consumption Plan) | **100万リクエスト/月** | 永続無料 |
| Cosmos DB Free Tier | **1000RU/s + 25GB** | 永続無料 |
| ストレージ アカウント | 5GB LRS | 12ヶ月無料 |
| 一般クレジット | **$200相当** | 30日間 |

このアプリは MAU 数百人規模まで **完全無料** で運用できます。

---

## Step 2: PC で Azure にログイン（あなたの作業・1コマンドだけ）

PowerShell を開き：

```powershell
cd "C:\Users\user\OneDrive\ドキュメント\テスト"
az login
```

ブラウザが開いて Azure にログインを求められます → さっき作ったアカウントでログイン → ブラウザを閉じる。

PowerShell に戻ると「○○ subscriptions found」と表示されれば成功。

---

## Step 3 以降は私が PowerShell スクリプトで全自動

Azure ログインが終わったら教えてください。
私が `deploy-backend.ps1` を実行して以下を一気にやります：

1. リソースグループ作成（東日本リージョン）
2. ストレージアカウント作成
3. Function App 作成（Linux + Python 3.11）
4. アプリ設定（環境変数）注入
5. コードを zip にして `func azure functionapp publish`
6. Function URL + アクセスキーを取得
7. その値で Flutter APK を再ビルド → 新リリース公開

---

## 💸 料金が発生しないか心配な方へ

以下の対策を入れています：

- **Consumption Plan のみ使用**（リクエスト課金、待機中は0円）
- **支出アラート** $1 / $5 / $10 で設定（自動でメール通知）
- アプリは **モック値で動く** ように設計（OpenAI API キーなしでもフォールバック動作）
- 想定 MAU 1000 人でも **月額 0〜数十円**

---

## トラブル対応

### サインアップで「住所が確認できません」
- ローマ字表記で再入力（例: Tokyo-to / Chuo-ku / 1-1-1）

### クレジットカードが弾かれる
- VISA / Mastercard 推奨
- デビットカードでも可（プリペイドは不可）

### 「サブスクリプションが見つからない」と az login で出る
- `az account list --output table` で確認
- なければ Azure portal でサブスクリプションが「アクティブ」か確認
