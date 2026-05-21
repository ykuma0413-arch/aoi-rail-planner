import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

import '../models/api_models.dart';
import '../models/history_record.dart';
import 'inventory_provider.dart';

// Azure Functions の関数キー付きURL（環境変数またはビルド定数で注入）
const String _apiBase = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'https://your-func-app.azurewebsites.net/api',
);
const String _funcKey = String.fromEnvironment('FUNC_KEY', defaultValue: '');

sealed class LayoutState {}

class LayoutIdle extends LayoutState {}

class LayoutLoading extends LayoutState {}

class LayoutSuccess extends LayoutState {
  final LayoutResponse response;
  LayoutSuccess(this.response);
}

class LayoutError extends LayoutState {
  final String message;
  LayoutError(this.message);
}

class LayoutNotifier extends StateNotifier<LayoutState> {
  LayoutNotifier(this.ref) : super(LayoutIdle());

  final Ref ref;
  Database? _db;

  Future<Database> _getDb() async {
    _db ??= await openDatabase(
      join(await getDatabasesPath(), 'aoi_rail.db'),
      onCreate: (db, _) => db.execute(HistoryRecord.createTableSql),
      version: 1,
    );
    return _db!;
  }

  Future<void> generateLayout(String theme) async {
    state = LayoutLoading();

    final inventory =
        ref.read(inventoryProvider.notifier).nonZeroItems;

    if (inventory.isEmpty) {
      state = LayoutError('在庫が登録されていません');
      return;
    }

    final request = LayoutRequest(
      inventory: inventory,
      theme: theme,
      sessionId: DateTime.now().millisecondsSinceEpoch.toString(),
    );

    try {
      final uri = Uri.parse('$_apiBase/layout_generator');
      final response = await http.post(
        uri,
        headers: {
          'Content-Type': 'application/json',
          if (_funcKey.isNotEmpty) 'x-functions-key': _funcKey,
        },
        body: jsonEncode(request.toJson()),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        state = LayoutError('サーバーエラー: ${response.statusCode}');
        return;
      }

      final layout = LayoutResponse.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );

      await _saveHistory(layout);
      state = LayoutSuccess(layout);
    } catch (e) {
      state = LayoutError('通信エラーが発生しました');
    }
  }

  Future<void> _saveHistory(LayoutResponse layout) async {
    final db = await _getDb();
    final record = HistoryRecord(
      layoutId: layout.layoutId,
      placedRailsJson: jsonEncode(
        layout.placedRails.map((r) => {
          'rail_type': r.railType,
          'origin_x': r.originX,
          'origin_y': r.originY,
          'rotation': r.rotation,
          'z_level': r.zLevel,
        }).toList(),
      ),
      llmComment: layout.llmComment,
      score: layout.score,
      isClosed: !layout.isSuggestedLayout,
      createdAt: DateTime.now(),
    );
    await db.insert(HistoryRecord.tableName, record.toMap());
  }

  Future<List<HistoryRecord>> loadHistory() async {
    final db = await _getDb();
    final rows = await db.query(
      HistoryRecord.tableName,
      orderBy: 'created_at DESC',
      limit: 50,
    );
    return rows.map(HistoryRecord.fromMap).toList();
  }

  void reset() => state = LayoutIdle();
}

final layoutProvider =
    StateNotifierProvider<LayoutNotifier, LayoutState>(
  (ref) => LayoutNotifier(ref),
);
