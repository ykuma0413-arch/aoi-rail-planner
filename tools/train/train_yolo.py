"""
あおいレールプランナー - YOLOv8 ファインチューニングスクリプト
使用方法:
    python train_yolo.py [--epochs 100] [--batch 16] [--device cuda]

前提:
    - data/images/train/ に学習画像を配置
    - data/labels/train/ に対応するYOLOアノテーションを配置
    - data/images/val/ / data/labels/val/ に検証データを配置
"""
import argparse
from pathlib import Path
from ultralytics import YOLO

BASE_DIR = Path(__file__).parent
DATASET_YAML = BASE_DIR / "data" / "dataset.yaml"
OUTPUT_DIR = BASE_DIR / "output"


def train(epochs: int = 100, batch: int = 16, device: str = "cpu",
          imgsz: int = 320, pretrained: str = "yolov8n.pt") -> Path:
    """
    YOLOv8n をベースにファインチューニング。
    小型モデル (nano) を使用して最終TFLiteサイズを最小化する。
    """
    OUTPUT_DIR.mkdir(exist_ok=True)

    model = YOLO(pretrained)
    results = model.train(
        data=str(DATASET_YAML),
        epochs=epochs,
        batch=batch,
        imgsz=imgsz,
        device=device,
        project=str(OUTPUT_DIR),
        name="rail_detector",
        save=True,
        val=True,
        patience=20,       # Early stopping
        optimizer="AdamW",
        lr0=0.001,
        augment=True,      # データ拡張（回転・フリップ・輝度変化）
        degrees=180.0,     # レールは全方向に置かれるため360°回転を許可
        flipud=0.5,
        fliplr=0.5,
        hsv_v=0.4,         # 照明変化に強くする
        mosaic=1.0,
        workers=4,
    )

    best_weights = OUTPUT_DIR / "rail_detector" / "weights" / "best.pt"
    print(f"\n✅ 学習完了: {best_weights}")
    return best_weights


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--epochs", type=int, default=100)
    parser.add_argument("--batch", type=int, default=16)
    parser.add_argument("--device", type=str, default="cpu")
    parser.add_argument("--imgsz", type=int, default=320)
    args = parser.parse_args()

    train(args.epochs, args.batch, args.device, args.imgsz)
