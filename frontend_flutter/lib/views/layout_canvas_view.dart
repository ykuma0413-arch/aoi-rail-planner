import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/api_models.dart';
import '../models/rail_type.dart';

/// Z軸高さ別カラーコード定義（仕様書 §3.3 準拠）
const _zColors = {
  0: Color(0xFF0072BC), // 1階
  1: Color(0xFF004B87), // 2階
  2: Color(0xFF002855), // 3階
};

Color _colorForZ(int z) => _zColors[z.clamp(0, 2)] ?? const Color(0xFF002855);

/// 2D Canvasレイアウト描画ビュー
/// - Z軸に応じた濃淡表現
/// - サジェストパーツ（不足分）は赤色 + 明滅アニメーション
class LayoutCanvasView extends StatefulWidget {
  final LayoutResponse layout;

  const LayoutCanvasView({super.key, required this.layout});

  @override
  State<LayoutCanvasView> createState() => _LayoutCanvasViewState();
}

class _LayoutCanvasViewState extends State<LayoutCanvasView>
    with SingleTickerProviderStateMixin {
  late AnimationController _blinkController;
  late Animation<double> _blinkAnim;

  @override
  void initState() {
    super.initState();
    // サジェストパーツの明滅アニメーション (0.3〜1.0 opacity)
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _blinkAnim = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _blinkController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _blinkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _blinkAnim,
      builder: (context, _) {
        return InteractiveViewer(
          minScale: 0.3,
          maxScale: 4.0,
          child: CustomPaint(
            size: const Size(400, 400),
            painter: _LayoutPainter(
              placedRails: widget.layout.placedRails,
              missingParts: widget.layout.missingParts,
              suggestOpacity: _blinkAnim.value,
            ),
          ),
        );
      },
    );
  }
}

class _LayoutPainter extends CustomPainter {
  final List<PlacedRail> placedRails;
  final List<MissingPart> missingParts;
  final double suggestOpacity;

  // グリッド原点オフセット（900mm → 表示スケール換算）
  static const double _gridOriginMm = 900.0;
  static const double _scale = 0.25; // mm → pixel (4px = 1mm, 1800mm = 450px)
  static const double _railWidth = 6.0;

  _LayoutPainter({
    required this.placedRails,
    required this.missingParts,
    required this.suggestOpacity,
  });

  Offset _toCanvas(double worldX, double worldY, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final px = cx + (worldX - _gridOriginMm) * _scale;
    final py = cy + (worldY - _gridOriginMm) * _scale;
    return Offset(px, py);
  }

  @override
  void paint(Canvas canvas, Size size) {
    _drawGrid(canvas, size);
    _drawRails(canvas, size);
    _drawMissingHints(canvas, size);
  }

  void _drawGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.grey.withOpacity(0.15)
      ..strokeWidth = 0.5;
    const step = 20.0 * _scale; // 20mm グリッド
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  void _drawRails(Canvas canvas, Size size) {
    // Z=0から順に描画（高い階が上に重なる）
    final byZ = <int, List<PlacedRail>>{};
    for (final r in placedRails) {
      byZ.putIfAbsent(r.zLevel, () => []).add(r);
    }
    for (final z in [0, 1, 2]) {
      for (final rail in byZ[z] ?? []) {
        _drawSingleRail(canvas, size, rail, _colorForZ(z));
      }
    }
  }

  void _drawSingleRail(Canvas canvas, Size size, PlacedRail rail, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = _railWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final rot = rail.rotation * math.pi / 180.0;
    final origin = _toCanvas(rail.originX, rail.originY, size);

    // レールの種別ごとに描画形状を切り替え
    final rt = RailType.fromApiValue(rail.railType);
    if (rt == RailType.curveR || rt == RailType.curveRLarge) {
      _drawCurve(canvas, origin, rot, rt == RailType.curveRLarge, paint);
    } else {
      _drawStraightSegment(canvas, origin, rot, rt, paint);
    }

    // ジョイント端点マーカー
    final dotPaint = Paint()
      ..color = color.withOpacity(0.6)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(origin, 3, dotPaint);
  }

  void _drawStraightSegment(
      Canvas canvas, Offset origin, double rot, RailType? rt, Paint paint) {
    double lengthMm;
    switch (rt) {
      case RailType.straightHalf:
        lengthMm = 53.0;
      case RailType.straightDouble:
        lengthMm = 212.0;
      default:
        lengthMm = 106.0;
    }
    final len = lengthMm * _scale;
    final end = origin + Offset(len * math.cos(rot), len * math.sin(rot));
    canvas.drawLine(origin, end, paint);
  }

  void _drawCurve(Canvas canvas, Offset origin, double rot, bool isLarge, Paint paint) {
    final radius = (isLarge ? 206.0 : 103.0) * _scale;
    const angleSpan = 22.5 * math.pi / 180.0;

    final path = Path();
    path.moveTo(origin.dx, origin.dy);

    // 円弧の中心を計算
    final cx = origin.dx + radius * math.cos(rot + math.pi / 2);
    final cy = origin.dy + radius * math.sin(rot + math.pi / 2);
    final startAngle = rot - math.pi / 2;

    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: radius);
    path.arcTo(rect, startAngle, angleSpan, false);
    canvas.drawPath(path, paint);
  }

  void _drawMissingHints(Canvas canvas, Size size) {
    if (missingParts.isEmpty) return;

    final paint = Paint()
      ..color = const Color(0xFFFF0000).withOpacity(suggestOpacity)
      ..strokeWidth = _railWidth + 2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // 不足パーツを画面端に配置表示
    double hintX = size.width * 0.1;
    for (final missing in missingParts) {
      for (int i = 0; i < missing.count.clamp(0, 4); i++) {
        final start = Offset(hintX, size.height - 50);
        final end = Offset(hintX + 30 * _scale * 4, size.height - 50);
        canvas.drawLine(start, end, paint);
        hintX += 40;
      }
    }
  }

  @override
  bool shouldRepaint(_LayoutPainter old) =>
      old.suggestOpacity != suggestOpacity ||
      old.placedRails != placedRails;
}
