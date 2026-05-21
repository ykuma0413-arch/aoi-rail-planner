/// ローカルSQLite履歴スキーマ
/// テーブル名: layout_history
class HistoryRecord {
  final int? id;
  final String layoutId;
  final String placedRailsJson;  // JSON文字列
  final String llmComment;
  final double score;
  final bool isClosed;
  final DateTime createdAt;

  const HistoryRecord({
    this.id,
    required this.layoutId,
    required this.placedRailsJson,
    required this.llmComment,
    required this.score,
    required this.isClosed,
    required this.createdAt,
  });

  static const tableName = 'layout_history';

  static const createTableSql = '''
    CREATE TABLE IF NOT EXISTS $tableName (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      layout_id TEXT NOT NULL,
      placed_rails_json TEXT NOT NULL,
      llm_comment TEXT NOT NULL,
      score REAL NOT NULL,
      is_closed INTEGER NOT NULL,
      created_at INTEGER NOT NULL
    )
  ''';

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'layout_id': layoutId,
        'placed_rails_json': placedRailsJson,
        'llm_comment': llmComment,
        'score': score,
        'is_closed': isClosed ? 1 : 0,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory HistoryRecord.fromMap(Map<String, dynamic> m) => HistoryRecord(
        id: m['id'] as int?,
        layoutId: m['layout_id'] as String,
        placedRailsJson: m['placed_rails_json'] as String,
        llmComment: m['llm_comment'] as String,
        score: (m['score'] as num).toDouble(),
        isClosed: (m['is_closed'] as int) == 1,
        createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
      );
}
