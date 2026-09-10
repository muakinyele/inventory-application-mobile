import 'passwords.dart';

/// The result of checking a candidate password.
class PasswordCheck {
  const PasswordCheck({required this.problems, required this.strength});

  /// Human-readable, already phrased for display. Empty means acceptable.
  final List<String> problems;

  /// 0 (unusable) to 4 (strong), for the strength meter (§11). Advisory only —
  /// a password is accepted on [problems] being empty, not on its score, so
  /// the meter can never become a hidden extra rule.
  final int strength;

  bool get isAcceptable => problems.isEmpty;
}

/// Checks passwords against a deliberately short list of rules.
///
/// Modern guidance (NIST SP 800-63B) is that composition rules — one capital,
/// one digit, one symbol — push people toward `Password1!` and measurably
/// weaken the result. So length and a blocklist do the work here, and there
/// are no character-class requirements at all.
class PasswordPolicy {
  const PasswordPolicy();

  PasswordCheck check(
    String password, {
    String? email,
    String? name,
    String? appName,
  }) {
    final problems = <String>[];

    if (password.length < minPasswordLength) {
      problems.add(
        'Use at least $minPasswordLength characters '
        '(this one has ${password.length}).',
      );
    }
    if (password.length > maxPasswordLength) {
      problems.add('Use at most $maxPasswordLength characters.');
    }
    if (password.trim().isEmpty) {
      problems.add('Enter a password.');
    }

    final lower = password.toLowerCase();

    if (_commonPasswords.contains(lower)) {
      problems.add(
        'This is one of the most commonly used passwords. Choose something '
        'less predictable.',
      );
    }
    if (_isRepeatedOrSequential(lower)) {
      problems.add(
        'Avoid repeated or sequential characters like "aaaa" or '
        '"12345".',
      );
    }

    // Anything derived from the account itself is the first thing an attacker
    // tries, so it is rejected however long it is.
    final localPart = email?.split('@').first.toLowerCase();
    for (final personal in [
      localPart,
      name?.toLowerCase(),
      appName?.toLowerCase(),
    ]) {
      if (personal != null &&
          personal.length >= 4 &&
          lower.contains(personal)) {
        problems.add(
          'Do not include your name, email address or the app name.',
        );
        break;
      }
    }

    return PasswordCheck(
      problems: List.unmodifiable(problems),
      strength: _score(password),
    );
  }

  /// A coarse estimate of variety and length. Not entropy — it never claims
  /// to be — just enough to drive a four-segment meter.
  int _score(String password) {
    if (password.length < minPasswordLength) return 0;
    if (_commonPasswords.contains(password.toLowerCase())) return 0;

    var variety = 0;
    if (RegExp(r'[a-z]').hasMatch(password)) variety++;
    if (RegExp(r'[A-Z]').hasMatch(password)) variety++;
    if (RegExp(r'[0-9]').hasMatch(password)) variety++;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(password)) variety++;

    var score = 1;
    if (password.length >= 12) score++;
    if (password.length >= 16) score++;
    // Length *or* variety earns the top point, never variety alone. A long
    // passphrase of nothing but lowercase words is stronger than a short
    // string with a capital and a symbol in it, and a meter that said
    // otherwise would push people toward exactly the passwords the rules
    // above exist to discourage.
    if (password.length >= 20 || variety >= 3) score++;
    if (_isRepeatedOrSequential(password.toLowerCase())) score--;

    return score.clamp(0, 4);
  }

  static bool _isRepeatedOrSequential(String value) {
    if (value.length < 4) return false;
    // Four or more of the same character.
    if (RegExp(r'(.)\1{3,}').hasMatch(value)) return true;
    // Five or more consecutive code units in either direction, which covers
    // "12345" and "abcde" without needing a keyboard-layout table.
    var ascending = 1;
    var descending = 1;
    for (var i = 1; i < value.length; i++) {
      final delta = value.codeUnitAt(i) - value.codeUnitAt(i - 1);
      ascending = delta == 1 ? ascending + 1 : 1;
      descending = delta == -1 ? descending + 1 : 1;
      if (ascending >= 5 || descending >= 5) return true;
    }
    return false;
  }
}

/// The passwords that show up first in every credential-stuffing list.
///
/// Intentionally small and in-process: a full breach corpus belongs behind a
/// k-anonymity API such as Have I Been Pwned, which is the documented upgrade
/// path. This list costs nothing and stops the worst choices.
const Set<String> _commonPasswords = {
  '123456',
  '123456789',
  '12345678',
  '12345',
  '1234567',
  '1234567890',
  'password',
  'password1',
  'password123',
  'passw0rd',
  'p@ssw0rd',
  'p@ssword',
  'qwerty',
  'qwerty123',
  'qwertyuiop',
  'abc123',
  'iloveyou',
  'admin',
  'administrator',
  'welcome',
  'welcome1',
  'welcome123',
  'monkey',
  'dragon',
  'letmein',
  'letmein123',
  'football',
  'baseball',
  'sunshine',
  'princess',
  'trustno1',
  'starwars',
  'whatever',
  'superman',
  'batman',
  'master',
  'shadow',
  'michael',
  'jennifer',
  'jordan',
  'harley',
  'ranger',
  'hunter',
  'buster',
  'soccer',
  'hockey',
  'killer',
  'george',
  'charlie',
  'andrew',
  'thomas',
  'robert',
  'daniel',
  'matthew',
  'joshua',
  'access',
  'flower',
  'freedom',
  'ginger',
  'summer',
  'winter',
  'autumn',
  'spring',
  'chelsea',
  'liverpool',
  'arsenal',
  'chocolate',
  'computer',
  'internet',
  'samsung',
  'google',
  'facebook',
  'linkedin',
  'secret',
  'secret123',
  'changeme',
  'default',
  'guest',
  'test',
  'test123',
  'testing',
  'temp',
  'temporary',
  'qazwsx',
  'zaq12wsx',
  '1q2w3e4r',
  '1qaz2wsx',
  'asdfgh',
  'asdfghjkl',
  'zxcvbnm',
  '000000',
  '111111',
  '121212',
  '123123',
  '654321',
  '666666',
  '696969',
  '888888',
  '987654321',
  '11111111',
  '00000000',
  'aaaaaa',
  'abcdef',
  'abcdefg',
  'abcd1234',
  'a1b2c3d4',
  'passpass',
  'pass123',
  'login',
  'login123',
  'root',
  'toor',
  'oracle',
  'postgres',
  'mysql',
  'inventory',
  'inventory123',
  'stockpile',
  'stockpile123',
  'warehouse',
  'stock123',
  'company',
  'business',
  'manager',
  'supervisor',
  'employee',
  'trustme',
  'nopassword',
  'nothing',
  'unknown',
  'user',
  'user123',
};
