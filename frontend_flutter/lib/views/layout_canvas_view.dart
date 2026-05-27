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

  /// 直線セグメントを描画し、ジョイント位置・角度を返す
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

    // 本体は両端を _railEndInset だけ内側に短くする → ジョイント表示用の隙間
    final bodyStart = origin + dir * _railEndInset;
    final bodyEnd = end - dir * _railEndInset;

    final perp = Offset(-math.sin(rot), math.cos(rot));
    const gauge = 3.5;

    final railPaint = Paint()
      ..color = paint.color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(bodyStart + perp * gauge, bodyEnd + perp * gauge, railPaint);
    canvas.drawLine(bodyStart - perp * gauge, bodyEnd - perp * gauge, railPaint);
    canvas.drawLine(bodyStart, bodyEnd, paint);

    // 枕木
    final tiePaint = Paint()
      ..color = paint.color.withOpacity(0.5)
      ..strokeWidth = 1.5;
    final bodyLenMm = lengthMm - (2 * _railEndInset / _scale);
    final tieCount = (bodyLenMm / 20).round().clamp(2, 8);
    for (int i = 1; i < tieCount; i++) {
      final t = i / tieCount;
      final tieCenter = Offset.lerp(bodyStart, bodyEnd, t)!;
      canvas.drawLine(
        tieCenter + perp * (gauge + 1.5),
        tieCenter - perp * (gauge + 1.5),
        tiePaint,
      );
    }
    // ジョイント: 本体の終端位置で、外向き = レール方向の反対 (start) / 同方向 (end)
    return _JointPair(
      startPos: bodyStart,
      startOutwardAngle: rot + math.pi,
      endPos: bodyEnd,
      endOutwardAngle: rot,
    );
  }

  /// 曲線セグメントを描画し、ジョイント位置・角度を返す
  _JointPair _drawCurve(Canvas canvas, Offset origin, double rot, bool isLarge, Paint paint) {
    final radius = (isLarge ? 206.0 : 103.0) * _scale;
    const angleSpan = 22.5 * math.pi / 180.0;

    // 円弧中心
    final cx = origin.dx + radius * math.cos(rot + math.pi / 2);
    final cy = origin.dy + radius * math.sin(rot + math.pi / 2);
    final startAngle = rot - math.pi / 2;

    // 弧長で inset を入れる (radian換算)
    final arcInset = _railEndInset / radius;
    final drawStart = startAngle + arcInset;
    final drawSpan = angleSpan - 2 * arcInset;

    const gauge = 3.5;
    final rectMid = Rect.fromCircle(center: Offset(cx, cy), radius: radius);
    final rectOuter = Rect.fromCircle(center: Offset(cx, cy), radius: radius + gauge);
    final rectInner = Rect.fromCircle(center: Offset(cx, cy), radius: radius - gauge);

    final railPaint = Paint()
      ..color = paint.color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawArc(rectOuter, drawStart, drawSpan, false, railPaint);
    canvas.drawArc(rectInner, drawStart, drawSpan, false, railPaint);
    canvas.drawArc(rectMid, drawStart, drawSpan, false, paint);

    // ジョイント位置 = inset 後の弧の両端
    final startWorld = Offset(cx + radius * math.cos(drawStart), cy + radius * math.sin(drawStart));
    final endWorld = Offset(cx + radius * math.cos(drawStart + drawSpan),
        cy + radius * math.sin(drawStart + drawSpan));
    // 接線方向 = 半径方向 + 90°
    final tangentAtStart = drawStart + math.pi / 2;
    final tangentAtEnd = drawStart + drawSpan + math.pi / 2;
    return _JointPair(
      startPos: startWorld,
      startOutwardAngle: tangentAtStart + math.pi,  // 開始側は接線の逆方向
      endPos: endWorld,
      endOutwardAngle: tangentAtEnd,
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
