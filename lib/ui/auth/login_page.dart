import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/design.dart';
import '../../core/palette.dart';
import '../../data/auth_api.dart';
import '../../state/auth_controller.dart';
import 'auth_scaffold.dart';
import 'password_field.dart';

/// The sign-in screen (§2).
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _rememberMe = true;
  bool _submitting = false;

  String? _error;
  List<String> _errorDetails = const [];

  /// Set when the server said the address is unconfirmed, so the "resend"
  /// affordance appears only when it is actually the problem.
  bool _offerResend = false;
  bool _resent = false;

  @override
  void initState() {
    super.initState();
    // A session that ended by itself explains why the user is looking at this
    // screen, rather than leaving them to guess.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final reason = context.read<AuthController>().endedReason;
      if (reason != null && mounted) {
        setState(() => _error = reason);
        context.read<AuthController>().acknowledgeEndedReason();
      }
    });
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() {
      _submitting = true;
      _error = null;
      _errorDetails = const [];
      _offerResend = false;
      _resent = false;
    });

    final auth = context.read<AuthController>();
    try {
      await auth.signIn(
        email: _email.text.trim(),
        password: _password.text,
        rememberMe: _rememberMe,
      );
      // The router's redirect takes it from here; nothing to navigate to by
      // hand, which keeps one source of truth for where a signed-in user goes.
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = error.message;
        _errorDetails = error.details;
        _offerResend = error.code == 'email_unverified';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = 'Something went wrong. Please try again.';
      });
    }
  }

  Future<void> _resendVerification() async {
    final auth = context.read<AuthController>();
    try {
      await auth.api.resendVerification(_email.text.trim());
    } on AuthApiException {
      // The endpoint answers the same way whether or not the address exists,
      // so there is nothing meaningful to report on a failure either.
    }
    if (!mounted) return;
    setState(() => _resent = true);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return AuthScaffold(
      title: 'Sign in',
      subtitle: 'Enter your details to reach your workspace.',
      footer: const Text('Ask an administrator if you need an account.'),
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                AuthNotice(
                  message: _error!,
                  details: _errorDetails,
                  action: _offerResend && !_resent
                      ? TextButton(
                          onPressed: _resendVerification,
                          style: TextButton.styleFrom(
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Send me a new link'),
                        )
                      : null,
                ),
                const SizedBox(height: Insets.lg),
              ],
              if (_resent) ...[
                const AuthNotice(
                  message:
                      'If that address needs confirming, a new link is on its '
                      'way.',
                  tone: AuthNoticeTone.success,
                ),
                const SizedBox(height: Insets.lg),
              ],

              TextFormField(
                controller: _email,
                autofocus: true,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.username],
                enabled: !_submitting,
                decoration: const InputDecoration(
                  labelText: 'Email address',
                  prefixIcon: Icon(Icons.alternate_email_rounded),
                ),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Enter your email address.'
                    : null,
              ),
              const SizedBox(height: Insets.lg),

              PasswordField(
                controller: _password,
                enabled: !_submitting,
                autofillHints: const [AutofillHints.password],
                onSubmitted: _submit,
                validator: (value) => (value == null || value.isEmpty)
                    ? 'Enter your password.'
                    : null,
              ),
              const SizedBox(height: Insets.sm),

              Row(
                children: [
                  Expanded(
                    child: InkWell(
                      onTap: _submitting
                          ? null
                          : () => setState(() => _rememberMe = !_rememberMe),
                      borderRadius: BorderRadius.circular(Radii.control),
                      child: Row(
                        children: [
                          Checkbox(
                            value: _rememberMe,
                            onChanged: _submitting
                                ? null
                                : (value) => setState(
                                    () => _rememberMe = value ?? false,
                                  ),
                          ),
                          Flexible(
                            child: Text(
                              'Remember me',
                              style: TextStyle(color: p.inkSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => context.push('/forgot-password'),
                    child: const Text('Forgot password?'),
                  ),
                ],
              ),
              const SizedBox(height: Insets.md),

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
                    : const Text('Sign in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
