import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../models/api_models.dart';

const String _apiBase = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://your-func-app.azurewebsites.net/api',
);
const String _funcKey = String.fromEnvironment('FUNC_KEY', defaultValue: '');

final configProvider = FutureProvider<AppConfig>((ref) async {
  try {
    // ウォームアップPingを非同期で投げてコンテナを温める
    _warmupPing();

    final uri = Uri.parse('$_apiBase/config');
    final response = await http.get(
      uri,
      headers: {if (_funcKey.isNotEmpty) 'x-functions-key': _funcKey},
    ).timeout(const Duration(seconds: 5));

    if (response.statusCode == 200) {
      return AppConfig.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
    }
  } catch (_) {
    // コンフィグ取得失敗時はデフォルト値で継続
  }
  return const AppConfig();
});

/// コールドスタート対策: アプリ起動直後に非同期ダミーPingを送信
void _warmupPing() {
  Future.microtask(() async {
    try {
      // /config は匿名アクセス可のため関数キー不要でコンテナを温められる
      await http
          .get(Uri.parse('$_apiBase/config'))
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // フォールバック: Pingの失敗はサイレント無視
    }
  });
}
