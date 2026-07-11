/// 走行経路と分岐進路選択（描画非依存の純粋モデル・mm空間）。
///
/// 本線の閉ループに加え、ポイントレール（switch_left / switch_right /
/// auto_turnout / switch_y）から延びる行き止まり側線への
/// 「進入 → 終端で一時停止 → 後退で本線復帰」を1周のタイムラインとして
/// モデル化する。
///
/// 車両位置は「先頭車のトラック座標 − 連結オフセット」で求める。
/// 後退中も各車両は自分が通ったレールをそのまま引き返すため、
/// 編成が物理的に正しく側線から退出する（弧長パラメータの折り返しを
/// odometer 空間でサンプリングすると終端付近で車間が潰れるため不可）。
library train_route;

import 'dart:math' as math;
import 'dart:ui';

import '../models/api_models.dart';
import '../models/rail_type.dart';

const double kCurveRadiusMm = 103.0;
const double kCurveRadiusLargeMm = 206.0;
const double kCurveSpanRad = 22.5 * math.pi / 180.0;

/// 側線終端の手前でこのマージンを残して停止する
const double kDeadEndMarginMm = 8.0;

/// 側線終端での一時停止時間（秒）
const double kDeadEndDwellSec = 0.8;

/// 端点マッチングの許容距離。レール接続は本来ぴったりだが、
/// 交差レールの直交通過など意図的なジャンプはこの値を超えるので橋渡しする。
const double _kJoinTolMm = 6.0;

/// 位置(mm) + 接線方向(rad)。接線は常に「進入時の前進方向」を向く
/// （後退中も編成の向きは変わらない）。
class TrackPose {
  final Offset position;
  final double heading;
  const TrackPose(this.position, this.heading);
}

/// 直線または円弧の1セグメント（mm空間）
class TrackSeg {
  final double length;
  final bool isArc;
  // 直線用
  final Offset start;
  final Offset dirU;
  // 弧用
  final Offset center;
  final double radius;
  final double startAngle;
  final double angSign; // +1 = 非反転(左旋回) / -1 = 反転(右旋回)

  const TrackSeg.line(this.start, this.dirU, this.length)
      : isArc = false,
        center = Offset.zero,
        radius = 0,
        startAngle = 0,
        angSign = 0;

  const TrackSeg.arc(
      this.center, this.radius, this.startAngle, this.angSign, this.length)
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

  TrackSeg reversed() {
    if (!isArc) {
      final end = posAt(length);
      return TrackSeg.line(end, Offset(-dirU.dx, -dirU.dy), length);
    }
    final endAngle = startAngle + angSign * (length / radius);
    return TrackSeg.arc(center, radius, endAngle, -angSign, length);
  }
}

/// 原点 [origin]・向き [rotRad] のレールから出る22.5°分岐弧を作る。
/// flipped=false は左旋回（非反転カーブと同形）、true は右旋回。
TrackSeg _branchArc(Offset origin, double rotRad, bool flipped) {
  final r = kCurveRadiusMm;
  final len = r * kCurveSpanRad;
  if (!flipped) {
    final center = origin +
        Offset(r * math.cos(rotRad + math.pi / 2),
            r * math.sin(rotRad + math.pi / 2));
    return TrackSeg.arc(center, r, rotRad - math.pi / 2, 1, len);
  }
  final center = origin +
      Offset(r * math.cos(rotRad - math.pi / 2),
          r * math.sin(rotRad - math.pi / 2));
  return TrackSeg.arc(center, r, rotRad + math.pi / 2, -1, len);
}

/// ポイントから延びる側線1本ぶんの往復行程
class SpurExcursion {
  /// 分岐点（ポイント原点）の本線odometer位置
  final double mainOffset;

  /// 分岐弧 + 側線ピース列（進入方向）
  final List<TrackSeg> segs;

  /// 側線全長
  final double length;

  /// 終端マージンを引いた停止位置（先頭車はここまで進む）
  final double stopAt;

  const SpurExcursion({
    required this.mainOffset,
    required this.segs,
    required this.length,
    required this.stopAt,
  });

  TrackPose poseAt(double u) {
    var s = u.clamp(0.0, length);
    for (final seg in segs) {
      if (s <= seg.length) return TrackPose(seg.posAt(s), seg.headingAt(s));
      s -= seg.length;
    }
    final last = segs.last;
    return TrackPose(last.posAt(last.length), last.headingAt(last.length));
  }
}

class _RawSeg {
  final TrackSeg seg;
  final int railIndex;
  const _RawSeg(this.seg, this.railIndex);
}

/// 本線閉ループ + 側線行程の集合
class TrainRoute {
  final List<TrackSeg> mainSegs;
  final double mainLength;

  /// mainOffset 昇順
  final List<SpurExcursion> excursions;

  /// 最終接合時の隙間（幾何整合性の指標。正常なら数mm以下）
  final double closureGapMm;

  TrainRoute._(this.mainSegs, this.mainLength, this.excursions,
      this.closureGapMm);

  TrackPose mainPoseAt(double d) {
    if (mainSegs.isEmpty || mainLength <= 0) {
      return const TrackPose(Offset.zero, 0);
    }
    var s = d % mainLength;
    if (s < 0) s += mainLength;
    for (final seg in mainSegs) {
      if (s <= seg.length) return TrackPose(seg.posAt(s), seg.headingAt(s));
      s -= seg.length;
    }
    final last = mainSegs.last;
    return TrackPose(last.posAt(last.length), last.headingAt(last.length));
  }

  factory TrainRoute.fromRails(List<PlacedRail> rails) {
    // 1. ピースを本線用と側線用に分け、主軸セグメントを作る
    final raw = <_RawSeg>[];
    final spurRaw = <TrackSeg>[];
    for (var i = 0; i < rails.length; i++) {
      final seg = _mainAxisSeg(rails[i]);
      if (seg == null) continue;
      if (rails[i].spur) {
        spurRaw.add(seg);
      } else {
        raw.add(_RawSeg(seg, i));
      }
    }
    if (raw.isEmpty) return TrainRoute._([], 0, const [], 0);

    // 2. 端点の最近傍マッチングで貪欲連結（逆向き許容・隙間は直線ブリッジ）。
    //    各ピースが本線上のどこから始まるか・逆向き通過かを記録する。
    final segs = <TrackSeg>[];
    var total = 0.0;
    void push(TrackSeg s) {
      segs.add(s);
      total += s.length;
    }

    final startDist = <int, double>{}; // railIndex -> odometer
    final traversedReversed = <int, bool>{};

    final used = List<bool>.filled(raw.length, false);
    used[0] = true;
    startDist[raw[0].railIndex] = 0.0;
    traversedReversed[raw[0].railIndex] = false;
    push(raw[0].seg);
    var curEnd = raw[0].seg.posAt(raw[0].seg.length);

    for (var n = 1; n < raw.length; n++) {
      var bestIdx = -1;
      var bestDist = double.infinity;
      var bestRev = false;
      for (var i = 0; i < raw.length; i++) {
        if (used[i]) continue;
        final s = raw[i].seg;
        final dStart = (s.posAt(0) - curEnd).distance;
        final dEnd = (s.posAt(s.length) - curEnd).distance;
        if (dStart < bestDist) {
          bestDist = dStart;
          bestIdx = i;
          bestRev = false;
        }
        if (dEnd < bestDist) {
          bestDist = dEnd;
          bestIdx = i;
          bestRev = true;
        }
      }
      if (bestIdx < 0) break;
      used[bestIdx] = true;
      final chosen =
          bestRev ? raw[bestIdx].seg.reversed() : raw[bestIdx].seg;
      final entry = chosen.posAt(0);
      final gap = (entry - curEnd).distance;
      if (gap > _kJoinTolMm) {
        push(TrackSeg.line(curEnd, (entry - curEnd) / gap, gap));
      }
      startDist[raw[bestIdx].railIndex] = total;
      traversedReversed[raw[bestIdx].railIndex] = bestRev;
      push(chosen);
      curEnd = chosen.posAt(chosen.length);
    }

    // 3. 閉ループの最終接合
    final firstStart = segs.first.posAt(0);
    final endGap = (firstStart - curEnd).distance;
    if (endGap > _kJoinTolMm) {
      push(TrackSeg.line(curEnd, (firstStart - curEnd) / endGap, endGap));
    }

    // 4. 各ポイントの分岐弧 + 側線チェーンを行程化する
    final spurUsed = List<bool>.filled(spurRaw.length, false);
    final excursions = <SpurExcursion>[];
    for (var i = 0; i < rails.length; i++) {
      final rail = rails[i];
      if (rail.spur) continue;
      final branchFlipped = _branchFlippedOf(rail);
      if (branchFlipped == null) continue; // ポイントではない
      // 対向方向（分岐弧の始端接線 = 本線の進行方向）で通過するポイント
      // だけが進路選択できる。背向通過のポイントは素通りする。
      if (traversedReversed[i] != false) continue;

      final rot = rail.rotation * math.pi / 180.0;
      final origin = Offset(rail.originX, rail.originY);
      final exSegs = <TrackSeg>[_branchArc(origin, rot, branchFlipped)];
      var exLen = exSegs.first.length;
      var cur = exSegs.first.posAt(exSegs.first.length);

      // 側線ピースを分岐弧の先から最近傍で辿る（他の側線のピースは
      // 物理的に離れているため許容距離内に現れない）
      while (true) {
        var bestIdx = -1;
        var bestDist = _kJoinTolMm;
        var bestRev = false;
        for (var k = 0; k < spurRaw.length; k++) {
          if (spurUsed[k]) continue;
          final s = spurRaw[k];
          final dStart = (s.posAt(0) - cur).distance;
          final dEnd = (s.posAt(s.length) - cur).distance;
          if (dStart < bestDist) {
            bestDist = dStart;
            bestIdx = k;
            bestRev = false;
          }
          if (dEnd < bestDist) {
            bestDist = dEnd;
            bestIdx = k;
            bestRev = true;
          }
        }
        if (bestIdx < 0) break;
        spurUsed[bestIdx] = true;
        final chosen =
            bestRev ? spurRaw[bestIdx].reversed() : spurRaw[bestIdx];
        exSegs.add(chosen);
        exLen += chosen.length;
        cur = chosen.posAt(chosen.length);
      }

      final stopAt = exLen - kDeadEndMarginMm;
      if (exSegs.length < 2 || stopAt < 20.0) continue; // 側線が短すぎる
      excursions.add(SpurExcursion(
        mainOffset: startDist[i] ?? 0.0,
        segs: exSegs,
        length: exLen,
        stopAt: stopAt,
      ));
    }
    excursions.sort((a, b) => a.mainOffset.compareTo(b.mainOffset));

    return TrainRoute._(segs, total, excursions, endGap);
  }

  /// ピースの主軸セグメント（走行軸）。橋脚は null。
  static TrackSeg? _mainAxisSeg(PlacedRail rail) {
    final rt = RailType.fromApiValue(rail.railType);
    if (rt == RailType.bridgePierStandard || rt == RailType.bridgePierBlock) {
      return null;
    }
    final origin = Offset(rail.originX, rail.originY);
    final rot = rail.rotation * math.pi / 180.0;

    // 曲線主軸: カーブ2種 + Y字ポイント（主軸自体が22.5°カーブ）
    if (rt == RailType.curveR ||
        rt == RailType.curveRLarge ||
        rt == RailType.switchY) {
      final r =
          rt == RailType.curveRLarge ? kCurveRadiusLargeMm : kCurveRadiusMm;
      final len = r * kCurveSpanRad;
      if (!rail.flipped) {
        final center = origin +
            Offset(r * math.cos(rot + math.pi / 2),
                r * math.sin(rot + math.pi / 2));
        return TrackSeg.arc(center, r, rot - math.pi / 2, 1, len);
      }
      final center = origin +
          Offset(r * math.cos(rot - math.pi / 2),
              r * math.sin(rot - math.pi / 2));
      return TrackSeg.arc(center, r, rot + math.pi / 2, -1, len);
    }

    double mm;
    switch (rt) {
      case RailType.straightHalf:
        mm = 53.0;
      case RailType.straightQuarter:
        mm = 26.5;
      case RailType.straightDouble:
        mm = 212.0;
      default:
        mm = 106.0; // straight / stop_rail / incline / crossing / 分岐主軸
    }
    return TrackSeg.line(
        origin, Offset(math.cos(rot), math.sin(rot)), mm);
  }

  /// ポイントの分岐弧の向き。非ポイントは null。
  /// switch_y は主軸が非反転カーブなら分岐は反転側（またはその逆）。
  static bool? _branchFlippedOf(PlacedRail rail) {
    switch (RailType.fromApiValue(rail.railType)) {
      case RailType.switchLeft:
      case RailType.autoTurnout:
        return false;
      case RailType.switchRight:
        return true;
      case RailType.switchY:
        return !rail.flipped;
      default:
        return null;
    }
  }
}

enum _PhaseKind { cruise, inbound, dwell, outbound }

class _Phase {
  final _PhaseKind kind;
  final double dist; // 走行距離（dwellは0）
  final double mainStart; // cruise用: 開始odometer
  final int spur; // 行程index（cruiseは-1）
  const _Phase(this.kind, this.dist, this.mainStart, this.spur);
}

/// 先頭車の現在状態
class EngineState {
  final bool onSpur;
  final int spurIndex;
  final double mainDist; // 本線走行時のodometer
  final double spurDist; // 側線走行時のトラック座標 u
  const EngineState.onMain(this.mainDist)
      : onSpur = false,
        spurIndex = -1,
        spurDist = 0;
  const EngineState.onSpurAt(this.spurIndex, this.spurDist)
      : onSpur = true,
        mainDist = 0;
}

/// 1周ぶんの走行計画（本線 + 全側線の往復 + 終端停止）
class TrainItinerary {
  final TrainRoute route;
  final List<_Phase> _phases;

  /// 1周の総走行距離（本線 + 側線往復）
  final double movingLength;
  final int _dwellCount;

  TrainItinerary._(this.route, this._phases, this.movingLength,
      this._dwellCount);

  factory TrainItinerary.fromRails(List<PlacedRail> rails) {
    final route = TrainRoute.fromRails(rails);
    final phases = <_Phase>[];
    var moving = route.mainLength;
    var prev = 0.0;
    for (var j = 0; j < route.excursions.length; j++) {
      final ex = route.excursions[j];
      final cruise = math.max(ex.mainOffset - prev, 0.0);
      if (cruise > 0) {
        phases.add(_Phase(_PhaseKind.cruise, cruise, prev, -1));
      }
      phases.add(_Phase(_PhaseKind.inbound, ex.stopAt, 0, j));
      phases.add(_Phase(_PhaseKind.dwell, 0, 0, j));
      phases.add(_Phase(_PhaseKind.outbound, ex.stopAt, 0, j));
      moving += 2 * ex.stopAt;
      prev = ex.mainOffset;
    }
    final tail = math.max(route.mainLength - prev, 0.0);
    if (tail > 0 || phases.isEmpty) {
      phases.add(_Phase(_PhaseKind.cruise, tail, prev, -1));
    }
    return TrainItinerary._(
        route, phases, moving, route.excursions.length);
  }

  double lapSeconds(double vMmPerSec) =>
      movingLength / vMmPerSec + _dwellCount * kDeadEndDwellSec;

  EngineState engineStateAt(double tSec, double vMmPerSec) {
    final lap = lapSeconds(vMmPerSec);
    if (lap <= 0 || route.mainLength <= 0) return const EngineState.onMain(0);
    var t = tSec % lap;
    if (t < 0) t += lap;
    for (final ph in _phases) {
      final dur =
          ph.kind == _PhaseKind.dwell ? kDeadEndDwellSec : ph.dist / vMmPerSec;
      if (t <= dur || identical(ph, _phases.last)) {
        final d = math.min(t * vMmPerSec, ph.dist);
        switch (ph.kind) {
          case _PhaseKind.cruise:
            return EngineState.onMain(ph.mainStart + d);
          case _PhaseKind.inbound:
            return EngineState.onSpurAt(ph.spur, d);
          case _PhaseKind.dwell:
            return EngineState.onSpurAt(
                ph.spur, route.excursions[ph.spur].stopAt);
          case _PhaseKind.outbound:
            return EngineState.onSpurAt(
                ph.spur, route.excursions[ph.spur].stopAt - d);
        }
      }
      t -= dur;
    }
    return const EngineState.onMain(0);
  }

  /// 先頭車から [backMm] 後方の車両のポーズ。
  /// 側線内では u−back、本線へはみ出す分は分岐点から後方へ辿る。
  TrackPose poseBehind(EngineState st, double backMm) {
    if (!st.onSpur) return route.mainPoseAt(st.mainDist - backMm);
    final ex = route.excursions[st.spurIndex];
    final u = st.spurDist - backMm;
    if (u >= 0) return ex.poseAt(u);
    return route.mainPoseAt(ex.mainOffset + u);
  }
}
