# 📷 レール認識モデル（YOLOv8）訓練ガイド

アプリ側の推論コードは**実装済み**（信頼度0.35・クラス別NMS・量子化対応）。
あとは実物のレール写真でモデルを訓練し、`.tflite` を差し替えるだけで
カメラスキャンが本物になる。

---

## 全体フロー

```
[1] 写真撮影 (あなた / 30分〜1時間)
       ↓
[2] アノテーション (Roboflow 無料枠 / 1〜2時間)
       ↓
[3] 訓練 (python train_yolo.py / GPU推奨・Colab可)
       ↓
[4] TFLite変換 (python convert_to_tflite.py)
       ↓
[5] assets/models/rail_detector.tflite を上書き → git push → 自動ビルド
```

---

## Step 1: 写真撮影のコツ（最重要）

**最低 100 枚、できれば 300 枚。** 多様性が精度に直結する。

| 条件 | バリエーション |
|---|---|
| 床 | フローリング / カーペット / 畳 / プレイマット の最低3種 |
| 照明 | 昼の自然光 / 夜の電灯 / 影が落ちる状況 |
| 高さ | 真上 70cm / 真上 1m / 斜め45° |
| 配置 | 2〜10本をパラパラ広げる（**重ねない**＝アプリの指示通り） |
| 種類 | 1枚に複数種類を混ぜる（直線+カーブ+坂 など） |

撮影はスマホでOK。アプリの入力は 320×320 に縮小されるので高解像度不要。

## Step 2: アノテーション（Roboflow 無料）

1. <https://roboflow.com> で無料アカウント作成
2. New Project → Object Detection
3. 写真をアップロード → 各レールを矩形で囲んでクラス名を付与
4. **クラス名は必ず以下の英語名を使う**（`dataset.yaml` と完全一致）:

```
straight, straight_half, curve_r, curve_r_large,
incline_start, incline_middle, incline_end, crossing,
switch_left, switch_right, bridge_pier_standard,
bridge_pier_block, flexible, straight_double
```

5. Generate → Export → **YOLOv8 形式** でダウンロード
6. 展開して `data/images/train`, `data/labels/train`, `data/images/val`, `data/labels/val` に配置
   （Roboflow の train/valid 分割をそのまま使えばよい）

> 持っていない種類のレールはアノテーション不要（そのクラスは検出されないだけ）。
> まずは 直線・カーブ・坂 の主要3〜5種だけでも実用になる。

## Step 3: 訓練

ローカルに GPU がない場合は **Google Colab（無料）** 推奨:

```bash
pip install -r requirements.txt
python train_yolo.py --epochs 100 --device cuda   # Colab/GPU
python train_yolo.py --epochs 50  --device cpu    # CPUなら50epochに削減
```

mAP50 が 0.85 以上になれば実用レベル。

## Step 4: TFLite 変換

```bash
python convert_to_tflite.py
# → frontend_flutter/assets/models/rail_detector.tflite を自動上書き
```

INT8量子化で数MBに収まる。

## Step 5: 反映

```powershell
git add frontend_flutter/assets/models/rail_detector.tflite
git commit -m "Add trained rail detector model"
git push   # → GitHub Actions が新APKを自動ビルド
```

---

## アプリ側の実装仕様（参考）

- 入力: 320×320×3。モデルの入力型 (uint8/float32) を自動判別して正規化
- 出力: YOLOv8 形式 `[1, 18, N]` / `[1, N, 18]` の両レイアウトに対応
- 信頼度しきい値 0.35、クラス別 NMS (IoU 0.5)
- 検出個数を種類ごとに集計して在庫に反映（合計100上限ガードあり）
- モック (`[1,14]`) や未知形状は安全に「検出0」へフォールバック
