import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:camera/camera.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;

import '../providers/inventory_provider.dart';
import 'onboarding_overlay.dart';

/// カメラスキャン画面
/// 起動順:
///   1. CAMERAランタイム権限を要求
///   2. CameraController.initialize() でプレビュー開始
///   3. (後追い) TFLite モデルをロード（失敗してもカメラは継続）
///
/// プライバシー要件: カメラバイトデータはTFLite推論直後にnull化
class CameraScanView extends ConsumerStatefulWidget {
  const CameraScanView({super.key});

  @override
  ConsumerState<CameraScanView> createState() => _CameraScanViewState();
}

class _CameraScanViewState extends ConsumerState<CameraScanView> {
  CameraController? _controller;
  Interpreter? _interpreter;
  bool _isProcessing = false;
  bool _showOnboarding = false;
  bool _cameraReady = false;
  bool _scanAvailable = false;  // 実検出モデルが使える状態かどうか（プレースホルダーは false）
  String? _errorMessage;
  String? _modelStatus;  // モデル読込状況をUIに表示

  static const _modelAssetKey = 'assets/models/rail_detector.tflite';
  static const _inputSize = 320;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final show = await OnboardingOverlay.shouldShow();
    if (mounted) setState(() => _showOnboarding = show);
    if (!show) await _startCamera();
  }

  Future<void> _startCamera() async {
    setState(() {
      _errorMessage = null;
      _cameraReady = false;
    });

    // ---- Step 1: ランタイム権限 ----
    PermissionStatus camStatus = await Permission.camera.status;
    if (!camStatus.isGranted) {
      camStatus = await Permission.camera.request();
    }
    if (!camStatus.isGranted) {
      setState(() {
        _errorMessage = camStatus.isPermanentlyDenied
            ? 'カメラ権限が拒否されています。\n端末の設定からアプリのカメラ権限を有効にしてください。'
            : 'カメラの使用が許可されませんでした。';
      });
      return;
    }

    // ---- Step 2: 利用可能カメラ列挙 ----
    List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } catch (e) {
      debugPrint('[camera_scan] availableCameras failed: $e');
      setState(() => _errorMessage =
          'カメラを認識できませんでした。\n端末を再起動してから、もう一度お試しください。');
      return;
    }

    if (cameras.isEmpty) {
      setState(() => _errorMessage = 'この端末にはカメラがありません。');
      return;
    }

    // 背面カメラを優先
    final backCam = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    // ---- Step 3: CameraController 初期化 ----
    _controller = CameraController(
      backCam,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    try {
      await _controller!.initialize();
      if (!mounted) return;
      setState(() => _cameraReady = true);
    } catch (e) {
      debugPrint('[camera_scan] CameraController.initialize failed: $e');
      setState(() => _errorMessage =
          'カメラをうまく起動できませんでした。\n他のアプリでカメラを使用中の場合は閉じてから、もう一度お試しください。');
      return;
    }

    // ---- Step 4: TFLiteモデルを後追いロード（失敗しても致命的でない） ----
    _loadInterpreterInBackground();
  }

  Future<void> _loadInterpreterInBackground() async {
    setState(() => _modelStatus = 'モデル読み込み中…');
    try {
      // assets/ プレフィックス問題回避: rootBundle で直接バイトロード
      final data = await rootBundle.load(_modelAssetKey);
      final bytes = data.buffer.asUint8List();
      final interpreter = Interpreter.fromBuffer(bytes);

      // プレースホルダーモデル判定: 実検出モデルは YOLO形式の3階テンソル
      // ([1, N, 4+nc] 等)を出力する。現状同梱されているのは疎通確認用の
      // モック（出力 [1, 14] の固定ゼロ）なので、形状で見分ける。
      final outShape = interpreter.getOutputTensor(0).shape;
      final isRealModel = outShape.length == 3;

      _interpreter = interpreter;
      if (mounted) {
        setState(() {
          _scanAvailable = isRealModel;
          _modelStatus = isRealModel
              ? 'モデル準備OK'
              : 'AI検出は準備中（手動で入力してね）';
        });
      }
    } catch (e) {
      // モデル失敗してもカメラプレビューは継続
      if (mounted) {
        setState(() {
          _scanAvailable = false;
          _modelStatus = 'モデル未ロード（スキャン無効）';
        });
      }
    }
  }

  Future<void> _captureAndInfer() async {
    if (_isProcessing || _controller == null) return;
    setState(() => _isProcessing = true);

    try {
      final xfile = await _controller!.takePicture();
      Uint8List? imgBytes = await xfile.readAsBytes();

      // プライバシー要件: takePicture がキャッシュ領域に書いた一時ファイルを即削除し、
      // 画像データはメモリ上でのみ扱う
      try {
        await File(xfile.path).delete();
      } catch (_) {}

      if (_interpreter == null || !_scanAvailable) {
        // AI検出が使えない状態（未ロード or プレースホルダーモデル）はスキャン結果なしで戻る
        imgBytes = null;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('AI検出は準備中です。お手数ですが手動でパーツを入力してください'),
            ),
          );
          Navigator.of(context).pop();
        }
        return;
      }

      final decoded = img.decodeImage(imgBytes);
      // プライバシー要件: バイトデータをTFLite推論テンソルに流し込んだ直後にnull化
      imgBytes = null;

      if (decoded == null) {
        throw Exception('画像のデコードに失敗');
      }

      final resized = img.copyResize(decoded, width: _inputSize, height: _inputSize);

      // 入力テンソル: モデルの入力型 (float32 / uint8) に合わせて構築
      final inTensor = _interpreter!.getInputTensor(0);
      final isFloatInput =
          inTensor.type.toString().toLowerCase().contains('float');
      final inputTensor = isFloatInput
          ? _imageToFloatTensor(resized)
          : _imageToIntTensor(resized);

      // 出力テンソル: 型・形状に合わせてバッファ生成
      final outTensor = _interpreter!.getOutputTensor(0);
      final outputShape = outTensor.shape;
      final isFloatOutput =
          outTensor.type.toString().toLowerCase().contains('float');
      final count = outputShape.reduce((a, b) => a * b);
      final outputBuffer = (isFloatOutput
              ? List<double>.filled(count, 0.0)
              : List<int>.filled(count, 0))
          .reshape(outputShape);

      _interpreter!.run(inputTensor, outputBuffer);

      final scanResult = _parseDetections(outputBuffer, outputShape);
      ref.read(inventoryProvider.notifier).loadFromScan(scanResult);

      if (mounted) {
        final totalFound =
            scanResult.values.fold<int>(0, (sum, v) => sum + v);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(scanResult.isEmpty
              ? 'レールが見つかりませんでした。明るい場所で、重ねずに広げて撮ってね'
              : 'スキャン完了！ $totalFound 本のレールを見つけました')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      debugPrint('[camera_scan] capture/inference failed: $e');
      setState(() {
        _errorMessage = '写真の処理に失敗しました。\nもう一度スキャンしてみてください。';
      });
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  List<List<List<List<int>>>> _imageToIntTensor(img.Image image) {
    return List.generate(1, (_) =>
      List.generate(_inputSize, (y) =>
        List.generate(_inputSize, (x) {
          final pixel = image.getPixel(x, y);
          return [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
        })
      )
    );
  }

  List<List<List<List<double>>>> _imageToFloatTensor(img.Image image) {
    return List.generate(1, (_) =>
      List.generate(_inputSize, (y) =>
        List.generate(_inputSize, (x) {
          final pixel = image.getPixel(x, y);
          return [pixel.r / 255.0, pixel.g / 255.0, pixel.b / 255.0];
        })
      )
    );
  }

  // dataset.yaml のクラス順と完全一致させること（RailType全19種）
  static const _classNames = [
    'straight', 'straight_half', 'curve_r', 'curve_r_large',
    'incline_start', 'incline_middle', 'incline_end', 'crossing',
    'switch_left', 'switch_right', 'bridge_pier_standard',
    'bridge_pier_block', 'flexible', 'straight_double',
    'straight_quarter', 'stop_rail', 'switch_y', 'auto_turnout',
    'cross_point',
  ];
  static const _confThreshold = 0.35;
  static const _iouThreshold = 0.50;

  /// YOLOv8 TFLite 出力の解析（信頼度フィルタ + クラス別NMS + 個数集計）。
  /// 対応形状: [1, 4+nc, N]（転置型）/ [1, N, 4+nc]。
  /// モックモデル（[1, 14]）や未知形状は空集計を返す。
  Map<String, int> _parseDetections(dynamic output, List<int> shape) {
    if (shape.length != 3) return {};
    final nc = _classNames.length;
    final attrs = 4 + nc;

    final bool transposed; // true: [1, attrs, N]
    final int numAnchors;
    if (shape[1] == attrs) {
      transposed = true;
      numAnchors = shape[2];
    } else if (shape[2] == attrs) {
      transposed = false;
      numAnchors = shape[1];
    } else {
      return {};
    }

    double at(int anchor, int attr) {
      final v = transposed ? output[0][attr][anchor] : output[0][anchor][attr];
      return (v as num).toDouble();
    }

    // 検出ボックス収集
    final boxes = <List<double>>[]; // [cx, cy, w, h, score, cls]
    for (var i = 0; i < numAnchors; i++) {
      var bestCls = -1;
      var bestScore = 0.0;
      for (var c = 0; c < nc; c++) {
        final s = at(i, 4 + c);
        if (s > bestScore) {
          bestScore = s;
          bestCls = c;
        }
      }
      if (bestScore >= _confThreshold) {
        boxes.add([
          at(i, 0), at(i, 1), at(i, 2), at(i, 3),
          bestScore, bestCls.toDouble(),
        ]);
      }
    }
    if (boxes.isEmpty) return {};

    // クラス別 NMS
    double iou(List<double> a, List<double> b) {
      final ax1 = a[0] - a[2] / 2, ay1 = a[1] - a[3] / 2;
      final ax2 = a[0] + a[2] / 2, ay2 = a[1] + a[3] / 2;
      final bx1 = b[0] - b[2] / 2, by1 = b[1] - b[3] / 2;
      final bx2 = b[0] + b[2] / 2, by2 = b[1] + b[3] / 2;
      final ix = (ax2 < bx2 ? ax2 : bx2) - (ax1 > bx1 ? ax1 : bx1);
      final iy = (ay2 < by2 ? ay2 : by2) - (ay1 > by1 ? ay1 : by1);
      if (ix <= 0 || iy <= 0) return 0;
      final inter = ix * iy;
      final union = a[2] * a[3] + b[2] * b[3] - inter;
      return union <= 0 ? 0 : inter / union;
    }

    final counts = <String, int>{};
    for (var c = 0; c < nc; c++) {
      final clsBoxes = boxes.where((b) => b[5] == c.toDouble()).toList()
        ..sort((a, b) => b[4].compareTo(a[4]));
      final kept = <List<double>>[];
      for (final box in clsBoxes) {
        if (kept.every((k) => iou(box, k) < _iouThreshold)) {
          kept.add(box);
        }
      }
      if (kept.isNotEmpty) {
        counts[_classNames[c]] = kept.length;
      }
    }
    return counts;
  }

  Future<void> _openAppSettings() async {
    await openAppSettings();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _interpreter?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_showOnboarding) {
      return OnboardingOverlay(
        onDismiss: () async {
          setState(() => _showOnboarding = false);
          await _startCamera();
        },
      );
    }

    if (_errorMessage != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('カメラスキャン')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text(_errorMessage!, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('再試行'),
                      onPressed: _startCamera,
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.settings),
                      label: const Text('設定を開く'),
                      onPressed: _openAppSettings,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (!_cameraReady || _controller == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('カメラスキャン')),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('カメラを準備中…'),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('パーツをスキャン'),
        actions: [
          if (_modelStatus != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  _modelStatus!,
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          CameraPreview(_controller!),
          Center(
            child: Container(
              width: 280,
              height: 280,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 2),
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: Column(
                children: [
                  if (!_scanAvailable) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          vertical: 8, horizontal: 12),
                      decoration: BoxDecoration(
                        color: Colors.orange.withOpacity(0.85),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        '⚠️ AI検出はただいま準備中です。下の「手動で入力する」からパーツを追加してね',
                        style: TextStyle(color: Colors.white, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ] else
                    const Text(
                      'パーツを枠内に広げて置いてください',
                      style: TextStyle(color: Colors.white),
                      textAlign: TextAlign.center,
                    ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0072BC),
                      disabledBackgroundColor: Colors.grey,
                      padding: const EdgeInsets.symmetric(
                          vertical: 14, horizontal: 32),
                    ),
                    onPressed: (_isProcessing || !_scanAvailable)
                        ? null
                        : _captureAndInfer,
                    icon: _isProcessing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            _scanAvailable ? Icons.camera : Icons.camera_alt_outlined,
                            color: Colors.white),
                    label: Text(
                      _isProcessing
                          ? '解析中…'
                          : (_scanAvailable ? 'スキャン' : 'AI検出 準備中'),
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                  if (!_scanAvailable) ...[
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        '手動で入力する',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
