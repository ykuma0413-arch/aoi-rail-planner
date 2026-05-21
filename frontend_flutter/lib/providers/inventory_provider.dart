import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/inventory_item.dart';
import '../models/rail_type.dart';

const int _maxTotalInventory = 100;

class InventoryNotifier extends StateNotifier<List<InventoryItem>> {
  InventoryNotifier() : super(_defaultInventory());

  static List<InventoryItem> _defaultInventory() => RailType.values
      .map((rt) => InventoryItem(railType: rt, count: 0))
      .toList();

  int get totalCount =>
      state.fold(0, (sum, item) => sum + item.count);

  /// ＋ボタン: 在庫上限100個ガードインターセプター
  void increment(RailType railType) {
    if (totalCount >= _maxTotalInventory) return;
    state = [
      for (final item in state)
        if (item.railType == railType)
          item.copyWith(count: item.count + 1)
        else
          item,
    ];
  }

  /// − ボタン
  void decrement(RailType railType) {
    state = [
      for (final item in state)
        if (item.railType == railType && item.count > 0)
          item.copyWith(count: item.count - 1)
        else
          item,
    ];
  }

  /// エッジAIスキャン結果を読み込む際の上限ガード
  void loadFromScan(Map<String, int> scanResult) {
    final updated = <InventoryItem>[];
    int running = 0;

    for (final item in state) {
      final scanned = scanResult[item.railType.apiValue] ?? item.count;
      final capped = (running + scanned <= _maxTotalInventory)
          ? scanned
          : (_maxTotalInventory - running).clamp(0, scanned);
      running += capped;
      updated.add(item.copyWith(count: capped));
    }
    state = updated;
  }

  void reset() {
    state = _defaultInventory();
  }

  List<InventoryItem> get nonZeroItems =>
      state.where((i) => i.count > 0).toList();
}

final inventoryProvider =
    StateNotifierProvider<InventoryNotifier, List<InventoryItem>>(
  (ref) => InventoryNotifier(),
);

// inventoryProvider の "state" を watch する（notifier は不変なので watch しても再評価されない）
final totalCountProvider = Provider<int>((ref) {
  final items = ref.watch(inventoryProvider);
  return items.fold<int>(0, (sum, item) => sum + item.count);
});
