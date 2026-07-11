import 'package:flutter/material.dart';
import '../models/api_models.dart';
import '../models/rail_type.dart';
import 'layout_canvas_view.dart';
import 'widgets/mini_rail_icon.dart';

/// じゅんばんに組み立てるモード
/// 本線はチェーン順（エンジンの出力順 = 実際に繋がる順）で1ピースずつ
/// ハイライトする。側線（スパー）のチェーン先頭ピースだけは本線の直前
/// ピースには繋がらないため、attachIndex を使って正しい分岐元を案内する。
class AssemblyScreen extends StatefulWidget {
  final LayoutResponse layout;

  const AssemblyScreen({super.key, required this.layout});

  @override
  State<AssemblyScreen> createState() => _AssemblyScreenState();
}

class _AssemblyScreenState extends State<AssemblyScreen> {
  int _step = 0; // 配置済みピース数（次に置くのは index == _step）

  int get _total => widget.layout.placedRails.length;
  bool get _isDone => _step >= _total;

  PlacedRail? get _currentPiece =>
      _isDone ? null : widget.layout.placedRails[_step];

  void _next() {
    if (_isDone) return;
    setState(() => _step++);
  }

  void _prev() {
    if (_step <= 0) return;
    setState(() => _step--);
  }

  String _instructionFor(PlacedRail piece) {
    final rt = RailType.fromApiValue(piece.railType);
    final name = rt?.displayName ?? piece.railType;
    if (rt == RailType.bridgePierStandard || rt == RailType.bridgePierBlock) {
      return '$name を おこう！';
    }
    // 側線（スパー）チェーンの先頭ピースは、本線の直前ピースではなく
    // attachIndex が指すポイントレールの分岐から繋がる。
    if (piece.spur && piece.attachIndex != null) {
      final anchor = widget.layout.placedRails[piece.attachIndex!];
      final anchorRt = RailType.fromApiValue(anchor.railType);
      final anchorName = anchorRt?.displayName ?? anchor.railType;
      return '${piece.attachIndex! + 1}番目の $anchorName の\n枝分かれから $name をつなげよう！（本線とはべつだよ）';
    }
    if (_step == 0) {
      return 'さいしょの $name を おこう！';
    }
    if (rt == RailType.curveR || rt == RailType.curveRLarge) {
      final side = piece.flipped ? 'みぎ' : 'ひだり';
      return '$name を $sideまわりに つなげよう！';
    }
    return '$name を つなげよう！';
  }

  @override
  Widget build(BuildContext context) {
    final piece = _currentPiece;
    final rt = piece != null ? RailType.fromApiValue(piece.railType) : null;

    return Scaffold(
      backgroundColor: const Color(0xFFF7FAFD),
      appBar: AppBar(
        title: const Text('🔧 じゅんばんに くみたて'),
        backgroundColor: const Color(0xFF0072BC),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // 進捗バー
          LinearProgressIndicator(
            value: _total == 0 ? 0 : _step / _total,
            minHeight: 8,
            backgroundColor: const Color(0xFF0072BC).withOpacity(0.12),
            valueColor:
                const AlwaysStoppedAnimation<Color>(Color(0xFFFF8F00)),
          ),
          // キャンバス（_step 個まで配置済み + 次のピースが明滅）
          Expanded(
            child: LayoutCanvasView(
              layout: widget.layout,
              assemblyStep: _step,
              showTrain: false,
            ),
          ),
          // ガイドパネル
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            decoration: const BoxDecoration(
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 8)],
            ),
            child: _isDone ? _buildDonePanel() : _buildStepPanel(piece!, rt),
          ),
        ],
      ),
    );
  }

  Widget _buildStepPanel(PlacedRail piece, RailType? rt) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            // 今置くピースのアイコン
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: const Color(0xFFFF8F00).withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFFF8F00), width: 1.5),
              ),
              child: rt != null
                  ? MiniRailIcon(railType: rt, size: 46)
                  : const SizedBox(width: 46, height: 46),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${_step + 1} / $_total',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.black54,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _instructionFor(piece),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF004B87),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.undo, size: 20),
                label: const Text('まえへ'),
                onPressed: _step > 0 ? _prev : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFF8F00),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.check, size: 22),
                label: Text(
                  _step == _total - 1 ? 'さいごの1本！' : 'つなげた！つぎへ',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
                onPressed: _next,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildDonePanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('🎉', style: TextStyle(fontSize: 40)),
        const SizedBox(height: 4),
        const Text(
          'ぜんぶ つながったね！',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Color(0xFF004B87),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'でんしゃを はしらせて あそぼう！',
          style: TextStyle(fontSize: 13, color: Colors.black54),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => setState(() => _step = 0),
                child: const Text('もういちど'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0072BC),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.train, size: 22),
                label: const Text(
                  'コースにもどる',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
