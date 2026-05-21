/// あおいレールプランナー - レール種別モデル
enum RailType {
  straight('straight', '直線レール'),
  straightHalf('straight_half', '直線レール（ハーフ）'),
  curveR('curve_r', '曲線レール（R）'),
  curveRLarge('curve_r_large', '大カーブレール'),
  inclineStart('incline_start', '勾配開始レール'),
  inclineMiddle('incline_middle', '勾配中間レール'),
  inclineEnd('incline_end', '勾配終了レール'),
  crossing('crossing', '交差レール'),
  switchLeft('switch_left', '左分岐レール'),
  switchRight('switch_right', '右分岐レール'),
  bridgePierStandard('bridge_pier_standard', '橋脚（標準）'),
  bridgePierBlock('bridge_pier_block', '橋脚（ブロック）'),
  flexible('flexible', 'まがレール'),
  straightDouble('straight_double', '直線レール（2倍）');

  const RailType(this.apiValue, this.displayName);

  final String apiValue;
  final String displayName;

  static RailType? fromApiValue(String value) {
    for (final rt in values) {
      if (rt.apiValue == value) return rt;
    }
    return null;
  }
}
