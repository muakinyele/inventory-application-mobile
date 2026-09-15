import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design.dart';
import '../../core/formatters.dart';
import '../../core/palette.dart';
import '../../data/auth_api.dart';
import '../../models/auth_user.dart';
import '../../state/auth_controller.dart';
import '../auth/auth_scaffold.dart';
import '../auth/password_field.dart';
import '../widgets/app_message.dart';
import '../widgets/page_header.dart';
import '../widgets/section_card.dart';
import '../widgets/confirm_dialog.dart';

/// Everything about how the account is secured (§17, §18).
class SecurityPage extends StatefulWidget {
  const SecurityPage({super.key});

  @override
  State<SecurityPage> createState() => _SecurityPageState();
}

class _SecurityPageState extends State<SecurityPage> {
  List<AuthSession>? _sessions;
  List<LoginActivity>? _activity;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AuthController>().api;
    try {
      final sessions = await api.sessions();
      final activity = await api.recentActivity();
      if (!mounted) return;
      setState(() {
        _sessions = sessions;
        _activity = activity;
        _loadError = null;
      });
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final user = context.watch<AuthController>().user;
    if (user == null) return const SizedBox.shrink();

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              Insets.pageNarrow,
              Insets.xl,
              Insets.pageNarrow,
              Insets.section,
            ),
            children: [
              const PageHeader(
                title: 'Security',
                subtitle: 'Your password, devices and recent sign-ins',
              ),
              const SizedBox(height: Insets.xl),

              if (_loadError != null) ...[
                AuthNotice(message: _loadError!),
                const SizedBox(height: Insets.lg),
              ],

              if (!user.emailVerified) ...[
                const AuthNotice(
                  message: 'Your email address has not been confirmed.',
                  tone: AuthNoticeTone.warning,
                  details: ['Security notices cannot reach you until it is.'],
                ),
                const SizedBox(height: Insets.lg),
              ],

              const _ChangePasswordCard(),
              const SizedBox(height: Insets.lg),

              _ChangeEmailCard(currentEmail: user.email),
              const SizedBox(height: Insets.lg),

              _SessionsCard(sessions: _sessions, onChanged: _load),
              const SizedBox(height: Insets.lg),

              _ActivityCard(activity: _activity),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Change password (§10)
// ---------------------------------------------------------------------

class _ChangePasswordCard extends StatefulWidget {
  const _ChangePasswordCard();

  @override
  State<_ChangePasswordCard> createState() => _ChangePasswordCardState();
}

class _ChangePasswordCardState extends State<_ChangePasswordCard> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();

  bool _open = false;
  bool _saving = false;
  String? _error;
  List<String> _details = const [];

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
      _details = const [];
    });

    try {
      await context.read<AuthController>().changePassword(
        currentPassword: _current.text,
        newPassword: _next.text,
      );
      if (!mounted) return;
      setState(() {
        _saving = false;
        _open = false;
      });
      _current.clear();
      _next.clear();
      _confirm.clear();

      await showAppMessage(
        context,
        'Your password has been changed. Every other device has been signed '
        'out, and we have emailed you about it.',
      );
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.message;
        _details = error.details;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return SectionCard(
      title: 'Password',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_open) ...[
            Text(
              'Choose a new password whenever you need to. Changing it signs '
              'out every other device.',
              style: TextStyle(color: p.inkSecondary, height: 1.5),
            ),
            const SizedBox(height: Insets.md),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _open = true),
                icon: const Icon(Icons.password_rounded, size: 18),
                label: const Text('Change password'),
              ),
            ),
          ] else
            Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error != null) ...[
                    AuthNotice(message: _error!, details: _details),
                    const SizedBox(height: Insets.lg),
                  ],
                  PasswordField(
                    controller: _current,
                    label: 'Current password',
                    enabled: !_saving,
                    autofocus: true,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.password],
                    validator: (value) => (value == null || value.isEmpty)
                        ? 'Enter your current password.'
                        : null,
                  ),
                  const SizedBox(height: Insets.lg),
                  PasswordField(
                    controller: _next,
                    label: 'New password',
                    enabled: !_saving,
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
                    enabled: !_saving,
                    onSubmitted: _submit,
                    validator: (value) => value != _next.text
                        ? 'The passwords do not match.'
                        : null,
                  ),
                  const SizedBox(height: Insets.xl),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _open = false;
                                _error = null;
                              }),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: Insets.sm),
                      FilledButton(
                        onPressed: _saving ? null : _submit,
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                ),
                              )
                            : const Text('Change password'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Change email (§16)
// ---------------------------------------------------------------------

class _ChangeEmailCard extends StatefulWidget {
  const _ChangeEmailCard({required this.currentEmail});

  final String currentEmail;

  @override
  State<_ChangeEmailCard> createState() => _ChangeEmailCardState();
}

class _ChangeEmailCardState extends State<_ChangeEmailCard> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();

  bool _open = false;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await context.read<AuthController>().api.requestEmailChange(
        newEmail: _email.text.trim(),
        currentPassword: _password.text,
      );
      if (!mounted) return;
      final destination = _email.text.trim();
      setState(() {
        _saving = false;
        _open = false;
      });
      _email.clear();
      _password.clear();

      await showAppMessage(
        context,
        'We have sent a confirmation link to $destination. Your address stays '
        'as it is until you follow it.',
        tone: MessageTone.info,
      );
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return SectionCard(
      title: 'Email address',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.currentEmail,
            style: TextStyle(fontWeight: FontWeight.w600, color: p.ink),
          ),
          const SizedBox(height: Insets.md),
          if (!_open) ...[
            Text(
              'Moving to a new address needs your password, and the new '
              'address has to confirm before the change takes effect.',
              style: TextStyle(color: p.inkSecondary, height: 1.5),
            ),
            const SizedBox(height: Insets.md),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _open = true),
                icon: const Icon(Icons.alternate_email_rounded, size: 18),
                label: const Text('Change email address'),
              ),
            ),
          ] else
            Form(
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
                    enabled: !_saving,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'New email address',
                      prefixIcon: Icon(Icons.alternate_email_rounded),
                    ),
                    validator: (value) {
                      final entered = value?.trim() ?? '';
                      if (entered.isEmpty) return 'Enter the new address.';
                      if (!entered.contains('@') || !entered.contains('.')) {
                        return 'Enter a valid email address.';
                      }
                      if (entered.toLowerCase() ==
                          widget.currentEmail.toLowerCase()) {
                        return 'That is already your address.';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: Insets.lg),
                  PasswordField(
                    controller: _password,
                    label: 'Your current password',
                    enabled: !_saving,
                    onSubmitted: _submit,
                    validator: (value) => (value == null || value.isEmpty)
                        ? 'Enter your password to confirm.'
                        : null,
                  ),
                  const SizedBox(height: Insets.xl),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _saving
                            ? null
                            : () => setState(() {
                                _open = false;
                                _error = null;
                              }),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: Insets.sm),
                      FilledButton(
                        onPressed: _saving ? null : _submit,
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                ),
                              )
                            : const Text('Send confirmation'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Active devices (§18)
// ---------------------------------------------------------------------

class _SessionsCard extends StatefulWidget {
  const _SessionsCard({required this.sessions, required this.onChanged});

  final List<AuthSession>? sessions;
  final Future<void> Function() onChanged;

  @override
  State<_SessionsCard> createState() => _SessionsCardState();
}

class _SessionsCardState extends State<_SessionsCard> {
  String? _revoking;
  bool _signingOutOthers = false;

  Future<void> _revoke(AuthSession session) async {
    final confirmed = await confirmAction(
      context,
      title: 'Sign out this device?',
      body:
          '${session.device} will have to sign in again. Nothing else about '
          'the account changes.',
      confirmLabel: 'Sign out device',
    );
    if (!confirmed || !mounted) return;

    setState(() => _revoking = session.id);
    try {
      await context.read<AuthController>().api.revokeSession(session.id);
      await widget.onChanged();
    } on AuthApiException catch (error) {
      if (mounted) {
        await showAppMessage(context, error.message, tone: MessageTone.failure);
      }
    } finally {
      if (mounted) setState(() => _revoking = null);
    }
  }

  Future<void> _signOutOthers() async {
    final confirmed = await confirmAction(
      context,
      title: 'Sign out every other device?',
      body:
          'This device stays signed in. Every other one will have to sign in '
          'again.',
      confirmLabel: 'Sign out others',
    );
    if (!confirmed || !mounted) return;

    setState(() => _signingOutOthers = true);
    try {
      final revoked = await context.read<AuthController>().signOutEverywhere(
        keepCurrent: true,
      );
      await widget.onChanged();
      if (!mounted) return;
      await showAppMessage(
        context,
        revoked == 0
            ? 'There were no other devices signed in.'
            : revoked == 1
            ? 'One other device has been signed out.'
            : '$revoked other devices have been signed out.',
      );
    } on AuthApiException catch (error) {
      if (mounted) {
        await showAppMessage(context, error.message, tone: MessageTone.failure);
      }
    } finally {
      if (mounted) setState(() => _signingOutOthers = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final sessions = widget.sessions;

    return SectionCard(
      title: 'Signed-in devices',
      trailing: sessions != null && sessions.length > 1
          ? TextButton(
              onPressed: _signingOutOthers ? null : _signOutOthers,
              child: const Text('Sign out others'),
            )
          : null,
      child: sessions == null
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: Insets.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          : sessions.isEmpty
          ? Text(
              'No other devices are signed in.',
              style: TextStyle(color: p.inkMuted),
            )
          : Column(
              children: [
                for (var i = 0; i < sessions.length; i++) ...[
                  if (i > 0) Divider(color: p.line, height: Insets.xxl),
                  _SessionRow(
                    session: sessions[i],
                    busy: _revoking == sessions[i].id,
                    onRevoke: sessions[i].isCurrent
                        ? null
                        : () => _revoke(sessions[i]),
                  ),
                ],
              ],
            ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.busy,
    required this.onRevoke,
  });

  final AuthSession session;
  final bool busy;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(_iconFor(session.device), size: 20, color: p.inkSecondary),
        const SizedBox(width: Insets.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      session.device,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: p.ink,
                      ),
                    ),
                  ),
                  if (session.isCurrent) ...[
                    const SizedBox(width: Insets.sm),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Insets.sm,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: p.goodWash,
                        borderRadius: BorderRadius.circular(Radii.pill),
                      ),
                      child: Text(
                        'This device',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: p.goodText,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Text(
                [
                  'Active ${relativeTime(session.lastUsedAt)}',
                  if (session.ipAddress != null) session.ipAddress!,
                ].join(' · '),
                style: TextStyle(color: p.inkMuted, fontSize: 13),
              ),
            ],
          ),
        ),
        if (onRevoke != null)
          busy
              ? const Padding(
                  padding: EdgeInsets.all(Insets.sm),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  ),
                )
              : TextButton(onPressed: onRevoke, child: const Text('Sign out')),
      ],
    );
  }

  static IconData _iconFor(String device) {
    final lower = device.toLowerCase();
    if (lower.contains('iphone') || lower.contains('android')) {
      return Icons.smartphone_rounded;
    }
    if (lower.contains('ipad')) return Icons.tablet_rounded;
    if (lower.contains('stockpile app')) return Icons.phone_iphone_rounded;
    return Icons.laptop_rounded;
  }
}

// ---------------------------------------------------------------------
// Recent activity (§17)
// ---------------------------------------------------------------------

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.activity});

  final List<LoginActivity>? activity;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return SectionCard(
      title: 'Recent sign-in activity',
      child: activity == null
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: Insets.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          : activity!.isEmpty
          ? Text('Nothing recorded yet.', style: TextStyle(color: p.inkMuted))
          : Column(
              children: [
                for (var i = 0; i < activity!.length; i++) ...[
                  if (i > 0) Divider(color: p.line, height: Insets.xl),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        activity![i].succeeded
                            ? Icons.check_circle_outline_rounded
                            : Icons.cancel_outlined,
                        size: 18,
                        color: activity![i].succeeded ? p.goodText : p.critical,
                      ),
                      const SizedBox(width: Insets.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              activity![i].description,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: activity![i].succeeded
                                    ? p.ink
                                    : p.critical,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              [
                                if (activity![i].device != null)
                                  activity![i].device!,
                                if (activity![i].ipAddress != null)
                                  activity![i].ipAddress!,
                              ].join(' · '),
                              style: TextStyle(color: p.inkMuted, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: Insets.sm),
                      Text(
                        relativeTime(activity![i].at),
                        style: TextStyle(color: p.inkMuted, fontSize: 13),
                      ),
                    ],
                  ),
                ],
              ],
            ),
    );
  }
}

/// A confirmation step before anything destructive (§8, §24).
