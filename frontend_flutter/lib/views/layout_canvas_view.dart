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
  TransformationController? _viewController;

  // キャンバスの実寸 (1800mm × スケール)
  static const double _canvasPx = 1800.0 * _LayoutPainter.scale;

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
    _viewController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 初期表示でレイアウト（中央配置済み）が画面中央に来るよう平行移動
        _viewController ??= TransformationController(
          Matrix4.translationValues(
            (constraints.maxWidth - _canvasPx) / 2,
            (constraints.maxHeight - _canvasPx) / 2,
            0,
          ),
        );
        return AnimatedBuilder(
          animation: _blinkAnim,
          builder: (context, _) {
            return InteractiveViewer(
              constrained: false,
              boundaryMargin: const EdgeInsets.all(400),
              transformationController: _viewController,
              minScale: 0.3,
              maxScale: 5.0,
              child: CustomPaint(
                size: const Size(_canvasPx, _canvasPx),
                painter: _LayoutPainter(
                  placedRails: widget.layout.placedRails,
                  missingParts: widget.layout.missingParts,
                  suggestOpacity: _blinkAnim.value,
                ),
              ),
            );
          },
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
  // 在庫アイコンと同じ「ずんぐり比率」になる拡大スケール
  // (アイコン: 道床9px/レール長36px ≈ 0.25 → 0.42倍で 106mm = 44.5px, 道床11px)
  static const double scale = 0.42;
  static const double _scale = scale;
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
    const step = 106.0 * _scale; // レール1本分 (106mm) グリッド
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

  static const double _railEndInset = 8.0;  // ジョイント表示用の隙間 (canvas px)
  static const double _jointSize = 6.0;

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

    // 橋脚: 軌道ピースではないので支柱マーカーとして描画してジョイントは省略
    if (rt == RailType.bridgePierStandard || rt == RailType.bridgePierBlock) {
      final pierRect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: origin, width: 15, height: 15),
        const Radius.circular(3),
      );
      canvas.drawRRect(
          pierRect, Paint()..color = const Color(0xFF8D9AA5));
      canvas.drawRRect(
        pierRect,
        Paint()
          ..color = Colors.black38
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
      return;
    }

    _JointPair? joints;
    if (rt == RailType.curveR || rt == RailType.curveRLarge) {
      joints = _drawCurve(canvas, origin, rot, rt == RailType.curveRLarge,
          rail.flipped, paint);
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

  // 道床（青いバンド）の描画幅。在庫アイコンと同じ比率。
  static const double _bandWidth = 11.0;

  /// 直線セグメント: 在庫アイコンと同一の paintBandLine で描画し、ジョイント情報を返す
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

    paintBandLine(canvas, bodyStart, bodyEnd, _bandWidth, paint.color);

    return _JointPair(
      startPos: bodyStart,
      startOutwardAngle: rot + math.pi,
      endPos: bodyEnd,
      endOutwardAngle: rot,
    );
  }

  /// 曲線セグメント: 在庫アイコンと同一の paintBandArc で描画し、ジョイント情報を返す。
  /// flipped=true は右旋回（カーブの反転連結）。
  _JointPair _drawCurve(Canvas canvas, Offset origin, double rot, bool isLarge,
      bool flipped, Paint paint) {
    final radius = (isLarge ? 206.0 : 103.0) * _scale;
    const angleSpan = 22.5 * math.pi / 180.0;
    final arcInset = _railEndInset / radius;

    final Offset center;
    final double drawStart;
    final double drawSpan;
    final double startOutward;
    final double endOutward;

    if (!flipped) {
      // 左旋回: 中心は進行方向の左 (rot+90°)、CCW に掃引
      center = origin +
          Offset(radius * math.cos(rot + math.pi / 2),
              radius * math.sin(rot + math.pi / 2));
      final startAngle = rot - math.pi / 2;
      drawStart = startAngle + arcInset;
      drawSpan = angleSpan - 2 * arcInset;
      // CCW 弧上の進行方向 = 角度 + 90°
      startOutward = drawStart + math.pi / 2 + math.pi;
      endOutward = drawStart + drawSpan + math.pi / 2;
    } else {
      // 右旋回: 中心は進行方向の右 (rot−90°)、CW（負の掃引）
      center = origin +
          Offset(radius * math.cos(rot - math.pi / 2),
              radius * math.sin(rot - math.pi / 2));
      final startAngle = rot + math.pi / 2;
      drawStart = startAngle - arcInset;
      drawSpan = -(angleSpan - 2 * arcInset);
      // CW 弧上の進行方向 = 角度 − 90°
      startOutward = drawStart - math.pi / 2 + math.pi;
      endOutward = drawStart + drawSpan - math.pi / 2;
    }

    paintBandArc(
        canvas, center, radius, drawStart, drawSpan, _bandWidth, paint.color);

    final startWorld = center +
        Offset(radius * math.cos(drawStart), radius * math.sin(drawStart));
    final endWorld = center +
        Offset(radius * math.cos(drawStart + drawSpan),
            radius * math.sin(drawStart + drawSpan));
    return _JointPair(
      startPos: startWorld,
      startOutwardAngle: startOutward,
      endPos: endWorld,
      endOutwardAngle: endOutward,
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
