import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'inventory_screen.dart';

const _prefKeyAgeVerified = 'age_verified';

/// コンプライアンス要件: 初回起動時の18歳以上確認画面
/// 本アプリは保護者（大人）が使用することを前提としている。
class AgeGateScreen extends StatelessWidget {
  const AgeGateScreen({super.key});

  static Future<bool> isAlreadyVerified() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefKeyAgeVerified) ?? false;
  }

  Future<void> _onConfirm(BuildContext context) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefKeyAgeVerified, true);
    if (context.mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const InventoryScreen()),
      );
    }
  }

  void _onDecline(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ご確認'),
        content: const Text(
          'このアプリは18歳以上の保護者の方を対象としています。\nご利用いただけません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0072BC),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.train, size: 80, color: Colors.white),
              const SizedBox(height: 24),
              const Text(
                'おまかせAIレールプランナー',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              const Text(
                'このアプリは保護者（大人）が使用することを\n前提としています。\n\n18歳以上の方のみご利用いただけます。',
                style: TextStyle(fontSize: 15, color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: const Color(0xFF0072BC),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () => _onConfirm(context),
                  child: const Text(
                    '18歳以上です',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => _onDecline(context),
                child: const Text(
                  '18歳未満です',
                  style: TextStyle(color: Colors.white60),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
