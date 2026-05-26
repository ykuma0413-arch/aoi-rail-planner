import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../models/rail_type.dart';

/// 在庫リスト用のレールデフォルメアイコン (40x40 程度)。
/// レールの形状とジョイント極性 (オス=▶ / メス=⌒) を一目で識別できる。
class MiniRailIcon extends StatelessWidget {
  final RailType railType;
  final double size;
  final Color color;

  const MiniRailIcon({
    super.key,
    required this.railType,
    this.size = 44,
    this.color = const Color(0xFF455A64),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RailIconPainter(railType: railType, color: color),
      ),
    );
  }
}

/// レイアウト Canvas でも使う共通の描画関数（外部公開）
void paintFemaleJoint(Canvas canvas, Offset pos, Color color, {double r = 3.5}) {
  final p = Paint()
    ..color = color
    ..strokeWidth = 1.5
    ..style = PaintingStyle.stroke;
  // 左向きの U 型くぼみ
  canvas.drawArc(
    Rect.fromCenter(center: Offset(pos.dx + r * 0.4, pos.dy), width: r * 1.6, height: r * 2),
    math.pi / 2,
    math.pi,
    false,
    p,
  );
}

void paintMaleJoint(Canvas canvas, Offset pos, Color color, {double r = 3.5}) {
  final p = Paint()..color = color..style = PaintingStyle.fill;
  final path = Path()
    ..moveTo(pos.dx - r * 0.3, pos.dy - r)
    ..lineTo(pos.dx + r, pos.dy)
    ..lineTo(pos.dx - r * 0.3, pos.dy + r)
    ..close();
  canvas.drawPath(path, p);
}

class _RailIconPainter extends CustomPainter {
  final RailType railType;
  final Color color;

  _RailIconPainter({required this.railType, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final fill = Paint()..color = color..style = PaintingStyle.fill;

    switch (railType) {
      case RailType.straight:
        _drawStraight(canvas, size, stroke, length: 0.85);
      case RailType.straightHalf:
        _drawStraight(canvas, size, stroke, length: 0.5);
      case RailType.straightDouble:
        _drawStraight(canvas, size, stroke, length: 0.95, doubled: true);
      case RailType.curveR:
        _drawCurve(canvas, size, stroke, radius: 0.55);
      case RailType.curveRLarge:
        _drawCurve(canvas, size, stroke, radius: 0.75);
      case RailType.crossing:
        _drawCrossing(canvas, size, stroke);
      case RailType.switchLeft:
        _drawSwitch(canvas, size, stroke, branchUp: true);
      case RailType.switchRight:
        _drawSwitch(canvas, size, stroke, branchUp: false);
      case RailType.inclineStart:
        _drawIncline(canvas, size, stroke, ascending: true, hasStart: true);
      case RailType.inclineMiddle:
        _drawIncline(canvas, size, stroke, ascending: true, hasStart: false);
      case RailType.inclineEnd:
        _drawIncline(canvas, size, stroke, ascending: false, hasStart: false);
      case RailType.bridgePierStandard:
        _drawPier(canvas, size, stroke, fill, block: false);
      case RailType.bridgePierBlock:
        _drawPier(canvas, size, stroke, fill, block: true);
      case RailType.flexible:
        _drawFlexible(canvas, size, stroke);
    }
  }

  void _drawTies(Canvas c, Offset start, Offset end, Paint p, double gap) {
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    final dist = math.sqrt(dx * dx + dy * dy);
    final tieCount = (dist / 10).round().clamp(3, 8);
    final perpX = -dy / dist * gap / 2;
    final perpY = dx / dist * gap / 2;
    for (int i = 1; i < tieCount; i++) {
      final t = i / tieCount;
      final cx = start.dx + dx * t;
      final cy = start.dy + dy * t;
      c.drawLine(
        Offset(cx - perpX, cy - perpY),
        Offset(cx + perpX, cy + perpY),
        p,
      );
    }
  }

  void _drawStraight(Canvas c, Size s, Paint stroke, {required double length, bool doubled = false}) {
    final w = s.width, h = s.height;
    final pad = (1 - length) * w / 2 + 4;
    final mid = h / 2;
    final gap = 5.0;
    // 2本のレール
    c.drawLine(Offset(pad, mid - gap / 2), Offset(w - pad, mid - gap / 2), stroke);
    c.drawLine(Offset(pad, mid + gap / 2), Offset(w - pad, mid + gap / 2), stroke);
    // 枕木
    _drawTies(c, Offset(pad, mid), Offset(w - pad, mid), stroke, gap + 2);
    // ジョイント
    paintFemaleJoint(c, Offset(pad, mid), color);
    paintMaleJoint(c, Offset(w - pad, mid), color);
    if (doubled) {
      // 真ん中に区切り表示
      c.drawLine(Offset(w / 2, mid - gap), Offset(w / 2, mid + gap), stroke);
    }
  }

  void _drawCurve(Canvas c, Size s, Paint stroke, {required double radius}) {
    final w = s.width, h = s.height;
    final r = w * radius;
    final cx = -r * 0.1;
    final cy = h * 0.85;
    // 円弧（外側）
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);
    c.drawArc(rect, -math.pi / 2, math.pi / 3, false, stroke);
    // 内側
    c.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: r - 5),
      -math.pi / 2,
      math.pi / 3,
      false,
      stroke,
    );
    // ジョイント位置を弧の両端で計算
    final startA = -math.pi / 2;
    final endA = startA + math.pi / 3;
    final pStart = Offset(cx + (r - 2.5) * math.cos(startA), cy + (r - 2.5) * math.sin(startA));
    final pEnd = Offset(cx + (r - 2.5) * math.cos(endA), cy + (r - 2.5) * math.sin(endA));
    paintFemaleJoint(c, pStart, color);
    paintMaleJoint(c, pEnd, color);
  }

  void _drawCrossing(Canvas c, Size s, Paint stroke) {
    final w = s.width, h = s.height;
    final pad = 6.0;
    final mid = w / 2;
    final gap = 4.0;
    // 横方向
    c.drawLine(Offset(pad, mid - gap / 2), Offset(w - pad, mid - gap / 2), stroke);
    c.drawLine(Offset(pad, mid + gap / 2), Offset(w - pad, mid + gap / 2), stroke);
    // 縦方向
    c.drawLine(Offset(mid - gap / 2, pad), Offset(mid - gap / 2, h - pad), stroke);
    c.drawLine(Offset(mid + gap / 2, pad), Offset(mid + gap / 2, h - pad), stroke);
    // 4 ジョイント
    paintFemaleJoint(c, Offset(pad, mid), color);
    paintMaleJoint(c, Offset(w - pad, mid), color);
    paintFemaleJoint(c, Offset(mid, pad), color);
    paintMaleJoint(c, Offset(mid, h - pad), color);
  }

  void _drawSwitch(Canvas c, Size s, Paint stroke, {required bool branchUp}) {
    final w = s.width, h = s.height;
    final pad = 5.0;
    final mid = h / 2;
    final gap = 5.0;
    // 直線部分
    c.drawLine(Offset(pad, mid - gap / 2), Offset(w - pad, mid - gap / 2), stroke);
    c.drawLine(Offset(pad, mid + gap / 2), Offset(w - pad, mid + gap / 2), stroke);
    // 分岐
    final branchY = branchUp ? mid - h * 0.32 : mid + h * 0.32;
    c.drawLine(
      Offset(w * 0.35, branchUp ? mid - gap / 2 : mid + gap / 2),
      Offset(w - pad, branchY),
      stroke,
    );
    // ジョイント
    paintFemaleJoint(c, Offset(pad, mid), color);
    paintMaleJoint(c, Offset(w - pad, mid), color);
    paintMaleJoint(c, Offset(w - pad, branchY), color);
  }

  void _drawIncline(Canvas c, Size s, Paint stroke, {required bool ascending, required bool hasStart}) {
    final w = s.width, h = s.height;
    final pad = 5.0;
    final y1 = ascending ? h - pad : pad;
    final y2 = ascending ? pad : h - pad;
    // 2本のレールを斜めに
    final gap = 4.0;
    c.drawLine(Offset(pad, y1 - gap / 2), Offset(w - pad, y2 - gap / 2), stroke);
    c.drawLine(Offset(pad, y1 + gap / 2), Offset(w - pad, y2 + gap / 2), stroke);
    // ジョイント
    paintFemaleJoint(c, Offset(pad, y1), color);
    paintMaleJoint(c, Offset(w - pad, y2), color);
    if (hasStart) {
      // 開始マーカー（小さい三角）
      final triPath = Path()
        ..moveTo(pad - 1, h - 2)
        ..lineTo(pad + 5, h - 2)
        ..lineTo(pad + 2, h - 6)
        ..close();
      c.drawPath(triPath, Paint()..color = color);
    }
  }

  void _drawPier(Canvas c, Size s, Paint stroke, Paint fill, {required bool block}) {
    final w = s.width, h = s.height;
    final cx = w / 2;
    final baseY = h - 6;
    final topY = h * 0.30;
    if (block) {
      // ブロック橋脚: 太い四角
      final rect = Rect.fromLTWH(cx - 9, topY, 18, baseY - topY);
      c.drawRect(rect, fill);
      c.drawRect(rect, stroke);
      // 上に小さなレール
      c.drawLine(Offset(cx - 12, topY - 3), Offset(cx + 12, topY - 3), stroke);
    } else {
      // 標準橋脚: T 字（柱 + 上に板）
      c.drawLine(Offset(cx, baseY), Offset(cx, topY + 4), stroke);
      // 上面の板
      c.drawLine(Offset(cx - 11, topY), Offset(cx + 11, topY), stroke..strokeWidth = 3);
      stroke.strokeWidth = 2;
      // 脚部
      c.drawLine(Offset(cx - 5, baseY), Offset(cx + 5, baseY), stroke);
    }
  }

  void _drawFlexible(Canvas c, Size s, Paint stroke) {
    final w = s.width, h = s.height;
    final pad = 5.0;
    final mid = h / 2;
    // 波線2本
    final path1 = Path()..moveTo(pad, mid - 3);
    final path2 = Path()..moveTo(pad, mid + 3);
    final steps = 20;
    for (int i = 1; i <= steps; i++) {
      final t = i / steps;
      final x = pad + (w - 2 * pad) * t;
      final dy = math.sin(t * math.pi * 2) * 3;
      path1.lineTo(x, mid - 3 + dy);
      path2.lineTo(x, mid + 3 + dy);
    }
    c.drawPath(path1, stroke);
    c.drawPath(path2, stroke);
    paintFemaleJoint(c, Offset(pad, mid), color);
    paintMaleJoint(c, Offset(w - pad, mid), color);
  }

  @override
  bool shouldRepaint(_RailIconPainter old) =>
      old.railType != railType || old.color != color;
}
