import 'package:flutter_test/flutter_test.dart';
import 'package:stockpile/core/formatters.dart';
import 'package:stockpile/models/app_settings.dart';

void main() {
  test('the app defaults to Naira', () {
    expect(const AppSettings().currency, 'NGN');
    expect(money(1500, const AppSettings().currency), contains('\u20a6'));
  });

  test('money uses the requested currency, not the device locale', () {
    expect(money(1500, 'NGN'), contains('\u20a6'));
    expect(money(2753.15, 'USD'), contains(r'$'));
    expect(money(2753.15, 'USD'), isNot(contains('\u20a6')));
    expect(money(20, 'GBP'), contains('\u00a3'));
  });

  test('moneyCompact keeps the currency for large amounts', () {
    expect(moneyCompact(1500000, 'NGN'), contains('\u20a6'));
    expect(moneyCompact(1500000, 'USD'), isNot(contains('\u20a6')));
  });

  test('whole amounts drop their trailing zeroes, fractions keep them', () {
    expect(money(1364000, 'NGN'), '\u20a61,364,000');
    expect(money(2500.50, 'NGN'), '\u20a62,500.50');
    expect(money(0, 'NGN'), '\u20a60');
    expect(money(1200, 'USD'), r'$1,200');
    expect(money(12.34, 'USD'), r'$12.34');
  });

  group('parseAmount', () {
    test('accepts an amount typed with separators or a symbol', () {
      expect(parseAmount('1250000'), 1250000);
      expect(parseAmount('1,250,000'), 1250000);
      expect(parseAmount('\u20a61,250,000'), 1250000);
      expect(parseAmount(' 2,500.50 '), 2500.50);
      expect(parseAmount('\u20a6 450'), 450);
    });

    test('puts no ceiling on what can be entered', () {
      expect(parseAmount('999,999,999,999'), 999999999999);
      expect(parseAmount('0.01'), 0.01);
    });

    test('rejects what is not a number, so a validator can say so', () {
      expect(parseAmount('abc'), isNull);
      expect(parseAmount(''), isNull);
      expect(parseAmount('\u20a6'), isNull);
      expect(parseAmount('1.2.3'), isNull);
    });

    test('keeps a negative sign so it can be refused upstream', () {
      expect(parseAmount('-500'), -500);
    });
  });

  test('currencySymbol gives the standalone symbol for a code', () {
    expect(currencySymbol('NGN'), '\u20a6');
    expect(currencySymbol('USD'), r'$');
    expect(currencySymbol('GBP'), '\u00a3');
  });
}
