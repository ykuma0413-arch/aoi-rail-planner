import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/api_models.dart';
import '../models/rail_type.dart';
import 'widgets/mini_rail_icon.dart';

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

/// レール両端のジョイント情報
class _JointPair {
  final Offset startPos;
  final double startOutwardAngle;
  final Offset endPos;
  final double endOutwardAngle;
  const _JointPair({
    required this.startPos,
    required this.startOutwardAngle,
    required this.endPos,
    required this.endOutwardAngle,
  });
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

  static const double _railEndInset = 7.0;  // ジョイント表示用の隙間 (canvas px)
  static const double _jointSize = 5.5;

  void _drawSingleRail(Canvas canvas, Size size, PlacedRail rail, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = _railWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final rot = rail.rotation * math.pi / 180.0;
    final origin = _toCanvas(rail.originX, rail.originY, size);

    // 各種別ごとに本体描画 + ジョイントの世界位置/角度を計算
    final rt = RailType.fromApiValue(rail.railType);
    _JointPair? joints;
    if (rt == RailType.curveR || rt == RailType.curveRLarge) {
      joints = _drawCurve(canvas, origin, rot, rt == RailType.curveRLarge, paint);
    } else {
      joints = _drawStraightSegment(canvas, origin, rot, rt, paint);
    }

    // 凸凹ジョイントマーカー（rail body の inset 位置に描画 → 隙間が生まれる）
    if (joints != null) {
      paintFemaleJoint(canvas, joints.startPos, color,
          outwardAngle: joints.startOutwardAngle, size: _jointSize);
      paintMaleJoint(canvas, joints.endPos, color,
          outwardAngle: joints.endOutwardAngle, size: _jointSize);
    }
  }

  // 道床（青いバンド）の描画幅。実物のレール幅 ~38mm 相当を少し強調。
  static const double _bandWidth = 11.0;

  /// 直線セグメント: 実物風の道床（バンド + 2本の溝）で描画し、ジョイント情報を返す
  _JointPair _drawStraightSegment(
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
    final dir = Offset(math.cos(rot), math.sin(rot));
    final end = origin + dir * len;

    // 本体は両端を _railEndInset だけ短く → ジョイント表示用の隙間
    final bodyStart = origin + dir * _railEndInset;
    final bodyEnd = end - dir * _railEndInset;
    final perp = Offset(-math.sin(rot), math.cos(rot));

    // 道床ベース
    final base = Paint()
      ..color = paint.color
      ..strokeWidth = _bandWidth
      ..strokeCap = StrokeCap.butt;
    canvas.drawLine(bodyStart, bodyEnd, base);

    // 2本の溝（車輪ガイド）
    final groove = Paint()
      ..color = Color.lerp(paint.color, Colors.black, 0.32)!
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.butt;
    canvas.drawLine(bodyStart + perp * _bandWidth * 0.22,
        bodyEnd + perp * _bandWidth * 0.22, groove);
    canvas.drawLine(bodyStart - perp * _bandWidth * 0.22,
        bodyEnd - perp * _bandWidth * 0.22, groove);

    return _JointPair(
      startPos: bodyStart,
      startOutwardAngle: rot + math.pi,
      endPos: bodyEnd,
      endOutwardAngle: rot,
    );
  }

  /// 曲線セグメント: 実物風の道床アークで描画し、ジョイント情報を返す
  _JointPair _drawCurve(Canvas canvas, Offset origin, double rot, bool isLarge, Paint paint) {
    final radius = (isLarge ? 206.0 : 103.0) * _scale;
    const angleSpan = 22.5 * math.pi / 180.0;

    final cx = origin.dx + radius * math.cos(rot + math.pi / 2);
    final cy = origin.dy + radius * math.sin(rot + math.pi / 2);
    final center = Offset(cx, cy);
    final startAngle = rot - math.pi / 2;

    final arcInset = _railEndInset / radius;
    final drawStart = startAngle + arcInset;
    final drawSpan = angleSpan - 2 * arcInset;

    // 道床ベースアーク
    final base = Paint()
      ..color = paint.color
      ..strokeWidth = _bandWidth
      ..strokeCap = StrokeCap.butt
      ..style = PaintingStyle.stroke;
    canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius), drawStart, drawSpan, false, base);

    // 2本の溝アーク
    final groove = Paint()
      ..color = Color.lerp(paint.color, Colors.black, 0.32)!
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.butt
      ..style = PaintingStyle.stroke;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius + _bandWidth * 0.22),
        drawStart, drawSpan, false, groove);
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius - _bandWidth * 0.22),
        drawStart, drawSpan, false, groove);

    final startWorld = center +
        Offset(radius * math.cos(drawStart), radius * math.sin(drawStart));
    final endWorld = center +
        Offset(radius * math.cos(drawStart + drawSpan),
            radius * math.sin(drawStart + drawSpan));
    return _JointPair(
      startPos: startWorld,
      startOutwardAngle: drawStart + math.pi / 2 + math.pi,
      endPos: endWorld,
      endOutwardAngle: drawStart + drawSpan + math.pi / 2,
    );
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
