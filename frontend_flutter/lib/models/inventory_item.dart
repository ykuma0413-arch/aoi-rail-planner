import 'rail_type.dart';

class InventoryItem {
  final RailType railType;
  final int count;

  const InventoryItem({required this.railType, required this.count});

  InventoryItem copyWith({RailType? railType, int? count}) => InventoryItem(
        railType: railType ?? this.railType,
        count: count ?? this.count,
      );

  Map<String, dynamic> toJson() => {
        'rail_type': railType.apiValue,
        'count': count,
      };
}
