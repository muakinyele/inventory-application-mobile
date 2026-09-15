import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design.dart';
import '../../core/formatters.dart';
import '../../core/palette.dart';
import '../../data/auth_api.dart';
import '../../models/auth_user.dart';
import '../../state/auth_controller.dart';
import '../auth/auth_scaffold.dart';
import '../widgets/app_message.dart';
import '../widgets/page_header.dart';
import '../widgets/section_card.dart';
import 'user_status_chip.dart';
import '../widgets/confirm_dialog.dart';

/// One user, and everything an administrator can do to their account (§8).
///
/// Each action is gated on the specific permission the API will check, so the
/// screen never offers a control that would come back forbidden — and the API
/// still enforces it regardless of what this screen decided to show.
class UserDetailPage extends StatefulWidget {
  const UserDetailPage({super.key, required this.userId});

  final String userId;

  @override
  State<UserDetailPage> createState() => _UserDetailPageState();
}

class _UserDetailPageState extends State<UserDetailPage> {
  ManagedUser? _user;
  List<AuthSession> _sessions = const [];
  List<AuthRole> _roles = const [];
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AuthController>().api;
    try {
      final detail = await api.userDetail(widget.userId);
      final roles = await api.roles();
      if (!mounted) return;
      setState(() {
        _user = detail.user;
        _sessions = detail.sessions;
        _roles = roles;
        _error = null;
      });
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    }
  }

  /// Runs an administrative action, showing whatever the API says on failure.
  ///
  /// Refusals here are meaningful — "this is the last administrator", "you
  /// cannot do that to your own account" — so the server's wording is shown
  /// rather than a generic message.
  Future<void> _run(
    Future<void> Function() action, {
    required String success,
  }) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
      if (!mounted) return;
      await showAppMessage(context, success);
    } on AuthApiException catch (error) {
      if (!mounted) return;
      await showAppMessage(context, error.message, tone: MessageTone.failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final auth = context.watch<AuthController>();
    final user = _user;

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(Insets.pageNarrow),
                child: Column(
                  children: [
                    const PageHeader(title: 'User', showBack: true),
                    const SizedBox(height: Insets.xl),
                    AuthNotice(message: _error!),
                  ],
                ),
              )
            : user == null
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.fromLTRB(
                  Insets.pageNarrow,
                  Insets.xl,
                  Insets.pageNarrow,
                  Insets.section,
                ),
                children: [
                  PageHeader(
                    title: user.name.isEmpty ? user.email : user.name,
                    subtitle: user.email,
                    showBack: true,
                  ),
                  const SizedBox(height: Insets.lg),

                  Wrap(
                    spacing: Insets.sm,
                    runSpacing: Insets.sm,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      UserStatusChip(user: user),
                      VerificationChip(verified: user.emailVerified),
                    ],
                  ),
                  const SizedBox(height: Insets.lg),

                  if (user.isLocked) ...[
                    AuthNotice(
                      message:
                          'This account is locked after too many failed '
                          'sign-in attempts.',
                      tone: AuthNoticeTone.warning,
                      details: const [
                        'It unlocks by itself shortly. You can also lift it now.',
                      ],
                      action: auth.can('users.update')
                          ? TextButton(
                              onPressed: _busy
                                  ? null
                                  : () => _run(
                                      () => auth.api.unlockUser(user.id),
                                      success: 'The account has been unlocked.',
                                    ),
                              style: TextButton.styleFrom(
                                padding: EdgeInsets.zero,
                                minimumSize: const Size(0, 32),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              child: const Text('Unlock now'),
                            )
                          : null,
                    ),
                    const SizedBox(height: Insets.lg),
                  ],

                  SectionCard(
                    title: 'Account',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _Fact(label: 'Email', value: user.email),
                        _Fact(
                          label: 'Phone',
                          value: user.phone?.isNotEmpty == true
                              ? user.phone!
                              : 'Not given',
                        ),
                        _Fact(
                          label: 'Email confirmed',
                          value: user.emailVerified ? 'Yes' : 'No',
                        ),
                        _Fact(
                          label: 'Last signed in',
                          value: user.lastLoginAt == null
                              ? 'Never'
                              : relativeTime(user.lastLoginAt!),
                        ),
                        _Fact(
                          label: 'Account created',
                          value: user.createdAt == null
                              ? '—'
                              : dateTimeLabel(user.createdAt!),
                        ),
                        _Fact(
                          label: 'Signed-in devices',
                          value: '${user.activeSessions}',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Insets.lg),

                  if (auth.can('roles.manage'))
                    _RolesCard(
                      user: user,
                      roles: _roles,
                      busy: _busy,
                      onChanged: (keys) => _run(
                        () => auth.api.setUserRoles(user.id, keys),
                        success: 'Their role has been changed.',
                      ),
                    ),
                  if (auth.can('roles.manage'))
                    const SizedBox(height: Insets.lg),

                  if (_sessions.isNotEmpty && auth.can('sessions.revoke')) ...[
                    SectionCard(
                      title: 'Signed-in devices',
                      child: Column(
                        children: [
                          for (var i = 0; i < _sessions.length; i++) ...[
                            if (i > 0)
                              Divider(color: p.line, height: Insets.xl),
                            Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _sessions[i].device,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w600,
                                          color: p.ink,
                                        ),
                                      ),
                                      Text(
                                        'Active '
                                        '${relativeTime(_sessions[i].lastUsedAt)}',
                                        style: TextStyle(
                                          color: p.inkMuted,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _run(
                                          () => auth.api.revokeUserSession(
                                            user.id,
                                            _sessions[i].id,
                                          ),
                                          success:
                                              'That device has been signed out.',
                                        ),
                                  child: const Text('Sign out'),
                                ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: Insets.lg),
                  ],

                  _ActionsCard(
                    user: user,
                    busy: _busy,
                    onAction: _run,
                    onReload: _load,
                  ),
                ],
              ),
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: TextStyle(color: p.inkMuted)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(color: p.ink, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

class _RolesCard extends StatelessWidget {
  const _RolesCard({
    required this.user,
    required this.roles,
    required this.busy,
    required this.onChanged,
  });

  final ManagedUser user;
  final List<AuthRole> roles;
  final bool busy;
  final void Function(List<String>) onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final current = user.roles.isEmpty ? null : user.roles.first;

    return SectionCard(
      title: 'Role',
      child: RadioGroup<String>(
        groupValue: current,
        onChanged: (value) {
          if (busy || value == null || value == current) return;
          onChanged([value]);
        },
        child: Column(
          children: [
            for (final role in roles)
              RadioListTile<String>(
                value: role.key,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  role.name,
                  style: TextStyle(fontWeight: FontWeight.w600, color: p.ink),
                ),
                subtitle: Text(
                  role.description,
                  style: TextStyle(color: p.inkSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActionsCard extends StatelessWidget {
  const _ActionsCard({
    required this.user,
    required this.busy,
    required this.onAction,
    required this.onReload,
  });

  final ManagedUser user;
  final bool busy;
  final Future<void> Function(
    Future<void> Function() action, {
    required String success,
  })
  onAction;
  final Future<void> Function() onReload;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final auth = context.watch<AuthController>();
    final isSelf = auth.user?.id == user.id;
    final pending = user.status == 'pending';

    return SectionCard(
      title: 'Actions',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (pending && auth.can('users.create')) ...[
            _ActionRow(
              icon: Icons.forward_to_inbox_rounded,
              label: 'Resend invitation',
              description: 'Send a fresh link. The old one stops working.',
              enabled: !busy,
              onTap: () => onAction(
                () => auth.api.resendInvitation(user.id),
                success: 'The invitation has been sent again.',
              ),
            ),
            Divider(color: p.line, height: Insets.xxl),
          ],

          if (!pending && auth.can('users.reset_password')) ...[
            _ActionRow(
              icon: Icons.lock_reset_rounded,
              label: 'Send a password reset',
              description:
                  'Emails them a link to choose a new password, and signs '
                  'out their devices. You never see the password.',
              enabled: !busy,
              onTap: () async {
                final ok = await confirmAction(
                  context,
                  title: 'Send a password reset?',
                  body:
                      '${user.email} will be emailed a link to set a new '
                      'password, and every device signed in as them will be '
                      'signed out.',
                  confirmLabel: 'Send reset',
                );
                if (!ok) return;
                await onAction(
                  () => auth.api.sendUserPasswordReset(user.id),
                  success: 'A password reset link has been sent.',
                );
              },
            ),
            Divider(color: p.line, height: Insets.xxl),
          ],

          if (auth.can('users.disable') && !isSelf) ...[
            _ActionRow(
              icon: user.status == 'disabled'
                  ? Icons.lock_open_rounded
                  : Icons.block_rounded,
              label: user.status == 'disabled'
                  ? 'Enable this account'
                  : 'Disable this account',
              description: user.status == 'disabled'
                  ? 'They will be able to sign in again, and will be emailed.'
                  : 'They are signed out at once and cannot sign in. Nothing '
                        'is deleted.',
              destructive: user.status != 'disabled',
              enabled: !busy,
              onTap: () async {
                final disabling = user.status != 'disabled';
                final ok = await confirmAction(
                  context,
                  title: disabling
                      ? 'Disable this account?'
                      : 'Enable this account?',
                  body: disabling
                      ? '${user.email} will be signed out of every device and '
                            'will not be able to sign in. Their data is kept.'
                      : '${user.email} will be able to sign in again.',
                  confirmLabel: disabling ? 'Disable' : 'Enable',
                  destructive: disabling,
                );
                if (!ok) return;
                await onAction(
                  () => auth.api.setUserEnabled(user.id, !disabling),
                  success: disabling
                      ? 'The account has been disabled.'
                      : 'The account has been restored.',
                );
              },
            ),
            Divider(color: p.line, height: Insets.xxl),
          ],

          if (auth.can('users.delete') && !isSelf)
            _ActionRow(
              icon: Icons.person_off_rounded,
              label: pending ? 'Cancel this invitation' : 'Deactivate account',
              description: pending
                  ? 'The invitation stops working and the account is removed.'
                  : 'Removes them from the list and frees their email address. '
                        'The audit trail keeps their history.',
              destructive: true,
              enabled: !busy,
              onTap: () async {
                final ok = await confirmAction(
                  context,
                  title: pending
                      ? 'Cancel this invitation?'
                      : 'Deactivate this account?',
                  body: pending
                      ? 'The link sent to ${user.email} will stop working.'
                      : '${user.email} will be signed out and removed from '
                            'the user list. This is not a permanent delete — '
                            'the record is kept so the audit trail still '
                            'names them.',
                  confirmLabel: pending ? 'Cancel invitation' : 'Deactivate',
                  destructive: true,
                );
                if (!ok || !context.mounted) return;

                try {
                  if (pending) {
                    await auth.api.revokeInvitation(user.id);
                  } else {
                    await auth.api.deactivateUser(user.id);
                  }
                  if (!context.mounted) return;
                  await showAppMessage(
                    context,
                    pending
                        ? 'The invitation has been cancelled.'
                        : 'The account has been deactivated.',
                  );
                  // The user no longer exists in the list, so there is nothing
                  // left on this screen to show.
                  if (context.mounted) Navigator.of(context).maybePop();
                } on AuthApiException catch (error) {
                  if (!context.mounted) return;
                  await showAppMessage(
                    context,
                    error.message,
                    tone: MessageTone.failure,
                  );
                  await onReload();
                }
              },
            ),

          if (isSelf)
            Padding(
              padding: const EdgeInsets.only(top: Insets.sm),
              child: Text(
                'This is your own account. Disabling or deactivating it is '
                'not offered here.',
                style: TextStyle(color: p.inkMuted, height: 1.5),
              ),
            ),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.description,
    required this.enabled,
    required this.onTap,
    this.destructive = false,
  });

  final IconData icon;
  final String label;
  final String description;
  final bool enabled;
  final VoidCallback onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final colour = destructive ? p.critical : p.ink;

    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(Radii.control),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: Insets.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: colour),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: colour,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(
                      color: p.inkSecondary,
                      height: 1.45,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Confirmation before anything that signs someone out or removes them (§8).
