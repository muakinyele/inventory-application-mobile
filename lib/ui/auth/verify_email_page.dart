import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/design.dart';
import '../../data/auth_api.dart';
import '../../state/auth_controller.dart';
import 'auth_scaffold.dart';

/// What a verification link is confirming.
enum VerificationKind {
  /// A new account confirming the address it was created with (§12).
  address,

  /// An existing account moving to a different address (§16).
  change,
}

/// Redeems a verification link (§12, §16).
///
/// Both kinds share this screen because the user's experience is identical —
/// arrive from an email, see whether it worked — and only the endpoint and the
/// wording differ.
class VerifyEmailPage extends StatefulWidget {
  const VerifyEmailPage({
    super.key,
    required this.token,
    this.kind = VerificationKind.address,
  });

  final String? token;
  final VerificationKind kind;

  @override
  State<VerifyEmailPage> createState() => _VerifyEmailPageState();
}

class _VerifyEmailPageState extends State<VerifyEmailPage> {
  bool _working = true;
  bool _verified = false;
  String? _error;

  /// Only offered for a plain address confirmation. An email *change* cannot
  /// be resent from here, because this page has no idea which address the
  /// change was heading to and the account it belongs to is not signed in.
  final _resendEmail = TextEditingController();
  bool _resending = false;
  bool _resent = false;

  @override
  void initState() {
    super.initState();
    _verify();
  }

  @override
  void dispose() {
    _resendEmail.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final token = widget.token;
    if (token == null || token.isEmpty) {
      setState(() {
        _working = false;
        _error = 'This link is not valid. Please request a new one.';
      });
      return;
    }

    final api = context.read<AuthController>().api;
    try {
      if (widget.kind == VerificationKind.change) {
        await api.confirmEmailChange(token);
      } else {
        await api.verifyEmail(token);
      }
      if (!mounted) return;

      // A signed-in user's own record has just changed underneath them, so it
      // is re-read rather than left stale until the next launch.
      await context.read<AuthController>().refreshUser();
      if (!mounted) return;

      setState(() {
        _working = false;
        _verified = true;
      });
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = error.message;
      });
    }
  }

  Future<void> _resend() async {
    if (_resendEmail.text.trim().isEmpty) return;
    setState(() => _resending = true);

    try {
      await context.read<AuthController>().api.resendVerification(
        _resendEmail.text.trim(),
      );
    } on AuthApiException {
      // Answers the same either way, so there is nothing to distinguish.
    }
    if (!mounted) return;
    setState(() {
      _resending = false;
      _resent = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isChange = widget.kind == VerificationKind.change;

    if (_working) {
      return AuthScaffold(
        title: isChange
            ? 'Confirming your new address'
            : 'Confirming your email address',
        icon: Icons.mark_email_read_rounded,
        child: const Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: Insets.xl),
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    if (_verified) {
      final signedIn = context.read<AuthController>().isAuthenticated;
      return AuthScaffold(
        title: isChange ? 'Email address updated' : 'Email address confirmed',
        icon: Icons.check_circle_rounded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AuthNotice(
              message: isChange
                  ? 'Your account now uses this email address.'
                  : 'Thanks — your email address is confirmed.',
              tone: AuthNoticeTone.success,
            ),
            const SizedBox(height: Insets.xl),
            FilledButton(
              onPressed: () => context.go(signedIn ? '/' : '/login'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: Text(signedIn ? 'Back to Stockpile' : 'Sign in'),
            ),
          ],
        ),
      );
    }

    return AuthScaffold(
      title: 'This link did not work',
      icon: Icons.link_off_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AuthNotice(message: _error ?? 'This link is not valid.'),
          const SizedBox(height: Insets.lg),

          if (isChange) ...[
            const Text(
              'Your account still uses its previous email address. Start the '
              'change again from your security settings.',
              style: TextStyle(height: 1.5),
            ),
            const SizedBox(height: Insets.xl),
            FilledButton(
              onPressed: () => context.go('/login'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Back to sign in'),
            ),
          ] else if (_resent) ...[
            const AuthNotice(
              message:
                  'If that address needs confirming, a new link is on its way.',
              tone: AuthNoticeTone.success,
            ),
            const SizedBox(height: Insets.xl),
            OutlinedButton(
              onPressed: () => context.go('/login'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Back to sign in'),
            ),
          ] else ...[
            const Text(
              'Confirmation links expire. Enter your address and we will send '
              'a new one.',
              style: TextStyle(height: 1.5),
            ),
            const SizedBox(height: Insets.lg),
            TextField(
              controller: _resendEmail,
              keyboardType: TextInputType.emailAddress,
              enabled: !_resending,
              onSubmitted: (_) => _resend(),
              decoration: const InputDecoration(
                labelText: 'Email address',
                prefixIcon: Icon(Icons.alternate_email_rounded),
              ),
            ),
            const SizedBox(height: Insets.lg),
            FilledButton(
              onPressed: _resending ? null : _resend,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: _resending
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : const Text('Send a new link'),
            ),
            const SizedBox(height: Insets.sm),
            TextButton(
              onPressed: () => context.go('/login'),
              child: const Text('Back to sign in'),
            ),
          ],
        ],
      ),
    );
  }
}
