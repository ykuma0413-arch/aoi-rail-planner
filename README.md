# おまかせAIレールプランナー

スマートフォン用あおいレール自動設計アプリ（MVP）

## アーキテクチャ

```
[Flutter App] ──JSON API──> [Azure Functions (Python)]
                                     │
                              ┌──────┴──────┐
                         [Azure OpenAI]  [Cosmos DB]
```

## セットアップ

### 前提条件
- Windows 10/11 (PowerShell 5.1+)
- または macOS / Linux

### 一発セットアップ（Windows）

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
.\setup.ps1
```

スクリプトが自動で以下をインストールします:
- Flutter SDK 3.32.1
- Python 3.11 + Azure Functions Core Tools
- すべての依存パッケージ

### 手動セットアップ

```bash
# 1. Flutter インストール
# https://docs.flutter.dev/get-started/install

# 2. パッケージ取得
cd frontend_flutter
flutter pub get

# 3. バックエンド Python 環境
cd ../backend_azure_functions
python -m venv .venv
.venv/bin/pip install -r requirements.txt  # macOS/Linux
# .venv\Scripts\pip install -r requirements.txt  # Windows
```

## 環境変数の設定

```bash
cp .env.example .env
# .env を編集して API キーを入力
```

必須の環境変数:

| 変数 | 説明 |
|------|------|
| `AZURE_OPENAI_ENDPOINT` | Azure OpenAI エンドポイント URL |
| `AZURE_OPENAI_KEY` | Azure OpenAI API キー |
| `COSMOS_ENDPOINT` | Cosmos DB エンドポイント |
| `COSMOS_KEY` | Cosmos DB 主キー |
| `AFFILIATE_BASE_URL` | アフィリエイトリンクのベース URL |

## 開発実行

```bash
# バックエンド（ローカル）
cd backend_azure_functions
func start

# フロントエンド（エミュレータ or 実機）
cd frontend_flutter
flutter run \
  --dart-define=API_BASE_URL=http://localhost:7071/api \
  --dart-define=FUNC_KEY=
```

## テスト

```bash
# バックエンドアルゴリズムテスト
cd backend_azure_functions
python test_algorithm.py
python test_cosmos_retry.py

# フロントエンドテスト
cd frontend_flutter
flutter test
flutter analyze
```

## YOLOv8 モデルの訓練

```bash
cd tools/train
pip install -r requirements.txt

# 1. データ収集: data/images/train/ に写真を追加
# 2. アノテーション: data/labels/train/ に YOLO形式ラベルを追加
# 3. 訓練
python train_yolo.py --epochs 100 --device cuda

# 4. TFLite INT8 変換
python convert_to_tflite.py

# 開発用モックモデル（精度なし）
python generate_mock_model.py
```

## デプロイ

### Azure Functions

```bash
cd backend_azure_functions
func azure functionapp publish YOUR-FUNC-APP-NAME
```

### Android APK

```bash
cd frontend_flutter
flutter build apk --release \
  --dart-define=API_BASE_URL=https://YOUR-FUNC.azurewebsites.net/api \
  --dart-define=FUNC_KEY=YOUR_KEY
```

### iOS IPA

```bash
cd frontend_flutter
flutter build ipa --release \
  --dart-define=API_BASE_URL=https://YOUR-FUNC.azurewebsites.net/api \
  --dart-define=FUNC_KEY=YOUR_KEY
```

## コンプライアンス

- アプリ内に "プラレール" "タカラトミー" の文字列を含まないこと
- カメラ画像は推論後に即座にメモリから削除（ローカル保存禁止）
- 初回起動時に18歳以上の確認を表示
- CI で自動コンプライアンスチェック実施（.github/workflows/ci.yml）

## ファイル構成

```
.
├── frontend_flutter/          # Flutter アプリ
│   ├── lib/
│   │   ├── models/            # データモデル
│   │   ├── providers/         # Riverpod 状態管理
│   │   └── views/             # 画面 UI
│   └── assets/models/         # TFLite モデル配置先
├── backend_azure_functions/   # Azure Functions バックエンド
│   └── layout_generator/
│       ├── algorithm.py       # 200ms タイムアウト探索
│       ├── rail_db.py         # レール幾何学DB
│       ├── llm_client.py      # Azure OpenAI + フォールバック
│       └── cosmos_client.py   # Cosmos DB + Exponential Backoff
├── tools/train/               # YOLOv8 訓練パイプライン
├── .github/workflows/ci.yml   # CI/CD (GitHub Actions)
└── setup.ps1                  # Windows セットアップスクリプト
```
