"""
あおいレールプランナー - YOLOv8 → TFLite INT8量子化変換スクリプト
使用方法:
    python convert_to_tflite.py \
        --weights output/rail_detector/weights/best.pt \
        --out ../../frontend_flutter/assets/models/rail_detector.tflite

出力ファイルサイズ目標: 5MB 以下
"""
import argparse
import shutil
from pathlib import Path

import numpy as np
from ultralytics import YOLO


def representative_dataset_gen(image_dir: Path, count: int = 100):
    """INT8量子化のためのキャリブレーションデータジェネレータ"""
    import tensorflow as tf
    from PIL import Image

    images = list(image_dir.glob("*.jpg")) + list(image_dir.glob("*.png"))
    images = images[:count]
    if not images:
        # 画像がない場合はランダムデータでフォールバック
        for _ in range(count):
            yield [np.random.randint(0, 255, (1, 320, 320, 3), dtype=np.uint8)]
        return

    for img_path in images:
        img = Image.open(img_path).resize((320, 320))
        arr = np.array(img, dtype=np.uint8)[np.newaxis]
        yield [arr]


def convert(weights: Path, output: Path, calib_dir: Path, imgsz: int = 320):
    """
    .pt → ONNX → TensorFlow SavedModel → TFLite INT8 の変換パイプライン
    """
    print(f"📦 変換元: {weights}")

    # Step 1: YOLOv8 → TFLite (ultralytics 組み込みエクスポート)
    model = YOLO(str(weights))

    # ultralytics の export は INT8 TFLite を直接生成できる
    export_path = model.export(
        format="tflite",
        imgsz=imgsz,
        int8=True,          # INT8量子化
        data=str(calib_dir.parent / "dataset.yaml"),  # キャリブレーションデータ
    )

    src = Path(str(weights).replace(".pt", "_int8.tflite"))
    if not src.exists():
        # フォールバック: exportが返したパスを使用
        src = Path(export_path) if export_path else src

    if src.exists():
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, output)
        size_mb = output.stat().st_size / 1024 / 1024
        print(f"✅ TFLite INT8 出力: {output}  ({size_mb:.2f} MB)")
        if size_mb > 5:
            print(f"⚠️  サイズが5MBを超えています。yolov8n (nano) を使用してください。")
    else:
        print(f"❌ 変換失敗: {src} が見つかりません")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--weights",
        type=Path,
        default=Path("output/rail_detector/weights/best.pt"),
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("../../frontend_flutter/assets/models/rail_detector.tflite"),
    )
    parser.add_argument(
        "--calib-dir",
        type=Path,
        default=Path("data/images/val"),
    )
    parser.add_argument("--imgsz", type=int, default=320)
    args = parser.parse_args()

    convert(args.weights, args.out, args.calib_dir, args.imgsz)
