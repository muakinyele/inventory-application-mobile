import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/design.dart';
import '../../data/auth_api.dart';
import '../../state/auth_controller.dart';
import 'auth_scaffold.dart';

/// Step one of the reset flow (§10).
///
/// The response never differs by whether the address is registered, so this
/// screen shows the same confirmation either way — the endpoint would
/// otherwise be a free way to discover who has an account.
class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();

  bool _submitting = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await context.read<AuthController>().api.forgotPassword(
        _email.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _sent = true;
      });
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        // Only a transport or throttling failure can land here; the endpoint
        // itself always succeeds.
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sent) {
      return AuthScaffold(
        title: 'Check your email',
        icon: Icons.mark_email_read_rounded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthNotice(
              message:
                  'If an account exists for this email address, password '
                  'reset instructions have been sent.',
              tone: AuthNoticeTone.success,
            ),
            const SizedBox(height: Insets.lg),
            Text(
              'The link can be used once and expires within the hour. Check '
              'your spam folder if it has not arrived in a few minutes.',
              style: TextStyle(
                height: 1.5,
                color: Theme.of(context).textTheme.bodySmall?.color,
              ),
            ),
            const SizedBox(height: Insets.xl),
            FilledButton(
              onPressed: () => context.go('/login'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Back to sign in'),
            ),
          ],
        ),
      );
    }

    return AuthScaffold(
      title: 'Reset your password',
      subtitle:
          'Enter the address you sign in with and we will send you a link to '
          'choose a new password.',
      icon: Icons.lock_reset_rounded,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              AuthNotice(message: _error!),
              const SizedBox(height: Insets.lg),
            ],
            TextFormField(
              controller: _email,
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              enabled: !_submitting,
              onFieldSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Email address',
                prefixIcon: Icon(Icons.alternate_email_rounded),
              ),
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? 'Enter your email address.'
                  : null,
            ),
            const SizedBox(height: Insets.xl),
            FilledButton(
              onPressed: _submitting ? null : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    )
                  : const Text('Send reset link'),
            ),
            const SizedBox(height: Insets.sm),
            TextButton(
              onPressed: _submitting ? null : () => context.go('/login'),
              child: const Text('Back to sign in'),
            ),
          ],
        ),
      ),
    );
  }
}
