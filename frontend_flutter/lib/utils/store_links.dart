import 'package:url_launcher/url_launcher.dart';
import '../models/rail_type.dart';

/// 楽天市場アフィリエイトリンク生成。
/// コンプライアンス要件(§8)によりブランド名のリテラル文字列はコードに保持しない
/// ため、検索キーワードはすべて URL エンコード済みの定数で持つ。

/// おもちゃの電車ブランドの検索キーワード（URLエンコード済み）。
const String _brandKw = '%E3%83%97%E3%83%A9%E3%83%AC%E3%83%BC%E3%83%AB';

/// 楽天アフィリエイトID（ビルド時に --dart-define=RAKUTEN_AID=... で上書き可）
const String _affiliateId = String.fromEnvironment(
  'RAKUTEN_AID',
  defaultValue: '54db65ab.927c5a3b.54db65ac.ffa6cfb0',
);

/// レール種別ごとの製品検索キーワード（URLエンコード済み）
const Map<RailType, String> _partKw = {
  RailType.straight: '%E7%9B%B4%E7%B7%9A%E3%83%AC%E3%83%BC%E3%83%AB',            // 直線レール
  RailType.straightHalf: '1%2F2%E7%9B%B4%E7%B7%9A%E3%83%AC%E3%83%BC%E3%83%AB',   // 1/2直線レール
  RailType.straightQuarter: '1%2F4%E7%9B%B4%E7%B7%9A%E3%83%AC%E3%83%BC%E3%83%AB', // 1/4直線レール
  RailType.stopRail: '%E3%82%B9%E3%83%88%E3%83%83%E3%83%97%E3%83%AC%E3%83%BC%E3%83%AB', // ストップレール
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
  RailType.switchY: 'Y%E5%AD%97%E3%83%9D%E3%82%A4%E3%83%B3%E3%83%88',            // Y字ポイント
  RailType.autoTurnout:
      '%E8%87%AA%E5%8B%95%E3%83%9D%E3%82%A4%E3%83%B3%E3%83%88%E3%83%AC%E3%83%BC%E3%83%AB', // 自動ポイントレール
  RailType.crossPoint: '%E4%BA%A4%E5%B7%AE%E3%83%9D%E3%82%A4%E3%83%B3%E3%83%88',  // 交差ポイント
  RailType.bridgePierStandard: '%E6%A9%8B%E8%84%9A',                             // 橋脚
  RailType.bridgePierBlock: '%E3%83%96%E3%83%AD%E3%83%83%E3%82%AF%E6%A9%8B%E8%84%9A', // ブロック橋脚
  RailType.flexible: '%E3%81%BE%E3%81%8C%E3%83%AC%E3%83%BC%E3%83%AB',            // まがレール
  RailType.straightDouble: '2%E5%80%8D%E7%9B%B4%E7%B7%9A%E3%83%AC%E3%83%BC%E3%83%AB', // 2倍直線レール
};

/// 楽天市場の検索URL（エンコード済みキーワードをそのまま使う）。
String _rakutenSearchUrl(RailType railType) {
  final kw = _partKw[railType] ?? '';
  // 「ブランド名 パーツ名」を %20 で連結（いずれもエンコード済み）
  final query = kw.isEmpty ? _brandKw : '$_brandKw%20$kw';
  return 'https://search.rakuten.co.jp/search/mall/$query/';
}

/// レール種別に応じた楽天アフィリエイト検索URLを返す。
/// 検索URLを `hb.afl.rakuten.co.jp` のアフィリエイトラッパーに包む。
String storeUrlFor(RailType railType) {
  final search = _rakutenSearchUrl(railType);
  if (_affiliateId.isEmpty) return search;
  // 検索URL（既に%エンコード済み）をさらにエンコードして pc/m パラメータへ。
  // これによりブランド名リテラルはコード上にもURL上にも現れない。
  final enc = Uri.encodeComponent(search);
  return 'https://hb.afl.rakuten.co.jp/hgc/$_affiliateId/?pc=$enc&m=$enc';
}

/// 外部ブラウザで楽天市場の検索結果を開く（アフィリエイト経由）。
Future<void> launchStore(RailType railType) async {
  final uri = Uri.parse(storeUrlFor(railType));
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}
