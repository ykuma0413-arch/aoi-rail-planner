このディレクトリに以下のファイルを配置してください:

  rail_detector.tflite
    - YOLOv8 INT8量子化モデル（レールパーツ検出用）
    - 目標サイズ: 数MB以下
    - 量子化コマンド例:
        tflite_convert --saved_model_dir=./saved_model \
          --output_file=rail_detector.tflite \
          --inference_type=INT8 \
          --representative_dataset_file=representative_data.py

モデルの入力:
  - Shape: [1, 320, 320, 3]  (INT8)

モデルの出力:
  - Shape: [1, N, 6]  (class_id, conf, x, y, w, h)

クラスIDとRailType.apiValueのマッピングは
camera_scan_view.dart の _parseDetections() に実装してください。
