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

/// 凹型（メス）ジョイント: U 字スロット形状（外向きに開く）
/// [pos]: ジョイントの中心位置（世界座標）
/// [outwardAngle]: 凹が開く方向（radians, 0 = +X）
/// [size]: ジョイントマーカーの基本サイズ
void paintFemaleJoint(Canvas canvas, Offset pos, Color color, {
  double outwardAngle = math.pi,
  double size = 4.5,
}) {
  final c = math.cos(outwardAngle);
  final s = math.sin(outwardAngle);
  final perpX = -s;
  final perpY = c;

  // 凹のサイズ: 開口幅 w、奥行き d
  final w = size * 1.4;
  final d = size * 1.1;

  // 中心 pos の周りに U 字を描く
  // 内側（閉じ側）: pos から -outward 方向に d/2
  // 外側（開口側）: pos から +outward 方向に d/2
  final innerCx = pos.dx - c * d / 2;
  final innerCy = pos.dy - s * d / 2;
  final outerCx = pos.dx + c * d / 2;
  final outerCy = pos.dy + s * d / 2;

  // 一方の外側→内側→反対側内側→反対側外側 と辿るパス（U字、3辺）
  final path = Path()
    ..moveTo(outerCx + perpX * w / 2, outerCy + perpY * w / 2)
    ..lineTo(innerCx + perpX * w / 2, innerCy + perpY * w / 2)
    ..lineTo(innerCx - perpX * w / 2, innerCy - perpY * w / 2)
    ..lineTo(outerCx - perpX * w / 2, outerCy - perpY * w / 2);

  final stroke = Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.8
    ..strokeJoin = StrokeJoin.miter
    ..strokeCap = StrokeCap.square;
  canvas.drawPath(path, stroke);
}

/// 凸型（オス）ジョイント: 矩形タブ突起（外向きに伸びる）
/// [pos]: ジョイントの中心位置
/// [outwardAngle]: 凸が突き出る方向
void paintMaleJoint(Canvas canvas, Offset pos, Color color, {
  double outwardAngle = 0,
  double size = 4.5,
}) {
  final c = math.cos(outwardAngle);
  final s = math.sin(outwardAngle);
  final perpX = -s;
  final perpY = c;

  // 凸のサイズ: タブ幅 w、奥行き d（凹の内幅より少し小さく → 視覚的に隙間）
  final w = size * 1.0;
  final d = size * 1.1;

  // 矩形タブを pos を中心に描く
  final backCx = pos.dx - c * d / 2;
  final backCy = pos.dy - s * d / 2;
  final frontCx = pos.dx + c * d / 2;
  final frontCy = pos.dy + s * d / 2;

  final path = Path()
    ..moveTo(backCx + perpX * w / 2, backCy + perpY * w / 2)
    ..lineTo(frontCx + perpX * w / 2, frontCy + perpY * w / 2)
    ..lineTo(frontCx - perpX * w / 2, frontCy - perpY * w / 2)
    ..lineTo(backCx - perpX * w / 2, backCy - perpY * w / 2)
    ..close();

  final fill = Paint()
    ..color = color
    ..style = PaintingStyle.fill;
  canvas.drawPath(path, fill);
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
    const jointInset = 4.0;
    // 2本のレール（ジョイント分内側に短く）
    c.drawLine(Offset(pad + jointInset, mid - gap / 2), Offset(w - pad - jointInset, mid - gap / 2), stroke);
    c.drawLine(Offset(pad + jointInset, mid + gap / 2), Offset(w - pad - jointInset, mid + gap / 2), stroke);
    // 枕木
    _drawTies(c, Offset(pad + jointInset, mid), Offset(w - pad - jointInset, mid), stroke, gap + 2);
    // 凹（左）: 開口は -X 方向（π）
    paintFemaleJoint(c, Offset(pad + jointInset, mid), color, outwardAngle: math.pi, size: 3.5);
    // 凸（右）: 突起は +X 方向（0）
    paintMaleJoint(c, Offset(w - pad - jointInset, mid), color, outwardAngle: 0, size: 3.5);
    if (doubled) {
      c.drawLine(Offset(w / 2, mid - gap), Offset(w / 2, mid + gap), stroke);
    }
  }

  void _drawCurve(Canvas c, Size s, Paint stroke, {required double radius}) {
    final w = s.width, h = s.height;
    final r = w * radius;
    final cx = -r * 0.1;
    final cy = h * 0.85;
    // 円弧内側へ短くする（隙間用）
    final arcInset = 0.10; // ラジアン
    final startA = -math.pi / 2;
    final span = math.pi / 3;
    final drawStart = startA + arcInset;
    final drawSpan = span - 2 * arcInset;
    c.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: r), drawStart, drawSpan, false, stroke);
    c.drawArc(Rect.fromCircle(center: Offset(cx, cy), radius: r - 5), drawStart, drawSpan, false, stroke);
    // ジョイント位置 = 内側にinsetした弧の端点
    final pStart = Offset(cx + (r - 2.5) * math.cos(drawStart), cy + (r - 2.5) * math.sin(drawStart));
    final pEnd = Offset(cx + (r - 2.5) * math.cos(drawStart + drawSpan),
        cy + (r - 2.5) * math.sin(drawStart + drawSpan));
    // 接線方向に対し凹は外向き、凸は前向き
    // 弧の中心から始点への半径方向 → +90度回した方向が接線（前進方向）
    // 始点側の凹の outward = 接線の反対（後方）
    final tangentStart = drawStart + math.pi / 2;
    final tangentEnd = drawStart + drawSpan + math.pi / 2;
    paintFemaleJoint(c, pStart, color, outwardAngle: tangentStart + math.pi, size: 3.5);
    paintMaleJoint(c, pEnd, color, outwardAngle: tangentEnd, size: 3.5);
  }

  void _drawCrossing(Canvas c, Size s, Paint stroke) {
    final w = s.width, h = s.height;
    final pad = 6.0;
    final mid = w / 2;
    final gap = 4.0;
    const inset = 3.5;
    c.drawLine(Offset(pad + inset, mid - gap / 2), Offset(w - pad - inset, mid - gap / 2), stroke);
    c.drawLine(Offset(pad + inset, mid + gap / 2), Offset(w - pad - inset, mid + gap / 2), stroke);
    c.drawLine(Offset(mid - gap / 2, pad + inset), Offset(mid - gap / 2, h - pad - inset), stroke);
    c.drawLine(Offset(mid + gap / 2, pad + inset), Offset(mid + gap / 2, h - pad - inset), stroke);
    paintFemaleJoint(c, Offset(pad + inset, mid), color, outwardAngle: math.pi, size: 3.0);
    paintMaleJoint(c, Offset(w - pad - inset, mid), color, outwardAngle: 0, size: 3.0);
    paintFemaleJoint(c, Offset(mid, pad + inset), color, outwardAngle: -math.pi / 2, size: 3.0);
    paintMaleJoint(c, Offset(mid, h - pad - inset), color, outwardAngle: math.pi / 2, size: 3.0);
  }

  void _drawSwitch(Canvas c, Size s, Paint stroke, {required bool branchUp}) {
    final w = s.width, h = s.height;
    final pad = 5.0;
    final mid = h / 2;
    final gap = 5.0;
    const inset = 4.0;
    c.drawLine(Offset(pad + inset, mid - gap / 2), Offset(w - pad - inset, mid - gap / 2), stroke);
    c.drawLine(Offset(pad + inset, mid + gap / 2), Offset(w - pad - inset, mid + gap / 2), stroke);
    final branchY = branchUp ? mid - h * 0.32 : mid + h * 0.32;
    c.drawLine(
      Offset(w * 0.35, branchUp ? mid - gap / 2 : mid + gap / 2),
      Offset(w - pad - inset, branchY),
      stroke,
    );
    paintFemaleJoint(c, Offset(pad + inset, mid), color, outwardAngle: math.pi, size: 3.5);
    paintMaleJoint(c, Offset(w - pad - inset, mid), color, outwardAngle: 0, size: 3.5);
    final branchAngle = math.atan2(branchY - (branchUp ? mid - gap / 2 : mid + gap / 2),
        (w - pad - inset) - w * 0.35);
    paintMaleJoint(c, Offset(w - pad - inset, branchY), color, outwardAngle: branchAngle, size: 3.5);
  }

  void _drawIncline(Canvas c, Size s, Paint stroke, {required bool ascending, required bool hasStart}) {
    final w = s.width, h = s.height;
    final pad = 5.0;
    final y1 = ascending ? h - pad : pad;
    final y2 = ascending ? pad : h - pad;
    final gap = 4.0;
    const inset = 4.0;
    // 角度方向に inset
    final angle = math.atan2(y2 - y1, (w - 2 * pad));
    final dx = math.cos(angle) * inset;
    final dy = math.sin(angle) * inset;
    c.drawLine(Offset(pad + dx, y1 - gap / 2 + dy), Offset(w - pad - dx, y2 - gap / 2 - dy), stroke);
    c.drawLine(Offset(pad + dx, y1 + gap / 2 + dy), Offset(w - pad - dx, y2 + gap / 2 - dy), stroke);
    paintFemaleJoint(c, Offset(pad + dx, y1 + dy), color, outwardAngle: angle + math.pi, size: 3.5);
    paintMaleJoint(c, Offset(w - pad - dx, y2 - dy), color, outwardAngle: angle, size: 3.5);
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
    paintFemaleJoint(c, Offset(pad, mid), color, outwardAngle: math.pi, size: 3.5);
    paintMaleJoint(c, Offset(w - pad, mid), color, outwardAngle: 0, size: 3.5);
  }

  @override
  bool shouldRepaint(_RailIconPainter old) =>
      old.railType != railType || old.color != color;
}
