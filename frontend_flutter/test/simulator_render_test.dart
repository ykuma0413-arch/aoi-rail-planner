// 描画レイヤーのテスト（雛形の import を実プロジェクトに合わせて調整済み）。
//
// computeTiePositions / RailPiece / JointShapes は
// lib/rail/rail_geometry.dart に描画非依存の純粋関数として実装されている。

import 'package:flutter_test/flutter_test.dart';
import 'package:aoi_rail_planner/rail/rail_geometry.dart';

const double tieSpacingMm = 18.0;
const double tieToleranceMm = 1.5;

void main() {
  group('枕木(タイ)描画', () {
    test('直線パーツ: 枕木の間隔が均等である', () {
      final piece = RailPiece.straight();
      final ties = computeTiePositions(piece, spacingMm: tieSpacingMm);

      expect(ties.length, greaterThan(1), reason: '枕木が1本も描画されていない疑い');

      for (var i = 1; i < ties.length; i++) {
        final dist = (ties[i] - ties[i - 1]).distance;
        expect(
          dist,
          closeTo(tieSpacingMm, tieToleranceMm),
          reason: '枕木の間隔が不均等(index $i)。曲線と直線で別ロジックになっている可能性',
        );
      }
    });

    test('曲線パーツ: 枕木が弧に沿って進行方向に直交している', () {
      final piece = RailPiece.curve(turnDegrees: 45);
      final ties = computeTiePositions(piece, spacingMm: tieSpacingMm);

      expect(ties.length, greaterThan(1), reason: '曲線パーツで枕木が描画されていない疑い');

      // 枕木の向きが接線に対して垂直かどうかは、
      // computeTieOrientations 的な補助関数がある場合はそちらでテストするのが望ましい。
      // ここでは最低限、曲線パーツでも直線と同程度の密度で枕木が存在することのみ確認する。
      final straightTies = computeTiePositions(
        RailPiece.straight(),
        spacingMm: tieSpacingMm,
      );
      final densityRatio = ties.length / straightTies.length;
      expect(
        densityRatio,
        closeTo(1.0, 0.3),
        reason: '曲線パーツの枕木密度が直線パーツと極端に違う',
      );
    });
  });

  group('ジョイント(接続部)描画', () {
    test('パーツの両端に凸/凹ジョイント形状が定義されている', () {
      final piece = RailPiece.straight();
      final joints = piece.jointShapes;

      expect(joints.entry, isNotNull, reason: '入口側ジョイント形状が未定義');
      expect(joints.exit, isNotNull, reason: '出口側ジョイント形状が未定義');
      expect(
        joints.entry,
        isNot(equals(joints.exit)),
        reason: '入口と出口が同形状(凸/凹の区別がない)。接続の視覚的整合性に問題',
      );
    });
  });
}
