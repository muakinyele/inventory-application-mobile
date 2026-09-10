import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design.dart';
import '../../core/palette.dart';
import '../../data/auth_api.dart';
import '../../models/auth_user.dart';
import '../../state/auth_controller.dart';
import '../auth/auth_scaffold.dart';

/// Invites a new user (§9).
///
/// Returns true when an invitation was sent, so the caller can reload its
/// list. The account is created pending with no password; the invitee sets one
/// through the emailed link.
Future<bool> showInviteUserSheet(BuildContext context) async {
  final sent = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.of(context).size.height * 0.9,
      maxWidth: 560,
    ),
    builder: (sheetContext) => const _InviteUserSheet(),
  );
  return sent ?? false;
}

class _InviteUserSheet extends StatefulWidget {
  const _InviteUserSheet();

  @override
  State<_InviteUserSheet> createState() => _InviteUserSheetState();
}

class _InviteUserSheetState extends State<_InviteUserSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();

  List<AuthRole>? _roles;
  String? _selectedRole;
  bool _sending = false;
  String? _error;

  /// Set when the server has no SMTP configured and handed the link back, so
  /// a development setup can still complete the flow.
  String? _invitationUrl;

  @override
  void initState() {
    super.initState();
    _loadRoles();
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _loadRoles() async {
    try {
      final roles = await context.read<AuthController>().api.roles();
      if (!mounted) return;
      setState(() {
        _roles = roles;
        // Defaults to the least privileged role, so an accidental Enter does
        // not create an administrator.
        _selectedRole = roles.any((r) => r.key == 'staff')
            ? 'staff'
            : roles.firstOrNull?.key;
      });
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    }
  }

  Future<void> _send() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final role = _selectedRole;
    if (role == null) return;

    setState(() {
      _sending = true;
      _error = null;
    });

    try {
      final result = await context.read<AuthController>().api.inviteUser(
        email: _email.text.trim(),
        name: _name.text.trim(),
        phone: _phone.text.trim(),
        roles: [role],
      );
      if (!mounted) return;

      if (result.invitationUrl != null) {
        // Shown rather than hidden: without mail configured this link is the
        // only way in, and the operator asked for it.
        setState(() {
          _sending = false;
          _invitationUrl = result.invitationUrl;
        });
        return;
      }
      Navigator.of(context).pop(true);
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = error.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Insets.xl),
          child: _invitationUrl != null
              ? _InvitationLink(
                  url: _invitationUrl!,
                  email: _email.text.trim(),
                  onDone: () => Navigator.of(context).pop(true),
                )
              : Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Invite someone',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: Insets.xs),
                      Text(
                        'They will get an email with a link to set their own '
                        'password. You never see it.',
                        style: TextStyle(color: p.inkSecondary, height: 1.5),
                      ),
                      const SizedBox(height: Insets.xl),

                      if (_error != null) ...[
                        AuthNotice(message: _error!),
                        const SizedBox(height: Insets.lg),
                      ],

                      TextFormField(
                        controller: _name,
                        autofocus: true,
                        enabled: !_sending,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Full name',
                          prefixIcon: Icon(Icons.person_outline_rounded),
                        ),
                        validator: (value) =>
                            (value == null || value.trim().isEmpty)
                            ? 'Enter their name.'
                            : null,
                      ),
                      const SizedBox(height: Insets.lg),

                      TextFormField(
                        controller: _email,
                        enabled: !_sending,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Email address',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                        validator: (value) {
                          final entered = value?.trim() ?? '';
                          if (entered.isEmpty) return 'Enter their address.';
                          if (!entered.contains('@') ||
                              !entered.contains('.')) {
                            return 'Enter a valid email address.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: Insets.lg),

                      TextFormField(
                        controller: _phone,
                        enabled: !_sending,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(
                          labelText: 'Phone number',
                          helperText: 'Optional',
                          prefixIcon: Icon(Icons.phone_outlined),
                        ),
                      ),
                      const SizedBox(height: Insets.xl),

                      Text(
                        'Role',
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(height: Insets.sm),
                      if (_roles == null)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: Insets.lg),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else
                        // RadioGroup rather than per-tile groupValue: the
                        // per-tile form is deprecated in this Flutter version.
                        RadioGroup<String>(
                          groupValue: _selectedRole,
                          // RadioGroup's callback is non-nullable, so the
                          // in-flight guard is inside it rather than being
                          // expressed by passing null.
                          onChanged: (value) {
                            if (_sending) return;
                            setState(() => _selectedRole = value);
                          },
                          child: Column(
                            children: [
                              for (final role in _roles!)
                                RadioListTile<String>(
                                  value: role.key,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(
                                    role.name,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: p.ink,
                                    ),
                                  ),
                                  subtitle: Text(
                                    role.description,
                                    style: TextStyle(color: p.inkSecondary),
                                  ),
                                ),
                            ],
                          ),
                        ),

                      const SizedBox(height: Insets.xl),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: _sending
                                ? null
                                : () => Navigator.of(context).pop(false),
                            child: const Text('Cancel'),
                          ),
                          const SizedBox(width: Insets.sm),
                          FilledButton(
                            onPressed: _sending ? null : _send,
                            child: _sending
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.2,
                                    ),
                                  )
                                : const Text('Send invitation'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

/// Shown when the server has no mail configured.
class _InvitationLink extends StatelessWidget {
  const _InvitationLink({
    required this.url,
    required this.email,
    required this.onDone,
  });

  final String url;
  final String email;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Account created', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: Insets.lg),
        const AuthNotice(
          message:
              'Email is not configured on the server, so nothing was sent.',
          tone: AuthNoticeTone.warning,
          details: [
            'Give this link to the person directly. It can be used once.',
          ],
        ),
        const SizedBox(height: Insets.lg),
        Text('For $email', style: TextStyle(color: p.inkSecondary)),
        const SizedBox(height: Insets.sm),
        Container(
          padding: const EdgeInsets.all(Insets.md),
          decoration: BoxDecoration(
            color: p.surfaceSunken,
            borderRadius: BorderRadius.circular(Radii.control),
            border: Border.all(color: p.line),
          ),
          child: SelectableText(
            url,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
        const SizedBox(height: Insets.xl),
        FilledButton(onPressed: onDone, child: const Text('Done')),
      ],
    );
  }
}
