import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/design.dart';
import '../../data/auth_api.dart';
import '../../state/auth_controller.dart';
import 'auth_scaffold.dart';
import 'password_field.dart';

/// Step two of the reset flow, reached from the emailed link (§10).
class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({super.key, required this.token});

  final String? token;

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _submitting = false;
  bool _done = false;
  String? _error;
  List<String> _details = const [];

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final token = widget.token;
    if (token == null || token.isEmpty) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _submitting = true;
      _error = null;
      _details = const [];
    });

    try {
      await context.read<AuthController>().api.resetPassword(
        token: token,
        password: _password.text,
      );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _done = true;
      });
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = error.message;
        _details = error.details;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final token = widget.token;

    if (token == null || token.isEmpty) {
      return AuthScaffold(
        title: 'This link is not valid',
        icon: Icons.link_off_rounded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthNotice(
              message:
                  'This password reset link is not valid. Please request a '
                  'new one.',
            ),
            const SizedBox(height: Insets.xl),
            FilledButton(
              onPressed: () => context.go('/forgot-password'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Request a new link'),
            ),
          ],
        ),
      );
    }

    if (_done) {
      return AuthScaffold(
        title: 'Password changed',
        icon: Icons.check_circle_rounded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthNotice(
              message: 'You can now sign in with your new password.',
              tone: AuthNoticeTone.success,
            ),
            const SizedBox(height: Insets.lg),
            const Text(
              'Every device that was signed in to your account has been '
              'signed out.',
              style: TextStyle(height: 1.5),
            ),
            const SizedBox(height: Insets.xl),
            FilledButton(
              onPressed: () => context.go('/login'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Sign in'),
            ),
          ],
        ),
      );
    }

    // An expired or already-used link cannot be recovered by retyping, so the
    // form is replaced by the one action that helps.
    final linkDead = _error != null && _details.isEmpty && _isLinkError;

    return AuthScaffold(
      title: 'Choose a new password',
      subtitle: linkDead
          ? null
          : 'Pick something you have not used here before.',
      icon: Icons.lock_reset_rounded,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              AuthNotice(message: _error!, details: _details),
              const SizedBox(height: Insets.lg),
            ],

            if (linkDead)
              FilledButton(
                onPressed: () => context.go('/forgot-password'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: const Text('Request a new link'),
              )
            else ...[
              PasswordField(
                controller: _password,
                label: 'New password',
                autofocus: true,
                enabled: !_submitting,
                showStrength: true,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.newPassword],
                validator: (value) => (value == null || value.isEmpty)
                    ? 'Enter a new password.'
                    : null,
              ),
              const SizedBox(height: Insets.lg),
              PasswordField(
                controller: _confirm,
                label: 'Confirm new password',
                enabled: !_submitting,
                onSubmitted: _submit,
                validator: (value) => value != _password.text
                    ? 'The passwords do not match.'
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
                    : const Text('Change password'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  bool get _isLinkError {
    final message = _error ?? '';
    return message.contains('expired') ||
        message.contains('already been used') ||
        message.contains('not valid');
  }
}
