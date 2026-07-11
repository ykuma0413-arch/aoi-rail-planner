// 走行レイヤー（分岐進路選択）のテスト。
//
// lib/rail/train_route.dart の TrainRoute / TrainItinerary は描画非依存の
// 純粋モデルなので、バックエンドと同じ座標規約で合成したコースを与えて
//   - 本線の幾何（switch_y 主軸 = 曲線）
//   - 側線行程の検出と長さ
//   - 進入 → 終端停止 → 後退復帰 のタイムライン
//   - 走行連続性（テレポートしない）と編成の車間維持
// を機械的に検証する。

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:aoi_rail_planner/models/api_models.dart';
import 'package:aoi_rail_planner/rail/train_route.dart';

const double _r = 103.0;
const double _spanRad = 22.5 * math.pi / 180.0;
const double _curveLen = _r * _spanRad; // ≈ 40.44mm

/// バックエンド walker と同じ規約でピースを連結配置するテスト用ビルダー。
/// 非反転カーブ: ローカル出口 (R sin a, R(1-cos a))・heading +22.5°。
class _Builder {
  double x, y; // mm
  double h = 0; // deg
  final rails = <PlacedRail>[];
  _Builder(this.x, this.y);

  PlacedRail _emit(String type, {bool flipped = false, bool spur = false}) {
    final rail = PlacedRail(
      railType: type,
      originX: x,
      originY: y,
      rotation: h,
      zLevel: 0,
      flipped: flipped,
      spur: spur,
    );
    rails.add(rail);
    return rail;
  }

  void _advanceLine(double mm) {
    final rad = h * math.pi / 180.0;
    x += mm * math.cos(rad);
    y += mm * math.sin(rad);
  }

  void _advanceCurve(bool flipped) {
    final rad = h * math.pi / 180.0;
    final sign = flipped ? -1.0 : 1.0;
    final lx = _r * math.sin(_spanRad);
    final ly = sign * _r * (1.0 - math.cos(_spanRad));
    x += lx * math.cos(rad) - ly * math.sin(rad);
    y += lx * math.sin(rad) + ly * math.cos(rad);
    h = (h + sign * 22.5) % 360.0;
  }

  void straight({bool spur = false}) {
    _emit('straight', spur: spur);
    _advanceLine(106.0);
  }

  void curve({bool flipped = false, bool spur = false}) {
    _emit('curve_r', flipped: flipped, spur: spur);
    _advanceCurve(flipped);
  }

  /// 主軸が直線のポイント（switch_left / switch_right / auto_turnout）
  void switchStraightAxis(String type) {
    _emit(type);
    _advanceLine(106.0);
  }

  /// 主軸が曲線のポイント（switch_y）。非反転カーブと同じ主軸。
  void switchY() {
    _emit('switch_y');
    _advanceCurve(false);
  }

  /// 直前に置いたポイントの分岐出口へカーソルを移す（次のピースが側線先頭になる）。
  /// branchFlipped=false は左分岐（+22.5°）、true は右分岐（−22.5°）。
  void jumpToBranchOf(PlacedRail sw, {required bool branchFlipped}) {
    final rad = sw.rotation * math.pi / 180.0;
    final sign = branchFlipped ? -1.0 : 1.0;
    final lx = _r * math.sin(_spanRad);
    final ly = sign * _r * (1.0 - math.cos(_spanRad));
    x = sw.originX + lx * math.cos(rad) - ly * math.sin(rad);
    y = sw.originY + lx * math.sin(rad) + ly * math.cos(rad);
    h = (sw.rotation + sign * 22.5) % 360.0;
  }
}

/// 直線2本 + カーブ16本のオーバル。先頭の直線を [firstStraight] で差し替え可。
_Builder _oval({String firstStraight = 'straight'}) {
  final b = _Builder(700, 900);
  if (firstStraight == 'straight') {
    b.straight();
  } else {
    b.switchStraightAxis(firstStraight);
  }
  for (var i = 0; i < 8; i++) {
    b.curve();
  }
  b.straight();
  for (var i = 0; i < 8; i++) {
    b.curve();
  }
  return b;
}

void main() {
  const v = 100.0; // mm/s
  final ovalMainLen = 2 * 106.0 + 16 * _curveLen;

  group('経路構築', () {
    test('側線なしのオーバル: 行程なし・1周時間 = 本線長/速度', () {
      final itin = TrainItinerary.fromRails(_oval().rails);
      expect(itin.route.closureGapMm, lessThan(1.0), reason: '本線が閉じていない');
      expect(itin.route.mainLength, closeTo(ovalMainLen, 1.0));
      expect(itin.route.excursions, isEmpty);
      expect(itin.lapSeconds(v), closeTo(ovalMainLen / v, 0.05));
    });

    test('switch_left + 側線直線2本: 行程が1つ検出され長さが一致する', () {
      final b = _oval(firstStraight: 'switch_left');
      b.jumpToBranchOf(b.rails[0], branchFlipped: false);
      b.straight(spur: true);
      b.straight(spur: true);

      final route = TrainRoute.fromRails(b.rails);
      expect(route.closureGapMm, lessThan(1.0));
      expect(route.mainLength, closeTo(ovalMainLen, 1.0),
          reason: 'ポイント主軸(106mm直線)が本線長に正しく寄与していない');
      expect(route.excursions.length, 1);
      expect(route.excursions[0].length, closeTo(_curveLen + 212.0, 1.0),
          reason: '側線長 = 分岐弧 + 直線2本 のはず');
    });

    test('switch_y 主軸は曲線として本線に組み込まれる（直線扱いだと閉路が壊れる）', () {
      // カーブ16本の正円のうち1本を switch_y に差し替え、右分岐に側線1本
      final b = _Builder(900, 700);
      for (var i = 0; i < 3; i++) {
        b.curve();
      }
      final sw = b._emit('switch_y');
      b._advanceCurve(false);
      for (var i = 0; i < 12; i++) {
        b.curve();
      }
      b.jumpToBranchOf(sw, branchFlipped: true);
      b.straight(spur: true);

      final route = TrainRoute.fromRails(b.rails);
      expect(route.closureGapMm, lessThan(1.0),
          reason: 'switch_y を106mm直線として扱うと本線が閉じない');
      expect(route.mainLength, closeTo(16 * _curveLen, 1.0));
      expect(route.excursions.length, 1);
    });
  });

  group('分岐進路選択（進入→終端停止→後退復帰）', () {
    late TrainItinerary itin;
    late SpurExcursion ex;

    setUp(() {
      final b = _oval(firstStraight: 'switch_left');
      b.jumpToBranchOf(b.rails[0], branchFlipped: false);
      b.straight(spur: true);
      b.straight(spur: true);
      itin = TrainItinerary.fromRails(b.rails);
      ex = itin.route.excursions[0];
    });

    test('1周の総走行距離 = 本線 + 側線往復', () {
      expect(itin.movingLength,
          closeTo(itin.route.mainLength + 2 * ex.stopAt, 0.01));
      expect(itin.lapSeconds(v),
          closeTo(itin.movingLength / v + kDeadEndDwellSec, 0.01));
    });

    test('先頭車が側線終端（マージン手前）まで進入し停止する', () {
      // 行程は本線odometer 0 の switch から始まる → 進入完了は t = stopAt/v
      final tIn = ex.stopAt / v;
      final st = itin.engineStateAt(tIn + kDeadEndDwellSec / 2, v);
      expect(st.onSpur, isTrue);
      expect(st.spurDist, closeTo(ex.stopAt, 0.5));

      final pose = itin.poseBehind(st, 0);
      final deadEnd = ex.poseAt(ex.length);
      expect((pose.position - deadEnd.position).distance,
          closeTo(kDeadEndMarginMm, 0.5),
          reason: '終端マージンぶん手前で停止していない');
    });

    test('後退復帰後は本線走行に戻り、1周でスタート地点に帰る', () {
      final tOut = (2 * ex.stopAt) / v + kDeadEndDwellSec;
      final st = itin.engineStateAt(tOut + 0.2, v);
      expect(st.onSpur, isFalse, reason: '後退完了後も側線にいる');

      final lap = itin.lapSeconds(v);
      final poseEnd = itin.poseBehind(itin.engineStateAt(lap - 0.001, v), 0);
      final poseStart = itin.poseBehind(itin.engineStateAt(0.0, v), 0);
      expect((poseEnd.position - poseStart.position).distance, lessThan(1.0),
          reason: '1周してもスタート地点に戻らない');
    });

    test('走行連続性: 全行程を通してテレポートしない（後退折り返し含む）', () {
      const dt = 0.02;
      final lap = itin.lapSeconds(v);
      var prev = itin.poseBehind(itin.engineStateAt(0.0, v), 0).position;
      for (var t = dt; t <= lap + dt; t += dt) {
        final cur = itin.poseBehind(itin.engineStateAt(t, v), 0).position;
        expect((cur - prev).distance, lessThanOrEqualTo(v * dt + 0.5),
            reason: 't=${t.toStringAsFixed(2)}s で位置が飛んだ');
        prev = cur;
      }
    });

    test('車間維持: 後退中も車両同士が潰れたり離れたりしない', () {
      const spacing = 62.0; // 車両中心間 (mm)
      final lap = itin.lapSeconds(v);
      for (var t = 0.0; t <= lap; t += 0.05) {
        final st = itin.engineStateAt(t, v);
        final p0 = itin.poseBehind(st, 0).position;
        final p1 = itin.poseBehind(st, spacing).position;
        final p2 = itin.poseBehind(st, 2 * spacing).position;
        // 曲線上では弦長 < 弧長になるため下限は緩めに取る
        expect((p0 - p1).distance, inInclusiveRange(spacing * 0.85, spacing * 1.01),
            reason: 't=${t.toStringAsFixed(2)}s 先頭-2両目');
        expect((p1 - p2).distance, inInclusiveRange(spacing * 0.85, spacing * 1.01),
            reason: 't=${t.toStringAsFixed(2)}s 2両目-3両目');
      }
    });

    test('複数ポイント: それぞれの側線を1周で1回ずつ訪問する', () {
      // オーバルの直線2本を両方ポイント化し、側線を1本ずつ付ける
      final b = _Builder(700, 900);
      final sw1 = b._emit('switch_left');
      b._advanceLine(106.0);
      for (var i = 0; i < 8; i++) {
        b.curve();
      }
      final sw2 = b._emit('auto_turnout');
      b._advanceLine(106.0);
      for (var i = 0; i < 8; i++) {
        b.curve();
      }
      b.jumpToBranchOf(sw1, branchFlipped: false);
      b.straight(spur: true);
      b.jumpToBranchOf(sw2, branchFlipped: false);
      b.straight(spur: true);

      final it2 = TrainItinerary.fromRails(b.rails);
      expect(it2.route.excursions.length, 2);
      // 各側線 = 分岐弧 + 直線1本
      for (final e in it2.route.excursions) {
        expect(e.length, closeTo(_curveLen + 106.0, 1.0));
      }
      expect(
          it2.movingLength,
          closeTo(
              it2.route.mainLength +
                  2 * it2.route.excursions[0].stopAt +
                  2 * it2.route.excursions[1].stopAt,
              0.01));

      // 1周のなかで両方の側線に入る（それぞれの終端付近を通過する）
      final lap = it2.lapSeconds(v);
      final visited = <int>{};
      for (var t = 0.0; t <= lap; t += 0.02) {
        final st = it2.engineStateAt(t, v);
        if (st.onSpur && st.spurDist > it2.route.excursions[st.spurIndex].stopAt - 1) {
          visited.add(st.spurIndex);
        }
      }
      expect(visited, {0, 1}, reason: '全ての側線を訪問していない');
    });
  });
}
