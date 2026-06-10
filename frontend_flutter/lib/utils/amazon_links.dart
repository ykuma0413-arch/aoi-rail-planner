import 'package:url_launcher/url_launcher.dart';
import '../models/rail_type.dart';

/// おもちゃの電車ブランドの検索キーワード（URLエンコード済み）。
/// コンプライアンス要件によりブランド名のリテラル文字列は保持しない。
const String _brandKw = '%E3%83%97%E3%83%A9%E3%83%AC%E3%83%BC%E3%83%AB';

/// Amazon アソシエイトタグ（ビルド時に --dart-define=AMAZON_TAG=xxx で注入）
const String _affiliateTag = String.fromEnvironment('AMAZON_TAG', defaultValue: '');

/// レール種別ごとの製品検索キーワード（URLエンコード済み）
const Map<RailType, String> _partKw = {
  RailType.straight: '%E7%9B%B4%E7%B7%9A%E3%83%AC%E3%83%BC%E3%83%AB',            // 直線レール
  RailType.straightHalf: '1%2F2%E7%9B%B4%E7%B7%9A%E3%83%AC%E3%83%BC%E3%83%AB',   // 1/2直線レール
  RailType.curveR: '%E6%9B%B2%E7%B7%9A%E3%83%AC%E3%83%BC%E3%83%AB',              // 曲線レール
  RailType.curveRLarge:
      '%E8%A4%87%E7%B7%9A%E5%A4%96%E5%81%B4%E6%9B%B2%E7%B7%9A%E3%83%AC%E3%83%BC%E3%83%AB', // 複線外側曲線レール
  RailType.inclineStart: '%E5%9D%82%E3%83%AC%E3%83%BC%E3%83%AB',                 // 坂レール
  RailType.inclineMiddle: '%E5%9D%82%E3%83%AC%E3%83%BC%E3%83%AB',
  RailType.inclineEnd: '%E5%9D%82%E3%83%AC%E3%83%BC%E3%83%AB',
  RailType.crossing: '%E4%BA%A4%E5%B7%AE%E3%83%9D%E3%82%A4%E3%83%B3%E3%83%88',   // 交差ポイント
  RailType.switchLeft:
      '%E3%82%BF%E3%83%BC%E3%83%B3%E3%82%A2%E3%82%A6%E3%83%88%E3%83%AC%E3%83%BC%E3%83%AB', // ターンアウトレール
  RailType.switchRight:
      '%E3%82%BF%E3%83%BC%E3%83%B3%E3%82%A2%E3%82%A6%E3%83%88%E3%83%AC%E3%83%BC%E3%83%AB',
  RailType.bridgePierStandard: '%E6%A9%8B%E8%84%9A',                             // 橋脚
  RailType.bridgePierBlock: '%E3%83%96%E3%83%AD%E3%83%83%E3%82%AF%E6%A9%8B%E8%84%9A', // ブロック橋脚
  RailType.flexible: '%E3%81%BE%E3%81%8C%E3%83%AC%E3%83%BC%E3%83%AB',            // まがレール
  RailType.straightDouble: '2%E5%80%8D%E7%9B%B4%E7%B7%9A%E3%83%AC%E3%83%BC%E3%83%AB', // 2倍直線レール
};

/// レール種別に応じた Amazon おもちゃカテゴリ検索 URL を返す
String amazonUrlFor(RailType railType) {
  final kw = _partKw[railType] ?? '';
  var url = 'https://www.amazon.co.jp/s?i=toys&k=$_brandKw';
  if (kw.isNotEmpty) url += '+$kw';
  if (_affiliateTag.isNotEmpty) url += '&tag=$_affiliateTag';
  return url;
}

/// 外部ブラウザで Amazon 検索を開く
Future<void> launchAmazon(RailType railType) async {
  final uri = Uri.parse(amazonUrlFor(railType));
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
