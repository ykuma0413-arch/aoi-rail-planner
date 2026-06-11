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
    // 2パス描画:
    //   1パス目: 全ピースの道床（Z=0から順、高い階が上に重なる）
    //   2パス目: 全継ぎ目マーカー（後続ピースの道床に塗りつぶされないように）
    final byZ = <int, List<PlacedRail>>{};
    for (final r in placedRails) {
      byZ.putIfAbsent(r.zLevel, () => []).add(r);
    }

    final connectors = <(_JointPair, Color)>[];
    var isFirstTrackPiece = true;
    _JointPair? firstJoints;
    Color? firstColor;

    for (final z in [0, 1, 2]) {
      for (final rail in byZ[z] ?? []) {
        final color = _colorForZ(z);
        final joints = _drawRailBody(canvas, size, rail, color);
        if (joints != null) {
          connectors.add((joints, color));
          if (isFirstTrackPiece) {
            firstJoints = joints;
            firstColor = color;
            isFirstTrackPiece = false;
          }
        }
      }
    }

    // 継ぎ目: 各ピースの終端（オス側）に1個 = 連結部1箇所につき1マーカー
    for (final (joints, color) in connectors) {
      _drawConnector(canvas, joints.endPos, joints.endOutwardAngle, color);
    }
    // 開いたチェーンの先頭（メス側）にはホールを表示
    if (firstJoints != null && firstColor != null) {
      _drawOpenHole(canvas, firstJoints.startPos,
          firstJoints.startOutwardAngle + math.pi, firstColor);
    }
  }

  /// 連結済みの継ぎ目: 道床を横切るシームライン + ペグ円（実物を上から見た接合部）
  void _drawConnector(Canvas canvas, Offset pos, double travelAngle, Color color) {
    final t = Offset(math.cos(travelAngle), math.sin(travelAngle));
    final perp = Offset(-t.dy, t.dx);
    final seam = Paint()
      ..color = grooveColorOf(color)
      ..strokeWidth = 1.4;
    canvas.drawLine(
        pos + perp * (_bandWidth / 2), pos - perp * (_bandWidth / 2), seam);
    // ペグ（次のレールのホールに収まった状態の小さな円）
    final pegCenter = pos + t * 3.6;
    canvas.drawCircle(pegCenter, 2.6, Paint()..color = grooveColorOf(color));
    canvas.drawCircle(
        pegCenter, 1.4, Paint()..color = Colors.white.withOpacity(0.9));
  }

  /// 開いた端のメスホール（未連結を表す）
  void _drawOpenHole(Canvas canvas, Offset pos, double intoAngle, Color color) {
    final t = Offset(math.cos(intoAngle), math.sin(intoAngle));
    final holeCenter = pos + t * 3.6;
    canvas.drawCircle(holeCenter, 2.6, Paint()..color = Colors.white);
    canvas.drawCircle(
      holeCenter,
      2.6,
      Paint()
        ..color = grooveColorOf(color)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  /// ピース1個分の道床を描画し、両端のジョイント情報を返す（橋脚は null）
  _JointPair? _drawRailBody(
      Canvas canvas, Size size, PlacedRail rail, Color color) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = _railWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final rot = rail.rotation * math.pi / 180.0;
    final origin = _toCanvas(rail.originX, rail.originY, size);

    final rt = RailType.fromApiValue(rail.railType);

    // 橋脚: 軌道ピースではないので支柱マーカーとして描画
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
      return null;
    }

    if (rt == RailType.curveR || rt == RailType.curveRLarge) {
      return _drawCurve(canvas, origin, rot, rt == RailType.curveRLarge,
          rail.flipped, paint);
    }
    return _drawStraightSegment(canvas, origin, rot, rt, paint);
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

    // 実物の連結済みレールと同様、道床は隙間なく連続させる
    paintBandLine(canvas, origin, end, _bandWidth, paint.color);

    return _JointPair(
      startPos: origin,
      startOutwardAngle: rot + math.pi,
      endPos: end,
      endOutwardAngle: rot,
    );
  }

  /// 曲線セグメント: 在庫アイコンと同一の paintBandArc で描画し、ジョイント情報を返す。
  /// flipped=true は右旋回（カーブの反転連結）。
  _JointPair _drawCurve(Canvas canvas, Offset origin, double rot, bool isLarge,
      bool flipped, Paint paint) {
    final radius = (isLarge ? 206.0 : 103.0) * _scale;
    const angleSpan = 22.5 * math.pi / 180.0;

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
      drawStart = rot - math.pi / 2;
      drawSpan = angleSpan;
      // CCW 弧上の進行方向 = 角度 + 90°
      startOutward = drawStart + math.pi / 2 + math.pi;
      endOutward = drawStart + drawSpan + math.pi / 2;
    } else {
      // 右旋回: 中心は進行方向の右 (rot−90°)、CW（負の掃引）
      center = origin +
          Offset(radius * math.cos(rot - math.pi / 2),
              radius * math.sin(rot - math.pi / 2));
      drawStart = rot + math.pi / 2;
      drawSpan = -angleSpan;
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
