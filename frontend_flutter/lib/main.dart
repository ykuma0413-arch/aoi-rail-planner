import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'views/age_gate_screen.dart';
import 'views/inventory_screen.dart';

void main() {
  runApp(const ProviderScope(child: AoiRailApp()));
}

class AoiRailApp extends StatelessWidget {
  const AoiRailApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'おまかせAIレールプランナー',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0072BC),
        ),
        useMaterial3: true,
        fontFamily: 'sans-serif',
      ),
      home: const _StartupRouter(),
    );
  }
}

/// 初回起動時にAgeGate、それ以降はInventoryScreenへルーティング
class _StartupRouter extends StatefulWidget {
  const _StartupRouter();

  @override
  State<_StartupRouter> createState() => _StartupRouterState();
}

class _StartupRouterState extends State<_StartupRouter> {
  bool? _ageVerified;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final verified = await AgeGateScreen.isAlreadyVerified();
    if (mounted) setState(() => _ageVerified = verified);
  }

  @override
  Widget build(BuildContext context) {
    if (_ageVerified == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return _ageVerified! ? const InventoryScreen() : const AgeGateScreen();
  }
}
