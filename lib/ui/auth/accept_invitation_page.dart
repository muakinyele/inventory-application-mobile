import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/design.dart';
import '../../core/palette.dart';
import '../../data/auth_api.dart';
import '../../state/auth_controller.dart';
import 'auth_scaffold.dart';
import 'password_field.dart';

/// Claiming an invitation (§9).
///
/// The link is looked up first so the page can greet the invitee by name and
/// show which address the account is for — without that, someone forwarded a
/// link has no way to tell what they are about to accept.
class AcceptInvitationPage extends StatefulWidget {
  const AcceptInvitationPage({super.key, required this.token});

  final String? token;

  @override
  State<AcceptInvitationPage> createState() => _AcceptInvitationPageState();
}

class _AcceptInvitationPageState extends State<AcceptInvitationPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _loading = true;
  bool _submitting = false;
  bool _done = false;

  String? _email;
  String? _error;
  List<String> _details = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final token = widget.token;
    if (token == null || token.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'This invitation link is not valid.';
      });
      return;
    }

    try {
      final invitation = await context
          .read<AuthController>()
          .api
          .inspectInvitation(token);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _email = invitation.email;
        _name.text = invitation.name;
      });
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    }
  }

  Future<void> _submit() async {
    final token = widget.token;
    if (token == null) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _submitting = true;
      _error = null;
      _details = const [];
    });

    try {
      await context.read<AuthController>().api.acceptInvitation(
        token: token,
        password: _password.text,
        name: _name.text,
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
    final p = context.palette;

    if (_loading) {
      return const AuthScaffold(
        title: 'Checking your invitation',
        icon: Icons.mail_outline_rounded,
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: Insets.xl),
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    if (_done) {
      return AuthScaffold(
        title: 'Your account is ready',
        icon: Icons.check_circle_rounded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthNotice(
              message: 'You can now sign in with your new password.',
              tone: AuthNoticeTone.success,
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

    // No email means the link never resolved, so there is nothing to accept.
    if (_email == null) {
      return AuthScaffold(
        title: 'This invitation is not valid',
        icon: Icons.link_off_rounded,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AuthNotice(message: _error ?? 'This invitation link is not valid.'),
            const SizedBox(height: Insets.lg),
            const Text(
              'Invitations expire. Ask an administrator to send you a new '
              'one.',
              style: TextStyle(height: 1.5),
            ),
            const SizedBox(height: Insets.xl),
            OutlinedButton(
              onPressed: () => context.go('/login'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('Back to sign in'),
            ),
          ],
        ),
      );
    }

    return AuthScaffold(
      title: 'Set your password',
      subtitle: 'Choose a password to activate your Stockpile account.',
      icon: Icons.person_add_alt_1_rounded,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(Insets.md),
              decoration: BoxDecoration(
                color: p.surfaceSunken,
                borderRadius: BorderRadius.circular(Radii.control),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.alternate_email_rounded,
                    size: 18,
                    color: p.inkMuted,
                  ),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      _email!,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: p.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Insets.lg),

            if (_error != null) ...[
              AuthNotice(message: _error!, details: _details),
              const SizedBox(height: Insets.lg),
            ],

            TextFormField(
              controller: _name,
              enabled: !_submitting,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Your name',
                prefixIcon: Icon(Icons.person_outline_rounded),
              ),
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? 'Enter your name.'
                  : null,
            ),
            const SizedBox(height: Insets.lg),

            PasswordField(
              controller: _password,
              label: 'Choose a password',
              enabled: !_submitting,
              showStrength: true,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.newPassword],
              validator: (value) => (value == null || value.isEmpty)
                  ? 'Choose a password.'
                  : null,
            ),
            const SizedBox(height: Insets.lg),

            PasswordField(
              controller: _confirm,
              label: 'Confirm password',
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
                  : const Text('Activate my account'),
            ),
          ],
        ),
      ),
    );
  }
}
