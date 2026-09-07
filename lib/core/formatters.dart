import 'package:intl/intl.dart';

final _currencyCache = <String, NumberFormat>{};
final _wholeCurrencyCache = <String, NumberFormat>{};
final _compactCache = <String, NumberFormat>{};

NumberFormat _currencyFormat(String code) {
  return _currencyCache.putIfAbsent(
    code,
    () => NumberFormat.simpleCurrency(name: code),
  );
}

/// The symbol the app renders for a currency code — "₦" for NGN, "$" for USD.
/// Used where the symbol stands alone, such as a stat card's tile.
String currencySymbol(String code) => _currencyFormat(code).currencySymbol;

/// Trailing zeroes are dropped for whole amounts: prices here are usually
/// round numbers, and "₦1,364,000" reads far better than "₦1,364,000.00" —
/// while a genuine ₦2,500.50 still keeps its kobo.
/// Reads an amount the way a person types it: grouping separators, a currency
/// symbol and surrounding space are all accepted, so "₦1,250,000" and
/// "1250000" both land on the same number. Returns null when what remains is
/// not a number, which lets a validator tell nonsense from an empty field.
///
/// Deliberately unbounded — an inventory can hold anything from a ₦450 box to
/// a multi-million-naira machine.
double? parseAmount(String input) {
  final cleaned = input.trim().replaceAll(RegExp(r'[^0-9.\-]'), '');
  if (cleaned.isEmpty) return null;
  return double.tryParse(cleaned);
}

String money(num value, String currency) {
  if (value == value.roundToDouble()) {
    final fmt = _wholeCurrencyCache.putIfAbsent(currency, () {
      try {
        return NumberFormat.simpleCurrency(name: currency, decimalDigits: 0);
      } on Exception {
        return _currencyFormat(currency);
      }
    });
    return fmt.format(value);
  }
  return _currencyFormat(currency).format(value);
}

/// Compact form for dashboard tiles, where the box is narrow.
String moneyCompact(num value, String currency) {
  if (value.abs() < 10000) return money(value, currency);
  final fmt = _compactCache.putIfAbsent(
    currency,
    () => NumberFormat.compactSimpleCurrency(name: currency),
  );
  return fmt.format(value);
}

final _decimal = NumberFormat.decimalPattern();

String number(num value) => _decimal.format(value);

/// Axis-tick sized numbers: 1.2k rather than 1,200.
String compactNumber(num value) => NumberFormat.compact().format(value);

String shortDay(DateTime at) => DateFormat('d MMM').format(at);

String signed(int value) => value > 0 ? '+${number(value)}' : number(value);

String relativeTime(DateTime at) {
  final seconds = DateTime.now().difference(at).inSeconds;
  if (seconds < 60) return 'just now';
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '${minutes}m ago';
  final hours = (minutes / 60).round();
  if (hours < 24) return '${hours}h ago';
  final days = (hours / 24).round();
  if (days < 7) return '${days}d ago';
  return DateFormat.MMMd().format(at);
}

String longDate(DateTime at) => DateFormat('EEEE, MMMM d').format(at);

String dateTimeLabel(DateTime at) => DateFormat.MMMd().add_jm().format(at);

String dayLabel(DateTime at) {
  final now = DateTime.now();
  bool sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
  if (sameDay(at, now)) return 'Today';
  if (sameDay(at, now.subtract(const Duration(days: 1)))) return 'Yesterday';
  return DateFormat.MMMEd().format(at);
}

String initials(String name) {
  final words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return '?';
  if (words.length == 1) {
    return words.first
        .substring(0, words.first.length.clamp(0, 2))
        .toUpperCase();
  }
  return (words[0][0] + words[1][0]).toUpperCase();
}
