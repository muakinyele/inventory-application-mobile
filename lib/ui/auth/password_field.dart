// Material ships its own `Durations`, which would shadow the project's design
// token of the same name. The project's scale is the one the rest of the app
// animates on, so Material's is hidden rather than the token aliased.
import 'package:flutter/material.dart' hide Durations;

import '../../core/design.dart';
import '../../core/palette.dart';

/// A password input with a show/hide toggle (§2).
///
/// The toggle is a real affordance rather than a nicety: on a phone keyboard,
/// being unable to see what you typed is the most common reason a correct
/// password gets entered wrongly three times and locks the account.
class PasswordField extends StatefulWidget {
  const PasswordField({
    super.key,
    required this.controller,
    this.label = 'Password',
    this.hint,
    this.textInputAction = TextInputAction.done,
    this.onSubmitted,
    this.autofocus = false,
    this.enabled = true,
    this.validator,
    this.showStrength = false,
    this.autofillHints,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final TextInputAction textInputAction;
  final VoidCallback? onSubmitted;
  final bool autofocus;
  final bool enabled;
  final String? Function(String?)? validator;

  /// Shows the meter and the requirement line. On for choosing a password,
  /// off for entering an existing one — where scoring what someone already
  /// has is noise.
  final bool showStrength;

  final Iterable<String>? autofillHints;

  @override
  State<PasswordField> createState() => _PasswordFieldState();
}

class _PasswordFieldState extends State<PasswordField> {
  bool _obscured = true;

  @override
  void initState() {
    super.initState();
    if (widget.showStrength) {
      widget.controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    if (widget.showStrength) {
      widget.controller.removeListener(_onChanged);
    }
    super.dispose();
  }

  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: widget.controller,
          obscureText: _obscured,
          enabled: widget.enabled,
          autofocus: widget.autofocus,
          textInputAction: widget.textInputAction,
          autofillHints: widget.autofillHints,
          onFieldSubmitted: (_) => widget.onSubmitted?.call(),
          validator: widget.validator,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            suffixIcon: IconButton(
              onPressed: () => setState(() => _obscured = !_obscured),
              icon: Icon(
                _obscured
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
              ),
              tooltip: _obscured ? 'Show password' : 'Hide password',
            ),
          ),
        ),
        if (widget.showStrength) ...[
          const SizedBox(height: Insets.sm),
          PasswordStrengthMeter(password: widget.controller.text),
        ],
      ],
    );
  }
}

/// The four-segment strength meter (§11).
///
/// Advisory only. The server decides whether a password is acceptable, and it
/// does so on length and a blocklist — not on this score. Showing a score the
/// form then enforced would be a second, hidden rule.
class PasswordStrengthMeter extends StatelessWidget {
  const PasswordStrengthMeter({super.key, required this.password});

  final String password;

  /// Mirrors the server's `PasswordPolicy._score`, so the meter and the
  /// server's judgement do not contradict each other.
  static int score(String password) {
    if (password.length < minPasswordLength) return 0;
    if (_commonPasswords.contains(password.toLowerCase())) return 0;

    var variety = 0;
    if (RegExp(r'[a-z]').hasMatch(password)) variety++;
    if (RegExp(r'[A-Z]').hasMatch(password)) variety++;
    if (RegExp(r'[0-9]').hasMatch(password)) variety++;
    if (RegExp(r'[^A-Za-z0-9]').hasMatch(password)) variety++;

    var value = 1;
    if (password.length >= 12) value++;
    if (password.length >= 16) value++;
    // Length or variety, never variety alone — a long lowercase passphrase is
    // stronger than a short one with a symbol wedged into it.
    if (password.length >= 20 || variety >= 3) value++;
    if (_isRepeatedOrSequential(password.toLowerCase())) value--;

    return value.clamp(0, 4);
  }

  static bool _isRepeatedOrSequential(String value) {
    if (value.length < 4) return false;
    if (RegExp(r'(.)\1{3,}').hasMatch(value)) return true;
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

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final value = score(password);
    final empty = password.isEmpty;

    final (label, colour) = switch (value) {
      0 => ('Too weak', p.critical),
      1 => ('Weak', p.critical),
      2 => ('Fair', p.warningText),
      3 => ('Good', p.info),
      _ => ('Strong', p.goodText),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            for (var segment = 0; segment < 4; segment++) ...[
              if (segment > 0) const SizedBox(width: Insets.xs),
              Expanded(
                child: AnimatedContainer(
                  duration: Durations.fast,
                  height: 4,
                  decoration: BoxDecoration(
                    color: !empty && segment < value ? colour : p.line,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: Insets.xs),
        Row(
          children: [
            Expanded(
              child: Text(
                // The rule, not the score, is what actually gates submission,
                // so it is stated plainly rather than left to be inferred.
                'At least $minPasswordLength characters. A few unrelated words '
                'works well.',
                style: TextStyle(fontSize: 12, color: p.inkMuted, height: 1.4),
              ),
            ),
            if (!empty) ...[
              const SizedBox(width: Insets.sm),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  color: colour,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// Matches the server's `minPasswordLength`.
const int minPasswordLength = 10;

/// A short mirror of the server's blocklist, so the meter does not call a
/// password "Strong" that the server is about to reject outright. The server
/// holds the full list and remains the authority.
const Set<String> _commonPasswords = {
  'password',
  'password1',
  'password123',
  'passw0rd',
  'p@ssw0rd',
  'qwerty',
  'qwerty123',
  'qwertyuiop',
  'abc123',
  'iloveyou',
  'admin',
  'welcome1',
  'welcome123',
  'letmein123',
  'monkey',
  'dragon',
  'football',
  'baseball',
  'sunshine',
  'princess',
  'trustno1',
  'starwars',
  'superman',
  '1234567890',
  '123456789',
  'changeme',
  'inventory',
  'inventory123',
  'stockpile',
  'stockpile123',
  'warehouse',
  'user123',
  'test123',
};
