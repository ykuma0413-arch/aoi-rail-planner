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

const double _kScale = 0.42;           // mm → px
const double _kCanvasPx = 1800.0 * _kScale;
const Color _kHighlight = Color(0xFFFF8F00);

Offset _worldToCanvas(double mmX, double mmY) {
  const c = _kCanvasPx / 2;
  return Offset(c + (mmX - 900.0) * _kScale, c + (mmY - 900.0) * _kScale);
}

// ============================================================
// 走行経路モデル
// ============================================================

class _PathSeg {
  final double length;
  final bool isArc;
  // 直線用
  final Offset start;
  final Offset dirU;
  // 弧用
  final Offset center;
  final double radius;
  final double startAngle;
  final double angSign; // +1 = CCW(左), -1 = CW(右)

  const _PathSeg.line(this.start, this.dirU, this.length)
      : isArc = false,
        center = Offset.zero,
        radius = 0,
        startAngle = 0,
        angSign = 0;

  const _PathSeg.arc(this.center, this.radius, this.startAngle, this.angSign,
      this.length)
      : isArc = true,
        start = Offset.zero,
        dirU = Offset.zero;

  Offset posAt(double s) {
    if (!isArc) return start + dirU * s;
    final a = startAngle + angSign * (s / radius);
    return center + Offset(radius * math.cos(a), radius * math.sin(a));
  }

  double headingAt(double s) {
    if (!isArc) return math.atan2(dirU.dy, dirU.dx);
    final a = startAngle + angSign * (s / radius);
    return a + angSign * math.pi / 2;
  }
}

/// 生成されたコースの走行経路（チェーン順 = エンジンの出力順）
class TrainPath {
  final List<_PathSeg> segments;
  final double totalLength;

  TrainPath._(this.segments, this.totalLength);

  factory TrainPath.fromRails(List<PlacedRail> rails) {
    final segs = <_PathSeg>[];
    var total = 0.0;
    for (final rail in rails) {
      final rt = RailType.fromApiValue(rail.railType);
      if (rt == RailType.bridgePierStandard ||
          rt == RailType.bridgePierBlock) {
        continue; // 橋脚は経路に含まない
      }
      final origin = _worldToCanvas(rail.originX, rail.originY);
      final rot = rail.rotation * math.pi / 180.0;

      if (rt == RailType.curveR || rt == RailType.curveRLarge) {
        final radius = (rt == RailType.curveRLarge ? 206.0 : 103.0) * _kScale;
        const span = 22.5 * math.pi / 180.0;
        final len = radius * span;
        if (!rail.flipped) {
          final center = origin +
              Offset(radius * math.cos(rot + math.pi / 2),
                  radius * math.sin(rot + math.pi / 2));
          segs.add(_PathSeg.arc(center, radius, rot - math.pi / 2, 1, len));
        } else {
          final center = origin +
              Offset(radius * math.cos(rot - math.pi / 2),
                  radius * math.sin(rot - math.pi / 2));
          segs.add(_PathSeg.arc(center, radius, rot + math.pi / 2, -1, len));
        }
        total += len;
      } else {
        double mm;
        switch (rt) {
          case RailType.straightHalf:
            mm = 53.0;
          case RailType.straightDouble:
            mm = 212.0;
          default:
            mm = 106.0;
        }
        final len = mm * _kScale;
        segs.add(_PathSeg.line(
            origin, Offset(math.cos(rot), math.sin(rot)), len));
        total += len;
      }
    }
    return TrainPath._(segs, total);
  }

  (Offset, double) sample(double d) {
    if (segments.isEmpty || totalLength <= 0) return (Offset.zero, 0);
    var s = d % totalLength;
    if (s < 0) s += totalLength;
    for (final seg in segments) {
      if (s <= seg.length) return (seg.posAt(s), seg.headingAt(s));
      s -= seg.length;
    }
    final last = segments.last;
    return (last.posAt(last.length), last.headingAt(last.length));
  }
}

// ============================================================
// メインビュー
// ============================================================

/// 2D Canvasレイアウト描画ビュー
/// - Z軸に応じた濃淡表現 / 不足パーツの赤明滅
/// - 電車の走行アニメーション（生成コースを周回）
/// - 組み立て手順モード（assemblyStep 指定時）
class LayoutCanvasView extends StatefulWidget {
  final LayoutResponse layout;

  /// null = 通常表示。0以上 = 組み立てモード（その個数まで配置済み表示）
  final int? assemblyStep;
  final bool showTrain;

  const LayoutCanvasView({
    super.key,
    required this.layout,
    this.assemblyStep,
    this.showTrain = true,
  });

  @override
  State<LayoutCanvasView> createState() => _LayoutCanvasViewState();
}

class _LayoutCanvasViewState extends State<LayoutCanvasView>
    with TickerProviderStateMixin {
  late AnimationController _blinkController;
  late Animation<double> _blinkAnim;
  late AnimationController _trainController;
  TransformationController? _viewController;

  TrainPath? _trainPath;
  double _speed = 1.0;
  bool _running = true;

  static const double _basePxPerSec = 46.0; // 1倍速 ≈ レール1本/秒

  bool get _trainEnabled =>
      widget.showTrain &&
      widget.assemblyStep == null &&
      (_trainPath?.totalLength ?? 0) > 0;

  @override
  void initState() {
    super.initState();
    _blinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _blinkAnim = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _blinkController, curve: Curves.easeInOut),
    );

    _trainController = AnimationController(vsync: this);
    _rebuildPath();
  }

  void _rebuildPath() {
    _trainPath = TrainPath.fromRails(widget.layout.placedRails);
    _applyTrainSpeed();
  }

  void _applyTrainSpeed() {
    final total = _trainPath?.totalLength ?? 0;
    if (total <= 0) return;
    final seconds = total / (_basePxPerSec * _speed);
    _trainController.duration =
        Duration(milliseconds: (seconds * 1000).round());
    if (_running && widget.assemblyStep == null && widget.showTrain) {
      _trainController.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant LayoutCanvasView old) {
    super.didUpdateWidget(old);
    if (old.layout != widget.layout) {
      _rebuildPath();
    }
  }

  void _togglePlay() {
    setState(() {
      _running = !_running;
      if (_running) {
        _trainController.repeat();
      } else {
        _trainController.stop();
      }
    });
  }

  void _cycleSpeed() {
    setState(() {
      _speed = _speed >= 3.0 ? 1.0 : _speed + 1.0;
      _applyTrainSpeed();
    });
  }

  @override
  void dispose() {
    _blinkController.dispose();
    _trainController.dispose();
    _viewController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewController ??= TransformationController(
          Matrix4.translationValues(
            (constraints.maxWidth - _kCanvasPx) / 2,
            (constraints.maxHeight - _kCanvasPx) / 2,
            0,
          ),
        );
        return Stack(
          children: [
            AnimatedBuilder(
              animation: Listenable.merge([_blinkAnim, _trainController]),
              builder: (context, _) {
                return InteractiveViewer(
                  constrained: false,
                  boundaryMargin: const EdgeInsets.all(400),
                  transformationController: _viewController,
                  minScale: 0.3,
                  maxScale: 5.0,
                  child: CustomPaint(
                    size: const Size(_kCanvasPx, _kCanvasPx),
                    painter: _LayoutPainter(
                      placedRails: widget.layout.placedRails,
                      missingParts: widget.layout.missingParts,
                      suggestOpacity: _blinkAnim.value,
                      trainPath: _trainEnabled ? _trainPath : null,
                      trainDistance: _trainEnabled
                          ? _trainController.value *
                              (_trainPath?.totalLength ?? 0)
                          : null,
                      assemblyStep: widget.assemblyStep,
                    ),
                  ),
                );
              },
            ),
            // 走行コントロール
            if (_trainEnabled)
              Positioned(
                right: 12,
                bottom: 12,
                child: Row(
                  children: [
                    Material(
                      color: Colors.white,
                      elevation: 3,
                      borderRadius: BorderRadius.circular(20),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: _cycleSpeed,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 9),
                          child: Text(
                            'はやさ ×${_speed.toInt()}',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: Color(0xFF0072BC),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FloatingActionButton.small(
                      heroTag: 'train_play',
                      backgroundColor: const Color(0xFF0072BC),
                      foregroundColor: Colors.white,
                      onPressed: _togglePlay,
                      child: Icon(_running ? Icons.pause : Icons.play_arrow),
                    ),
                  ],
                ),
              ),
          ],
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
  final TrainPath? trainPath;
  final double? trainDistance;
  final int? assemblyStep;

  static const double _gridOriginMm = 900.0;
  static const double scale = _kScale;
  static const double _scale = scale;
  static const double _railWidth = 6.0;
  static const double _bandWidth = 11.0;

  _LayoutPainter({
    required this.placedRails,
    required this.missingParts,
    required this.suggestOpacity,
    this.trainPath,
    this.trainDistance,
    this.assemblyStep,
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
    if (assemblyStep != null) {
      _drawRailsAssembly(canvas, size, assemblyStep!);
    } else {
      _drawRails(canvas, size);
      _drawTrain(canvas);
    }
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

  // ---------- 通常表示 ----------

  void _drawRails(Canvas canvas, Size size) {
    // 2パス描画: 道床全部 → 継ぎ目全部
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

    for (final (joints, color) in connectors) {
      _drawConnector(canvas, joints.endPos, joints.endOutwardAngle, color);
    }
    if (firstJoints != null && firstColor != null) {
      _drawOpenHole(canvas, firstJoints.startPos,
          firstJoints.startOutwardAngle + math.pi, firstColor);
    }
  }

  // ---------- 組み立てモード ----------

  void _drawRailsAssembly(Canvas canvas, Size size, int step) {
    // チェーン順（= 組み立て順）で描画。
    //   i < step  : 配置済み（通常色）
    //   i == step : いまから置くピース（オレンジで明滅）
    //   i > step  : 未配置（ゴースト）
    final connectors = <(_JointPair, Color)>[];

    for (var i = 0; i < placedRails.length; i++) {
      final rail = placedRails[i];
      final baseColor = _colorForZ(rail.zLevel);
      Color color;
      if (i < step) {
        color = baseColor;
      } else if (i == step) {
        color = Color.lerp(
            _kHighlight.withOpacity(0.45), _kHighlight, suggestOpacity)!;
      } else {
        color = baseColor.withOpacity(0.10);
      }
      final joints = _drawRailBody(canvas, size, rail, color);
      if (joints != null && i < step) {
        connectors.add((joints, baseColor));
      }
    }

    for (final (joints, color) in connectors) {
      _drawConnector(canvas, joints.endPos, joints.endOutwardAngle, color);
    }
  }

  // ---------- 電車 ----------

  void _drawTrain(Canvas canvas) {
    final path = trainPath;
    final dist = trainDistance;
    if (path == null || dist == null || path.totalLength <= 0) return;

    // 先頭から: 赤い機関車 + 黄色・緑の客車
    const carSpacing = 26.0;
    final cars = [
      (const Color(0xFFE53935), 24.0, 13.0, true),
      (const Color(0xFFFFB300), 21.0, 12.0, false),
      (const Color(0xFF43A047), 21.0, 12.0, false),
    ];

    for (var i = cars.length - 1; i >= 0; i--) {
      final (color, w, h, isEngine) = cars[i];
      final (pos, heading) = path.sample(dist - i * carSpacing);

      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(heading);

      // 車体
      final body = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset.zero, width: w, height: h),
        const Radius.circular(3.5),
      );
      canvas.drawRRect(body, Paint()..color = color);
      canvas.drawRRect(
        body,
        Paint()
          ..color = Colors.black.withOpacity(0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
      // 屋根のハイライト
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: w - 7, height: h - 6),
          const Radius.circular(2),
        ),
        Paint()..color = Colors.white.withOpacity(0.35),
      );
      if (isEngine) {
        // 機関車の前面（進行方向側）に黒いバンパー
        canvas.drawRect(
          Rect.fromLTWH(w / 2 - 2.5, -h / 2, 2.5, h),
          Paint()..color = const Color(0xFF263238),
        );
      }
      canvas.restore();
    }
  }

  // ---------- 継ぎ目 ----------

  void _drawConnector(Canvas canvas, Offset pos, double travelAngle, Color color) {
    final t = Offset(math.cos(travelAngle), math.sin(travelAngle));
    final perp = Offset(-t.dy, t.dx);
    final seam = Paint()
      ..color = grooveColorOf(color)
      ..strokeWidth = 1.4;
    canvas.drawLine(
        pos + perp * (_bandWidth / 2), pos - perp * (_bandWidth / 2), seam);
    final pegCenter = pos + t * 3.6;
    canvas.drawCircle(pegCenter, 2.6, Paint()..color = grooveColorOf(color));
    canvas.drawCircle(
        pegCenter, 1.4, Paint()..color = Colors.white.withOpacity(0.9));
  }

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

  // ---------- ピース本体 ----------

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

    if (rt == RailType.bridgePierStandard || rt == RailType.bridgePierBlock) {
      final pierRect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: origin, width: 15, height: 15),
        const Radius.circular(3),
      );
      canvas.drawRRect(
          pierRect, Paint()..color = const Color(0xFF8D9AA5).withOpacity(color.opacity));
      canvas.drawRRect(
        pierRect,
        Paint()
          ..color = Colors.black38.withOpacity(0.38 * color.opacity)
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

    paintBandLine(canvas, origin, end, _bandWidth, paint.color);

    return _JointPair(
      startPos: origin,
      startOutwardAngle: rot + math.pi,
      endPos: end,
      endOutwardAngle: rot,
    );
  }

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
      center = origin +
          Offset(radius * math.cos(rot + math.pi / 2),
              radius * math.sin(rot + math.pi / 2));
      drawStart = rot - math.pi / 2;
      drawSpan = angleSpan;
      startOutward = drawStart + math.pi / 2 + math.pi;
      endOutward = drawStart + drawSpan + math.pi / 2;
    } else {
      center = origin +
          Offset(radius * math.cos(rot - math.pi / 2),
              radius * math.sin(rot - math.pi / 2));
      drawStart = rot + math.pi / 2;
      drawSpan = -angleSpan;
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
      old.placedRails != placedRails ||
      old.trainDistance != trainDistance ||
      old.assemblyStep != assemblyStep;
}
