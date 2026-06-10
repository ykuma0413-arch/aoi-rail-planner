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
import 'widgets/mini_rail_icon.dart';
import '../utils/amazon_links.dart';

const _themes = {
  'standard': 'おまかせ',
  'figure8': 'コンパクト',
  'elevated': 'こうか（坂＋橋脚）',
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
          // ヒント＋クイックスタート
          _MinRequirementHint(onQuickStart: _loadRecommendedSet),
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

  void _loadRecommendedSet() {
    // ループ閉鎖の最低要件: カーブ16本 (各22.5° × 16 = 360°) + 直線数本
    final notifier = ref.read(inventoryProvider.notifier);
    notifier.reset();
    for (int i = 0; i < 16; i++) {
      notifier.increment(RailType.curveR);
    }
    for (int i = 0; i < 4; i++) {
      notifier.increment(RailType.straight);
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('おすすめ構成を読み込みました: カーブ16本 + 直線4本'),
        duration: Duration(seconds: 2),
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

class _MinRequirementHint extends ConsumerWidget {
  final VoidCallback onQuickStart;
  const _MinRequirementHint({required this.onQuickStart});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(inventoryProvider);
    // 生成エンジンが閉ループに使えるのは標準カーブ + 大カーブのみ
    // （エンジン側の REQUIRED_CURVES 判定と必ず一致させること）
    final curveCount = items
        .where((i) => [
              RailType.curveR,
              RailType.curveRLarge,
            ].contains(i.railType))
        .fold<int>(0, (sum, i) => sum + i.count);

    final isEnough = curveCount >= 16;
    final shortage = (16 - curveCount).clamp(0, 16);

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isEnough
            ? const Color(0xFF4CAF50).withOpacity(0.10)
            : const Color(0xFFFFA726).withOpacity(0.15),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isEnough
              ? const Color(0xFF4CAF50)
              : const Color(0xFFFFA726),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isEnough ? Icons.check_circle : Icons.info_outline,
                color: isEnough
                    ? const Color(0xFF4CAF50)
                    : const Color(0xFFFFA726),
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isEnough
                      ? 'カーブ系 $curveCount 本 OK！ループを閉じられます'
                      : 'ループ完成には カーブ系レール 最低16本が必要です',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: isEnough
                        ? const Color(0xFF2E7D32)
                        : const Color(0xFFE65100),
                  ),
                ),
              ),
            ],
          ),
          if (!isEnough) ...[
            const SizedBox(height: 6),
            Text(
              '現在: カーブ系 $curveCount 本（あと $shortage 本足りません）',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFE65100),
                  side: const BorderSide(color: Color(0xFFFFA726)),
                  padding: const EdgeInsets.symmetric(vertical: 4),
                ),
                icon: const Icon(Icons.flash_on, size: 18),
                label: const Text('おすすめ構成（カーブ16+直線4）を自動投入'),
                onPressed: onQuickStart,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RailCountRow extends ConsumerWidget {
  final InventoryItem item;

  const _RailCountRow({required this.item});

  Future<void> _showCountInput(BuildContext context, WidgetRef ref) async {
    final controller =
        TextEditingController(text: item.count.toString());
    final result = await showDialog<int?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            MiniRailIcon(railType: item.railType, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item.railType.displayName,
                style: const TextStyle(fontSize: 16),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
              ),
              decoration: const InputDecoration(
                labelText: '個数',
                suffixText: '個',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) {
                final n = int.tryParse(v) ?? 0;
                Navigator.of(ctx).pop(n);
              },
            ),
            const SizedBox(height: 8),
            const Text(
              '※ 全体合計100個まで',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(0),
            child: const Text('0 にする',
                style: TextStyle(color: Colors.red)),
          ),
          FilledButton(
            onPressed: () {
              final n = int.tryParse(controller.text) ?? 0;
              Navigator.of(ctx).pop(n);
            },
            child: const Text('決定'),
          ),
        ],
      ),
    );
    if (result != null) {
      ref.read(inventoryProvider.notifier).setCount(item.railType, result);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(inventoryProvider.notifier);
    final total = ref.watch(totalCountProvider);

    return InkWell(
      onTap: () => _showCountInput(context, ref),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            // デフォルメアイコン
            Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: item.count > 0
                    ? const Color(0xFF0072BC).withOpacity(0.06)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: item.count > 0
                      ? const Color(0xFF0072BC).withOpacity(0.4)
                      : Colors.black12,
                  width: 1,
                ),
              ),
              child: MiniRailIcon(railType: item.railType, size: 40),
            ),
            const SizedBox(width: 12),
            // 名前
            Expanded(
              child: Text(
                item.railType.displayName,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight:
                      item.count > 0 ? FontWeight.w600 : FontWeight.normal,
                  color: item.count > 0
                      ? Colors.black87
                      : Colors.black54,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // ボタン群
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              color: Colors.red,
              iconSize: 28,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(),
              onPressed: item.count > 0
                  ? () => notifier.decrement(item.railType)
                  : null,
            ),
            // 数字（タップで直接入力ダイアログ）
            InkWell(
              onTap: () => _showCountInput(context, ref),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                width: 48,
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: item.count > 0
                      ? const Color(0xFF0072BC).withOpacity(0.08)
                      : Colors.grey.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: const Color(0xFF0072BC).withOpacity(0.3),
                    width: 1,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  '${item.count}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF0072BC),
                  ),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              color: const Color(0xFF0072BC),
              iconSize: 28,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(),
              onPressed:
                  total < 100 ? () => notifier.increment(item.railType) : null,
            ),
            const SizedBox(width: 2),
            // Amazon で追加購入（アフィリエイトリンク）
            IconButton(
              icon: const Icon(Icons.add_shopping_cart),
              color: const Color(0xFFFF9900),
              iconSize: 22,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(),
              tooltip: 'Amazonで購入',
              onPressed: () => launchAmazon(item.railType),
            ),
          ],
        ),
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
