import 'package:flutter/material.dart';

import '../core/category_colors.dart';

class AppSettings {
  const AppSettings({
    this.companyName = 'My Inventory',
    this.currency = 'NGN',
    this.themeMode = ThemeMode.system,
    this.companyAddress = '',
    this.companyPhone = '',
    this.companyEmail = '',
    this.taxRate = 0,
    this.taxLabel = 'VAT',
    this.receiptFooter = 'Thank you for your custom.',
    this.companyLogo = '',
    this.bankName = '',
    this.accountName = '',
    this.accountNumber = '',
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

  /// Printed at the head of a receipt, under the workspace name. All optional
  /// — a receipt reads perfectly well with nothing but a name on it.
  final String companyAddress;
  final String companyPhone;
  final String companyEmail;

  /// The rate new receipts default to, as a fraction: 0.075 for 7.5%. Each
  /// receipt freezes its own copy at the moment of issue, so changing this
  /// never rewrites what a customer was already charged.
  final double taxRate;

  /// What that tax is called on the printed document — VAT, GST, Sales Tax.
  final String taxLabel;

  /// The closing line on a printed receipt.
  final String receiptFooter;

  /// The company logo for invoices and receipts: a base64 PNG, or empty for
  /// none.
  ///
  /// Stored inline like item photos, and normalised on the way in — capped at
  /// 512px on its longest edge — because this row is read on every settings
  /// load and a two-megapixel original would be carried on every one of them.
  final String companyLogo;

  bool get hasCompanyLogo => companyLogo.isNotEmpty;

  /// Where a customer pays, printed on invoices and sales orders. Set by an
  /// administrator in Settings → Payment details.
  final String bankName;
  final String accountName;
  final String accountNumber;

  /// Whether there is anything to print: an account number at least.
  bool get hasBankDetails => accountNumber.trim().isNotEmpty;

  /// The payment details as lines, for a document or a message.
  List<String> get bankLines => [
    if (bankName.trim().isNotEmpty) 'Bank: ${bankName.trim()}',
    if (accountName.trim().isNotEmpty) 'Account name: ${accountName.trim()}',
    if (accountNumber.trim().isNotEmpty)
      'Account number: ${accountNumber.trim()}',
  ];
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
    String? companyAddress,
    String? companyPhone,
    String? companyEmail,
    double? taxRate,
    String? taxLabel,
    String? receiptFooter,
    String? companyLogo,
    String? bankName,
    String? accountName,
    String? accountNumber,
    List<String>? categories,
    List<String>? locations,
    List<String>? units,
    Map<String, int>? categoryColors,
  }) {
    return AppSettings(
      companyName: companyName ?? this.companyName,
      currency: currency ?? this.currency,
      themeMode: themeMode ?? this.themeMode,
      companyAddress: companyAddress ?? this.companyAddress,
      companyPhone: companyPhone ?? this.companyPhone,
      companyEmail: companyEmail ?? this.companyEmail,
      taxRate: taxRate ?? this.taxRate,
      taxLabel: taxLabel ?? this.taxLabel,
      receiptFooter: receiptFooter ?? this.receiptFooter,
      // Passing '' is how the logo is removed; there is no separate flag
      // because empty already means "none" everywhere else.
      companyLogo: companyLogo ?? this.companyLogo,
      bankName: bankName ?? this.bankName,
      accountName: accountName ?? this.accountName,
      accountNumber: accountNumber ?? this.accountNumber,
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
    'companyAddress': companyAddress,
    'companyPhone': companyPhone,
    'companyEmail': companyEmail,
    'taxRate': taxRate,
    'taxLabel': taxLabel,
    'receiptFooter': receiptFooter,
    'companyLogo': companyLogo,
    'bankName': bankName,
    'accountName': accountName,
    'accountNumber': accountNumber,
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
      companyAddress: _text(json['companyAddress']),
      companyPhone: _text(json['companyPhone']),
      companyEmail: _text(json['companyEmail']),
      taxRate: json['taxRate'] is num
          ? (json['taxRate'] as num).toDouble().clamp(0, 1).toDouble()
          : 0,
      taxLabel:
          json['taxLabel'] is String && (json['taxLabel'] as String).isNotEmpty
          ? json['taxLabel'] as String
          : 'VAT',
      receiptFooter: json['receiptFooter'] is String
          ? json['receiptFooter'] as String
          : 'Thank you for your custom.',
      companyLogo: _text(json['companyLogo']),
      bankName: _text(json['bankName']),
      accountName: _text(json['accountName']),
      accountNumber: _text(json['accountNumber']),
      categories: _list(json['categories'], defaultCategories),
      locations: _list(json['locations'], defaultLocations),
      units: _list(json['units'], defaultUnits),
      categoryColors: _colors(json['categoryColors']),
    );
  }
}

String _text(Object? value) => value is String ? value : '';

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
