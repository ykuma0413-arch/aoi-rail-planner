import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../models/rail_type.dart';

/// 実物のおもちゃレールに近い青色
const Color kRailBlue = Color(0xFF0072BC);

/// 橋脚の色（標準=黄色 / ブロック=灰色）
const Color kPierStandard = Color(0xFFFFC107); // 黄色
const Color kPierBlock = Color(0xFF9E9E9E);    // 灰色

/// 在庫リスト用のレールアイコン。
/// 実物風: 青い道床（太いバンド）+ 2本の溝 + 凸ペグ / 凹ホールのジョイント。
class MiniRailIcon extends StatelessWidget {
  final RailType railType;
  final double size;
  final Color color;

  const MiniRailIcon({
    super.key,
    required this.railType,
    this.size = 44,
    this.color = kRailBlue,
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

// ============ 共通ジョイント描画（レイアウトCanvasと共用） ============

/// 凸（オス）: 道床から突き出るステム + 円形ペグ。実物の連結部そのもの。
/// [pos] 道床の端, [outwardAngle] 突き出る方向, [size] 基本サイズ
void paintMaleJoint(Canvas canvas, Offset pos, Color color,
    {double outwardAngle = 0, double size = 4.5}) {
  final u = Offset(math.cos(outwardAngle), math.sin(outwardAngle));
  // ステム（首）
  final stem = Paint()
    ..color = color
    ..strokeWidth = size * 0.55
    ..strokeCap = StrokeCap.butt;
  canvas.drawLine(pos, pos + u * size * 1.0, stem);
  // ペグ（円頭）
  canvas.drawCircle(pos + u * size * 1.35, size * 0.62, Paint()..color = color);
}

/// 凹（メス）: 道床の端に開いた円形ホール + エッジへ抜けるスロット。
/// 白で抜いて「穴」に見せる。
void paintFemaleJoint(Canvas canvas, Offset pos, Color color,
    {double outwardAngle = math.pi, double size = 4.5}) {
  final u = Offset(math.cos(outwardAngle), math.sin(outwardAngle));
  final holeCenter = pos - u * size * 0.95; // 道床の内側
  // スロット（エッジへの切り欠き）
  final slot = Paint()
    ..color = Colors.white
    ..strokeWidth = size * 0.6
    ..strokeCap = StrokeCap.butt;
  canvas.drawLine(pos + u * size * 0.25, holeCenter, slot);
  // ホール本体
  canvas.drawCircle(holeCenter, size * 0.62, Paint()..color = Colors.white);
  canvas.drawCircle(
    holeCenter,
    size * 0.62,
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1,
  );
}

// ============ 道床（バンド）描画ヘルパー ============

Color grooveColorOf(Color base) => Color.lerp(base, Colors.black, 0.28)!;

/// 道床の縁取り（白枠）の太さ（片側 px）。実物のレールの白フチを表現。
const double kBandBorder = 2.6;

// ---- 白枠（下地）: 道床より太い白ストロークで縁取りを作る ----
void paintBandBorderLine(Canvas c, Offset a, Offset b, double w) {
  c.drawLine(
      a,
      b,
      Paint()
        ..color = Colors.white
        ..strokeWidth = w + kBandBorder * 2
        ..strokeCap = StrokeCap.round);
}

void paintBandBorderArc(
    Canvas c, Offset center, double r, double start, double sweep, double w) {
  c.drawArc(
      Rect.fromCircle(center: center, radius: r),
      start,
      sweep,
      false,
      Paint()
        ..color = Colors.white
        ..strokeWidth = w + kBandBorder * 2
        ..strokeCap = StrokeCap.round
        ..style = PaintingStyle.stroke);
}

// ---- 青い道床本体 + 2本の溝（白枠の内側に重ねる） ----
void paintBandFillLine(Canvas c, Offset a, Offset b, double w, Color color) {
  c.drawLine(
      a,
      b,
      Paint()
        ..color = color
        ..strokeWidth = w
        ..strokeCap = StrokeCap.butt);
  final d = b - a;
  final len = d.distance;
  if (len < 0.01) return;
  final perp = Offset(-d.dy / len, d.dx / len);
  final groove = Paint()
    ..color = grooveColorOf(color)
    ..strokeWidth = w * 0.12
    ..strokeCap = StrokeCap.butt;
  c.drawLine(a + perp * w * 0.24, b + perp * w * 0.24, groove);
  c.drawLine(a - perp * w * 0.24, b - perp * w * 0.24, groove);
}

void paintBandFillArc(Canvas c, Offset center, double r, double start,
    double sweep, double w, Color color) {
  c.drawArc(
      Rect.fromCircle(center: center, radius: r),
      start,
      sweep,
      false,
      Paint()
        ..color = color
        ..strokeWidth = w
        ..strokeCap = StrokeCap.butt
        ..style = PaintingStyle.stroke);
  final groove = Paint()
    ..color = grooveColorOf(color)
    ..strokeWidth = w * 0.12
    ..strokeCap = StrokeCap.butt
    ..style = PaintingStyle.stroke;
  c.drawArc(Rect.fromCircle(center: center, radius: r + w * 0.24), start, sweep,
      false, groove);
  c.drawArc(Rect.fromCircle(center: center, radius: r - w * 0.24), start, sweep,
      false, groove);
}

/// 継ぎ目の白いシーム線（青道床の内側を横切る = 実物の真上視点の連結部）。
/// 白枠は連続させ、シームは道床内のティックにすることで「隙間」ではなく
/// 「連続トラックの継ぎ目」に見せる。
void paintJointSeam(Canvas c, Offset pos, double travelAngle, double w) {
  final perp = Offset(-math.sin(travelAngle), math.cos(travelAngle));
  final half = w / 2; // 道床幅のみ（白枠は割らない）
  c.drawLine(
      pos + perp * half,
      pos - perp * half,
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.butt);
}

/// 直線レール1本（白枠+道床+溝）を単独で描く（在庫アイコン用）。
void paintBandLine(Canvas c, Offset a, Offset b, double w, Color color) {
  paintBandBorderLine(c, a, b, w);
  paintBandFillLine(c, a, b, w, color);
}

/// 曲線レール1本（白枠+道床+溝）を単独で描く（在庫アイコン用）。
void paintBandArc(Canvas c, Offset center, double r, double start, double sweep,
    double w, Color color) {
  paintBandBorderArc(c, center, r, start, sweep, w);
  paintBandFillArc(c, center, r, start, sweep, w, color);
}

// 旧名エイリアス（アイコンペインタ内部用）
void _bandLine(Canvas c, Offset a, Offset b, double w, Color color) =>
    paintBandLine(c, a, b, w, color);
void _bandArc(Canvas c, Offset center, double r, double start, double sweep,
        double w, Color color) =>
    paintBandArc(c, center, r, start, sweep, w, color);

// ============ アイコンペインタ ============

class _RailIconPainter extends CustomPainter {
  final RailType railType;
  final Color color;

  _RailIconPainter({required this.railType, required this.color});

  static const double _bw = 9.0; // 道床幅
  static const double _js = 3.2; // ジョイントサイズ

  @override
  void paint(Canvas canvas, Size size) {
    switch (railType) {
      case RailType.straight:
        _straight(canvas, size, lengthRatio: 0.85);
      case RailType.straightHalf:
        _straight(canvas, size, lengthRatio: 0.52);
      case RailType.straightQuarter:
        _straight(canvas, size, lengthRatio: 0.32);
      case RailType.stopRail:
        _straight(canvas, size, lengthRatio: 0.85, stop: true);
      case RailType.straightDouble:
        _straight(canvas, size, lengthRatio: 0.96, seam: true);
      case RailType.curveR:
        _curve(canvas, size, radiusRatio: 0.58);
      case RailType.curveRLarge:
        _curve(canvas, size, radiusRatio: 0.80);
      case RailType.crossing:
        _crossing(canvas, size);
      case RailType.crossPoint:
        _crossing(canvas, size);
      case RailType.switchLeft:
        _switch(canvas, size, branchUp: true);
      case RailType.switchRight:
        _switch(canvas, size, branchUp: false);
      case RailType.autoTurnout:
        _switch(canvas, size, branchUp: true);
      case RailType.switchY:
        _switchY(canvas, size);
      case RailType.inclineStart:
        _incline(canvas, size, ascending: true, marker: true);
      case RailType.inclineMiddle:
        _incline(canvas, size, ascending: true, marker: false);
      case RailType.inclineEnd:
        _incline(canvas, size, ascending: false, marker: false);
      case RailType.bridgePierStandard:
        _pier(canvas, size, block: false);
      case RailType.bridgePierBlock:
        _pier(canvas, size, block: true);
      case RailType.flexible:
        _flexible(canvas, size);
    }
  }

  void _straight(Canvas c, Size s,
      {required double lengthRatio, bool seam = false, bool stop = false}) {
    final w = s.width, h = s.height;
    final pad = (1 - lengthRatio) * w / 2 + 4;
    final mid = h / 2;
    final a = Offset(pad + 3, mid);
    final b = Offset(w - pad - 3, mid);
    _bandLine(c, a, b, _bw, color);
    if (seam) {
      c.drawLine(
        Offset(w / 2, mid - _bw / 2),
        Offset(w / 2, mid + _bw / 2),
        Paint()..color = grooveColorOf(color)..strokeWidth = 1.2,
      );
    }
    if (stop) {
      // ストップレール: 赤い停止標識
      final sx = (a.dx + b.dx) / 2;
      c.drawCircle(Offset(sx, mid), _bw * 0.42,
          Paint()..color = const Color(0xFFE53935));
    }
    paintFemaleJoint(c, a, color, outwardAngle: math.pi, size: _js);
    paintMaleJoint(c, b, color, outwardAngle: 0, size: _js);
  }

  /// Y字ポイント: 直線が両方向に分岐
  void _switchY(Canvas c, Size s) {
    final w = s.width, h = s.height;
    final mid = h / 2;
    final a = Offset(7, mid);
    final fork = Offset(w * 0.40, mid);
    final up = Offset(w - 8, mid - h * 0.30);
    final down = Offset(w - 8, mid + h * 0.30);
    _bandLine(c, fork, up, _bw * 0.8, color);
    _bandLine(c, fork, down, _bw * 0.8, color);
    _bandLine(c, a, fork, _bw * 0.9, color);
    paintFemaleJoint(c, a, color, outwardAngle: math.pi, size: _js);
    final upA = math.atan2(up.dy - fork.dy, up.dx - fork.dx);
    final dnA = math.atan2(down.dy - fork.dy, down.dx - fork.dx);
    paintMaleJoint(c, up, color, outwardAngle: upA, size: 2.6);
    paintMaleJoint(c, down, color, outwardAngle: dnA, size: 2.6);
  }

  void _curve(Canvas c, Size s, {required double radiusRatio}) {
    final w = s.width, h = s.height;
    final r = w * radiusRatio;
    final center = Offset(w * 0.08, h * 0.92);
    const startDeg = -80.0;
    const sweepDeg = 62.0;
    final start = startDeg * math.pi / 180;
    final sweep = sweepDeg * math.pi / 180;
    _bandArc(c, center, r, start, sweep, _bw, color);

    final pStart = center + Offset(r * math.cos(start), r * math.sin(start));
    final endA = start + sweep;
    final pEnd = center + Offset(r * math.cos(endA), r * math.sin(endA));
    paintFemaleJoint(c, pStart, color,
        outwardAngle: start + math.pi / 2 + math.pi, size: _js);
    paintMaleJoint(c, pEnd, color, outwardAngle: endA + math.pi / 2, size: _js);
  }

  void _crossing(Canvas c, Size s) {
    final w = s.width, h = s.height;
    final mid = Offset(w / 2, h / 2);
    final a1 = Offset(7, h / 2);
    final b1 = Offset(w - 7, h / 2);
    final a2 = Offset(w / 2, 7);
    final b2 = Offset(w / 2, h - 7);
    _bandLine(c, a2, b2, _bw * 0.85, color);
    _bandLine(c, a1, b1, _bw * 0.85, color);
    paintFemaleJoint(c, a1, color, outwardAngle: math.pi, size: 2.6);
    paintMaleJoint(c, b1, color, outwardAngle: 0, size: 2.6);
    paintFemaleJoint(c, a2, color, outwardAngle: -math.pi / 2, size: 2.6);
    paintMaleJoint(c, b2, color, outwardAngle: math.pi / 2, size: 2.6);
  }

  void _switch(Canvas c, Size s, {required bool branchUp}) {
    final w = s.width, h = s.height;
    final mid = h / 2;
    final a = Offset(7, mid);
    final b = Offset(w - 7, mid);
    final branchEnd = Offset(w - 8, branchUp ? mid - h * 0.30 : mid + h * 0.30);
    final branchStart = Offset(w * 0.32, mid);
    _bandLine(c, branchStart, branchEnd, _bw * 0.8, color);
    _bandLine(c, a, b, _bw * 0.9, color);
    paintFemaleJoint(c, a, color, outwardAngle: math.pi, size: _js);
    paintMaleJoint(c, b, color, outwardAngle: 0, size: _js);
    final bAngle = math.atan2(
        branchEnd.dy - branchStart.dy, branchEnd.dx - branchStart.dx);
    paintMaleJoint(c, branchEnd, color, outwardAngle: bAngle, size: 2.6);
  }

  void _incline(Canvas c, Size s, {required bool ascending, required bool marker}) {
    final w = s.width, h = s.height;
    final y1 = ascending ? h * 0.78 : h * 0.22;
    final y2 = ascending ? h * 0.22 : h * 0.78;
    final a = Offset(7, y1);
    final b = Offset(w - 7, y2);
    _bandLine(c, a, b, _bw, color);
    final angle = math.atan2(b.dy - a.dy, b.dx - a.dx);
    paintFemaleJoint(c, a, color, outwardAngle: angle + math.pi, size: _js);
    paintMaleJoint(c, b, color, outwardAngle: angle, size: _js);
    if (marker) {
      // 上り開始マーク（小さい三角）
      final tri = Path()
        ..moveTo(6, h - 4)
        ..lineTo(13, h - 4)
        ..lineTo(9.5, h - 10)
        ..close();
      c.drawPath(tri, Paint()..color = color.withOpacity(0.7));
    }
  }

  void _pier(Canvas c, Size s, {required bool block}) {
    final w = s.width, h = s.height;
    final cx = w / 2;
    // 標準橋脚 = 黄色 / ブロック橋脚 = 灰色
    final pierColor = block ? kPierBlock : kPierStandard;
    final fill = Paint()..color = pierColor;
    final stroke = Paint()
      ..color = grooveColorOf(pierColor)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3;
    if (block) {
      // ブロック橋脚: 積み上げ可能な箱型
      final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - 10, h * 0.28, 20, h * 0.55), const Radius.circular(2));
      c.drawRRect(rect, fill);
      c.drawRRect(rect, stroke);
      // 上面の連結ペグ
      c.drawCircle(Offset(cx, h * 0.28), 2.6, fill);
      // 横ライン（ブロックの段）
      c.drawLine(Offset(cx - 10, h * 0.55), Offset(cx + 10, h * 0.55), stroke);
    } else {
      // 標準橋脚: T 字型
      final top = Rect.fromLTWH(cx - 13, h * 0.26, 26, 6);
      c.drawRect(top, fill);
      final post = Rect.fromLTWH(cx - 4, h * 0.26 + 6, 8, h * 0.48);
      c.drawRect(post, fill);
      final base = Rect.fromLTWH(cx - 9, h * 0.78, 18, 4);
      c.drawRect(base, fill);
    }
  }

  void _flexible(Canvas c, Size s) {
    final w = s.width, h = s.height;
    final mid = h / 2;
    final path = Path()..moveTo(7, mid);
    const steps = 24;
    for (int i = 1; i <= steps; i++) {
      final t = i / steps;
      final x = 7 + (w - 14) * t;
      final dy = math.sin(t * math.pi * 2) * 4.5;
      path.lineTo(x, mid + dy);
    }
    final base = Paint()
      ..color = color
      ..strokeWidth = _bw * 0.85
      ..strokeCap = StrokeCap.butt
      ..style = PaintingStyle.stroke;
    c.drawPath(path, base);
    paintFemaleJoint(c, Offset(7, mid), color, outwardAngle: math.pi, size: _js);
    paintMaleJoint(c, Offset(w - 7, mid), color, outwardAngle: 0, size: _js);
  }

  @override
  bool shouldRepaint(_RailIconPainter old) =>
      old.railType != railType || old.color != color;
}
