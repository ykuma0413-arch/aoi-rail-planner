import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/history_record.dart';
import '../models/api_models.dart';
import '../providers/layout_provider.dart';
import 'layout_canvas_view.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  List<HistoryRecord>? _records;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records =
        await ref.read(layoutProvider.notifier).loadHistory();
    if (mounted) setState(() => _records = records);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('履歴'),
        backgroundColor: const Color(0xFF0072BC),
        foregroundColor: Colors.white,
      ),
      body: _records == null
          ? const Center(child: CircularProgressIndicator())
          : _records!.isEmpty
              ? const Center(
                  child: Text('まだ履歴がありません\nレイアウトを生成してみましょう！',
                      textAlign: TextAlign.center),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: _records!.length,
                  itemBuilder: (context, i) => _HistoryCard(
                    record: _records![i],
                  ),
                ),
    );
  }
}

class _HistoryCard extends StatelessWidget {
  final HistoryRecord record;

  const _HistoryCard({required this.record});

  @override
  Widget build(BuildContext context) {
    final date = record.createdAt;
    final dateStr =
        '${date.year}/${date.month.toString().padLeft(2, '0')}/${date.day.toString().padLeft(2, '0')} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: record.isClosed
              ? const Color(0xFF0072BC)
              : Colors.orange,
          child: Icon(
            record.isClosed ? Icons.check : Icons.construction,
            color: Colors.white,
            size: 18,
          ),
        ),
        title: Text(
          record.llmComment.isNotEmpty
              ? record.llmComment
              : 'レイアウト #${record.id}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text('$dateStr　スコア: ${(record.score * 100).round()}点'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openDetail(context),
      ),
    );
  }

  void _openDetail(BuildContext context) {
    try {
      final rails = (jsonDecode(record.placedRailsJson) as List<dynamic>)
          .map((e) => PlacedRail.fromJson(e as Map<String, dynamic>))
          .toList();

      final fakeResponse = LayoutResponse(
        layoutId: record.layoutId,
        isSuggestedLayout: !record.isClosed,
        placedRails: rails,
        missingParts: [],
        llmComment: record.llmComment,
        score: record.score,
      );

      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(
              title: const Text('レイアウト詳細'),
              backgroundColor: const Color(0xFF0072BC),
              foregroundColor: Colors.white,
            ),
            body: Center(
              child: LayoutCanvasView(layout: fakeResponse),
            ),
          ),
        ),
      );
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('データの読み込みに失敗しました')),
      );
    }
  }
}
