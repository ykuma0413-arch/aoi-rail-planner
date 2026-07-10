/// レールピースの弧長ジオメトリ（描画非依存の純粋関数群）。
///
/// 設計方針:
///   直線・曲線を「曲率 k = 総旋回角 / 弧長」で統一的に扱い、
///   弧長パラメータ s → (座標, 接線方向) を単一の式で計算する。
///   直線は k→0 の極限としてガード付きで同じコードパスを通る
///   （直線用と曲線用でロジックを分けない）。
///
/// 枕木(computeTiePositions)・ジョイント形状(JointShapes)は
/// _renderPiece 等の描画コードから独立してテスト可能。
library rail_geometry;

import 'dart:math' as math;
import 'dart:ui';

/// 実寸換算の枕木間隔 (mm)
const double kTieSpacingMm = 18.0;

/// ジョイント形状（凹=female / 凸=male）
enum JointShape { female, male }

class JointShapes {
  final JointShape entry;
  final JointShape exit;
  const JointShapes({required this.entry, required this.exit});
}

/// レール1ピースの走行ジオメトリ。
/// [lengthMm] は弧長、[turnDegrees] は総旋回角（符号付き、0=直線）。
class RailPiece {
  final double lengthMm;
  final double turnDegrees;

  const RailPiece({required this.lengthMm, required this.turnDegrees});

  /// 直線レール (106mm)
  factory RailPiece.straight({double lengthMm = 106.0}) =>
      RailPiece(lengthMm: lengthMm, turnDegrees: 0);

  /// 曲線レール（半径103mm・旋回角は度）
  factory RailPiece.curve(
      {double turnDegrees = 22.5, double radiusMm = 103.0}) {
    final len = radiusMm * turnDegrees.abs() * math.pi / 180.0;
    return RailPiece(lengthMm: len, turnDegrees: turnDegrees);
  }

  /// 全ピース共通: 入口=凹(female)・出口=凸(male)
  JointShapes get jointShapes =>
      const JointShapes(entry: JointShape.female, exit: JointShape.male);
}

/// 弧長パラメータ上のポーズ（座標 + 接線方向 rad）
class ArcPose {
  final Offset position;
  final double headingRad;
  const ArcPose(this.position, this.headingRad);
}

/// 弧長 s におけるポーズを返す統一関数。
///
///   k = turnRadians / lengthMm （曲率）
///   θ(s) = k・s
///   位置 = (R sinθ, R(1−cosθ))  [R = 1/k]  … k→0 では (s, 0) に連続収束
///
/// [origin]/[heading0] でワールド座標へ配置できる（省略時はローカル座標）。
ArcPose poseAtArcLength({
  required double lengthMm,
  required double turnRadians,
  required double s,
  Offset origin = Offset.zero,
  double heading0 = 0,
}) {
  final k = lengthMm.abs() < 1e-12 ? 0.0 : turnRadians / lengthMm;
  final th = k * s;
  double lx, ly;
  if (k.abs() < 1e-9) {
    // 直線極限
    lx = s;
    ly = 0;
  } else {
    final r = 1.0 / k;
    lx = r * math.sin(th);
    ly = r * (1.0 - math.cos(th));
  }
  final c = math.cos(heading0);
  final sn = math.sin(heading0);
  return ArcPose(
    Offset(origin.dx + lx * c - ly * sn, origin.dy + lx * sn + ly * c),
    heading0 + th,
  );
}

/// 枕木のポーズ列（中心座標+向き）を返す純粋関数。
/// 枕木は弧長に沿って [spacing] 間隔で等間隔配置し、
/// 端の余りは両側に均等に振り分ける（中央寄せ）。
List<ArcPose> computeTiePoses(
  RailPiece piece, {
  required double spacingMm,
  Offset origin = Offset.zero,
  double heading0 = 0,
}) {
  if (spacingMm <= 0 || piece.lengthMm <= 0) return const [];
  final n = (piece.lengthMm / spacingMm).floor();
  if (n < 1) return const [];
  final turnRad = piece.turnDegrees * math.pi / 180.0;
  final start = (piece.lengthMm - spacingMm * (n - 1)) / 2.0;
  return [
    for (var i = 0; i < n; i++)
      poseAtArcLength(
        lengthMm: piece.lengthMm,
        turnRadians: turnRad,
        s: start + i * spacingMm,
        origin: origin,
        heading0: heading0,
      ),
  ];
}

/// 枕木の中心座標リスト（テスト用の簡易形）。
List<Offset> computeTiePositions(RailPiece piece,
    {required double spacingMm}) {
  return [
    for (final p in computeTiePoses(piece, spacingMm: spacingMm)) p.position
  ];
}
