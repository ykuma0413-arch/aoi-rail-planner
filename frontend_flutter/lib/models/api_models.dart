import 'inventory_item.dart';

// ---- Request ----

class LayoutRequest {
  final List<InventoryItem> inventory;
  final String theme;
  final String sessionId;

  const LayoutRequest({
    required this.inventory,
    required this.theme,
    required this.sessionId,
  });

  Map<String, dynamic> toJson() => {
        'inventory': inventory.map((i) => i.toJson()).toList(),
        'theme': theme,
        'session_id': sessionId,
      };
}

// ---- Response ----

class PlacedRail {
  final String railType;
  final double originX;
  final double originY;
  final double rotation;
  final int zLevel;

  const PlacedRail({
    required this.railType,
    required this.originX,
    required this.originY,
    required this.rotation,
    required this.zLevel,
  });

  factory PlacedRail.fromJson(Map<String, dynamic> j) => PlacedRail(
        railType: j['rail_type'] as String,
        originX: (j['origin_x'] as num).toDouble(),
        originY: (j['origin_y'] as num).toDouble(),
        rotation: (j['rotation'] as num).toDouble(),
        zLevel: (j['z_level'] as num).toInt(),
      );
}

class MissingPart {
  final String railType;
  final int count;
  final String primaryAffiliateUrl;
  final String fallbackSearchUrl;

  const MissingPart({
    required this.railType,
    required this.count,
    required this.primaryAffiliateUrl,
    required this.fallbackSearchUrl,
  });

  factory MissingPart.fromJson(Map<String, dynamic> j) => MissingPart(
        railType: j['rail_type'] as String,
        count: (j['count'] as num).toInt(),
        primaryAffiliateUrl: j['primary_affiliate_url'] as String? ?? '',
        fallbackSearchUrl: j['fallback_search_url'] as String? ?? '',
      );

  /// ASINリンク切れ対策: primaryが空または無効なときfallbackを返す
  String get resolvedUrl =>
      primaryAffiliateUrl.isNotEmpty ? primaryAffiliateUrl : fallbackSearchUrl;
}

class LayoutResponse {
  final String layoutId;
  final bool isSuggestedLayout;
  final List<PlacedRail> placedRails;
  final List<MissingPart> missingParts;
  final String llmComment;
  final double score;

  const LayoutResponse({
    required this.layoutId,
    required this.isSuggestedLayout,
    required this.placedRails,
    required this.missingParts,
    required this.llmComment,
    required this.score,
  });

  factory LayoutResponse.fromJson(Map<String, dynamic> j) => LayoutResponse(
        layoutId: j['layout_id'] as String,
        isSuggestedLayout: j['is_suggested_layout'] as bool? ?? false,
        placedRails: (j['placed_rails'] as List<dynamic>)
            .map((e) => PlacedRail.fromJson(e as Map<String, dynamic>))
            .toList(),
        missingParts: (j['missing_parts'] as List<dynamic>)
            .map((e) => MissingPart.fromJson(e as Map<String, dynamic>))
            .toList(),
        llmComment: j['llm_comment'] as String? ?? '',
        score: (j['score'] as num?)?.toDouble() ?? 0.0,
      );
}

// ---- Remote Config ----

class AppConfig {
  final bool affiliateEnabled;
  final bool videoAdEnabled;
  final int maxInventory;
  final List<String> supportedThemes;

  const AppConfig({
    this.affiliateEnabled = true,
    this.videoAdEnabled = false,
    this.maxInventory = 100,
    this.supportedThemes = const ['standard', 'figure8', 'elevated'],
  });

  factory AppConfig.fromJson(Map<String, dynamic> j) => AppConfig(
        affiliateEnabled: j['affiliate_enabled'] as bool? ?? true,
        videoAdEnabled: j['video_ad_enabled'] as bool? ?? false,
        maxInventory: (j['max_inventory'] as num?)?.toInt() ?? 100,
        supportedThemes:
            (j['supported_themes'] as List<dynamic>?)?.cast<String>() ??
                ['standard', 'figure8', 'elevated'],
      );
}
