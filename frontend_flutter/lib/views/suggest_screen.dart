import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/api_models.dart';

/// 工事中画面（サジェスト画面）
/// is_suggested_layout: true またはタイムアウトフォールバック時にナビゲーション。
class SuggestScreen extends StatelessWidget {
  final LayoutResponse? response;
  final String? errorMessage;

  const SuggestScreen({super.key, this.response, this.errorMessage});

  @override
  Widget build(BuildContext context) {
    final missing = response?.missingParts ?? [];

    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      appBar: AppBar(
        title: const Text('もう少しパーツが必要です'),
        backgroundColor: const Color(0xFF0072BC),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 工事中アイコン
            Center(
              child: Column(
                children: [
                  const Text('🚧', style: TextStyle(fontSize: 64)),
                  const SizedBox(height: 8),
                  const Text(
                    '工事中...',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0072BC),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // LLMコメント or エラーメッセージ
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4)],
              ),
              child: Text(
                response?.llmComment ??
                    errorMessage ??
                    'もう少しパーツを追加するとレイアウトが完成します！',
                style: const TextStyle(fontSize: 16, height: 1.5),
                textAlign: TextAlign.center,
              ),
            ),
            if (missing.isNotEmpty) ...[
              const SizedBox(height: 24),
              const Text(
                '不足パーツ',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF0072BC),
                ),
              ),
              const SizedBox(height: 12),
              ...missing.map((part) => _MissingPartCard(part: part)),
            ],
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.arrow_back),
                label: const Text('在庫画面に戻る'),
                onPressed: () => Navigator.of(context).popUntil(
                  (route) => route.isFirst,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MissingPartCard extends StatelessWidget {
  final MissingPart part;

  const _MissingPartCard({required this.part});

  Future<void> _openUrl() async {
    final url = Uri.parse(part.resolvedUrl);
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      // フォールバックURLが開けない場合はサイレント処理
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0xFFFF0000).withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Icon(Icons.train, color: Color(0xFFFF0000)),
        ),
        title: Text(
          part.railType.replaceAll('_', ' '),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text('あと ${part.count} 個'),
        trailing: part.resolvedUrl.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.shopping_cart,
                    color: Color(0xFF0072BC)),
                onPressed: _openUrl,
                tooltip: '購入する',
              )
            : null,
      ),
    );
  }
}
