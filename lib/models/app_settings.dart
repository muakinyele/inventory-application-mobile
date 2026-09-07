import 'package:flutter/material.dart';

import '../core/category_colors.dart';

class AppSettings {
  const AppSettings({
    this.companyName = 'My Inventory',
    this.currency = 'NGN',
    this.themeMode = ThemeMode.system,
    this.categories = defaultCategories,
    this.locations = defaultLocations,
    this.units = defaultUnits,
    this.categoryColors = const {},
  });

  static const defaultCategories = <String>[
    'Electronics',
    'Accessories',
    'Packaging',
    'Office',
    'Raw Materials',
  ];
  static const defaultLocations = <String>[
    'Main Warehouse',
    'Store Front',
    'Van 1',
  ];
  static const defaultUnits = <String>[
    'pcs',
    'box',
    'kg',
    'litre',
    'pack',
    'roll',
  ];

  final String companyName;
  final String currency;
  final ThemeMode themeMode;
  final List<String> categories;
  final List<String> locations;
  final List<String> units;

  /// Explicit swatch choices, keyed by category name. Absent names fall back
  /// to [defaultSwatchIndex], so this only ever holds deliberate overrides and
  /// settings saved before colours existed still load cleanly.
  final Map<String, int> categoryColors;

  int swatchIndexFor(String category) {
    final explicit = categoryColors[category];
    if (explicit != null) return explicit;
    final rank = categories.indexOf(category);
    return defaultSwatchIndex(category, rank: rank < 0 ? 0 : rank);
  }

  Color colorFor(String category) => swatchAt(swatchIndexFor(category));

  AppSettings copyWith({
    String? companyName,
    String? currency,
    ThemeMode? themeMode,
    List<String>? categories,
    List<String>? locations,
    List<String>? units,
    Map<String, int>? categoryColors,
  }) {
    return AppSettings(
      companyName: companyName ?? this.companyName,
      currency: currency ?? this.currency,
      themeMode: themeMode ?? this.themeMode,
      categories: categories ?? this.categories,
      locations: locations ?? this.locations,
      units: units ?? this.units,
      categoryColors: categoryColors ?? this.categoryColors,
    );
  }

  Map<String, dynamic> toJson() => {
    'companyName': companyName,
    'currency': currency,
    'themeMode': themeMode.name,
    'categories': categories,
    'locations': locations,
    'units': units,
    'categoryColors': categoryColors,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      companyName:
          json['companyName'] is String &&
              (json['companyName'] as String).isNotEmpty
          ? json['companyName'] as String
          : 'My Inventory',
      currency: json['currency'] is String ? json['currency'] as String : 'NGN',
      themeMode: ThemeMode.values.firstWhere(
        (m) => m.name == json['themeMode'],
        orElse: () => ThemeMode.system,
      ),
      categories: _list(json['categories'], defaultCategories),
      locations: _list(json['locations'], defaultLocations),
      units: _list(json['units'], defaultUnits),
      categoryColors: _colors(json['categoryColors']),
    );
  }
}

Map<String, int> _colors(Object? value) {
  if (value is! Map) return const {};
  final result = <String, int>{};
  value.forEach((key, raw) {
    if (key is String && raw is int) result[key] = raw;
  });
  return result;
}

List<String> _list(Object? value, List<String> fallback) {
  if (value is List) {
    final strings = value.whereType<String>().toList();
    if (strings.isNotEmpty) return strings;
  }
  return List<String>.from(fallback);
}
