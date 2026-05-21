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
      setState(() => _errorMessage = 'カメラ列挙に失敗: $e');
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
      setState(() => _errorMessage = 'カメラの初期化に失敗: $e');
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
      _interpreter = Interpreter.fromBuffer(bytes);
      if (mounted) setState(() => _modelStatus = 'モデル準備OK');
    } catch (e) {
      // モデル失敗してもカメラプレビューは継続
      if (mounted) setState(() => _modelStatus = 'モデル未ロード（スキャン無効）');
    }
  }

  Future<void> _captureAndInfer() async {
    if (_isProcessing || _controller == null) return;
    setState(() => _isProcessing = true);

    try {
      final xfile = await _controller!.takePicture();
      Uint8List? imgBytes = await xfile.readAsBytes();

      if (_interpreter == null) {
        // モデル未ロード時はスキャン結果なしで戻る
        imgBytes = null;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('モデル未ロードのため、スキャン結果は空です')),
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
      final inputTensor = _imageToInputTensor(resized);

      final outputShape = _interpreter!.getOutputTensor(0).shape;
      final outputBuffer = List.filled(
        outputShape.reduce((a, b) => a * b),
        0,
      ).reshape(outputShape);

      _interpreter!.run(inputTensor, outputBuffer);

      final scanResult = _parseDetections(outputBuffer);
      ref.read(inventoryProvider.notifier).loadFromScan(scanResult);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(scanResult.isEmpty
              ? 'スキャン完了（検出なし: モックモデルは認識精度を持ちません）'
              : 'スキャン完了！${scanResult.length}種類検出')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'スキャンに失敗: $e';
      });
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  List<List<List<List<int>>>> _imageToInputTensor(img.Image image) {
    return List.generate(1, (_) =>
      List.generate(_inputSize, (y) =>
        List.generate(_inputSize, (x) {
          final pixel = image.getPixel(x, y);
          return [pixel.r.toInt(), pixel.g.toInt(), pixel.b.toInt()];
        })
      )
    );
  }

  Map<String, int> _parseDetections(dynamic output) {
    // 実モデル投入後にYOLO出力を解析する実装に置き換える
    return {};
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
                  const Text(
                    'パーツを枠内に広げて置いてください',
                    style: TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0072BC),
                      padding: const EdgeInsets.symmetric(
                          vertical: 14, horizontal: 32),
                    ),
                    onPressed: _isProcessing ? null : _captureAndInfer,
                    icon: _isProcessing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.camera, color: Colors.white),
                    label: Text(
                      _isProcessing ? '解析中…' : 'スキャン',
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
