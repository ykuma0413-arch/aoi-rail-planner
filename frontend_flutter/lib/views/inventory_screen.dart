import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/inventory_item.dart';
import '../models/rail_type.dart';
import '../models/api_models.dart';
import '../providers/inventory_provider.dart';
import '../providers/layout_provider.dart';
import '../providers/config_provider.dart';
import 'camera_scan_view.dart';
import 'layout_canvas_view.dart';
import 'suggest_screen.dart';
import 'history_screen.dart';

const _themes = {
  'standard': '基本オーバル',
  'figure8': '8の字',
  'elevated': '立体交差',
};

class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  String _selectedTheme = 'standard';

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(inventoryProvider);
    final total = ref.watch(totalCountProvider);
    final layoutState = ref.watch(layoutProvider);
    final configAsync = ref.watch(configProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('おまかせAIレールプランナー'),
        backgroundColor: const Color(0xFF0072BC),
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HistoryScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.camera_alt),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const CameraScanView()),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // 在庫合計バー
          Container(
            color: const Color(0xFF0072BC).withOpacity(0.08),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.inventory_2, color: Color(0xFF0072BC)),
                const SizedBox(width: 8),
                Text(
                  '合計: $total / 100 個',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0072BC),
                  ),
                ),
                const Spacer(),
                if (total >= 100)
                  const Chip(
                    label: Text('上限', style: TextStyle(color: Colors.white, fontSize: 12)),
                    backgroundColor: Colors.orange,
                    padding: EdgeInsets.zero,
                  ),
              ],
            ),
          ),
          // 在庫リスト
          Expanded(
            child: ListView.builder(
              itemCount: inventory.length,
              itemBuilder: (context, i) =>
                  _RailCountRow(item: inventory[i]),
            ),
          ),
          // テーマ選択 + 生成ボタン
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8)],
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Text('テーマ: ', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: _selectedTheme,
                      items: _themes.entries
                          .map((e) => DropdownMenuItem(
                                value: e.key,
                                child: Text(e.value),
                              ))
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _selectedTheme = v ?? 'standard'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0072BC),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: layoutState is LayoutLoading || total == 0
                        ? null
                        : () => _generate(context),
                    icon: layoutState is LayoutLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.auto_fix_high, color: Colors.white),
                    label: Text(
                      layoutState is LayoutLoading ? '生成中...' : 'AIでレイアウト生成',
                      style: const TextStyle(fontSize: 16, color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _generate(BuildContext context) async {
    await ref
        .read(layoutProvider.notifier)
        .generateLayout(_selectedTheme);

    if (!mounted) return;

    final state = ref.read(layoutProvider);
    if (state is LayoutSuccess) {
      final resp = state.response;
      if (resp.isSuggestedLayout) {
        // 工事中画面へナビゲーション
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SuggestScreen(response: resp),
          ),
        );
      } else {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => _LayoutResultScreen(response: resp),
          ),
        );
      }
    } else if (state is LayoutError) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SuggestScreen(errorMessage: state.message),
        ),
      );
    }
  }
}

class _RailCountRow extends ConsumerWidget {
  final InventoryItem item;

  const _RailCountRow({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(inventoryProvider.notifier);
    final total = ref.watch(totalCountProvider);

    return ListTile(
      dense: true,
      title: Text(item.railType.displayName),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline),
            color: Colors.red,
            onPressed: item.count > 0
                ? () => notifier.decrement(item.railType)
                : null,
          ),
          SizedBox(
            width: 32,
            child: Text(
              '${item.count}',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            color: const Color(0xFF0072BC),
            // 在庫上限100個ガード
            onPressed: total < 100
                ? () => notifier.increment(item.railType)
                : null,
          ),
        ],
      ),
    );
  }
}

class _LayoutResultScreen extends StatelessWidget {
  final LayoutResponse response;

  const _LayoutResultScreen({required this.response});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('レイアウト完成！'),
        backgroundColor: const Color(0xFF0072BC),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            child: LayoutCanvasView(layout: response),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.white,
            child: Column(
              children: [
                if (response.llmComment.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0072BC).withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.auto_awesome, color: Color(0xFF0072BC)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(response.llmComment)),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.star, color: Colors.amber),
                    const SizedBox(width: 4),
                    Text(
                      'スコア: ${(response.score * 100).round()}点',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
