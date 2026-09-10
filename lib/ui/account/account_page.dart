import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import '../../core/design.dart';
import '../../core/formatters.dart';
import '../../core/palette.dart';
import '../../data/auth_api.dart';
import '../../models/auth_user.dart';
import '../../state/auth_controller.dart';
import '../widgets/app_message.dart';
import '../widgets/page_header.dart';
import '../widgets/section_card.dart';

/// The signed-in user's own profile (§16).
///
/// Role and status are shown but not editable here: a user changing their own
/// role would defeat the whole permission system, so those fields are
/// deliberately read-only and the API has no route that would accept them.
class AccountPage extends StatefulWidget {
  const AccountPage({super.key});

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();

  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthController>().user;
    _name.text = user?.name ?? '';
    _phone.text = user?.phone ?? '';
    _name.addListener(_onEdited);
    _phone.addListener(_onEdited);
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _onEdited() {
    final user = context.read<AuthController>().user;
    final changed =
        _name.text != (user?.name ?? '') || _phone.text != (user?.phone ?? '');
    if (changed != _dirty) setState(() => _dirty = changed);
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);

    final auth = context.read<AuthController>();
    try {
      final updated = await auth.api.updateProfile(
        name: _name.text.trim(),
        phone: _phone.text.trim(),
      );
      auth.applyProfile(updated);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _dirty = false;
      });
      await showAppMessage(context, 'Your profile has been updated.');
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      await showAppMessage(context, error.message, tone: MessageTone.failure);
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
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Insets.pageNarrow,
            Insets.xl,
            Insets.pageNarrow,
            Insets.section,
          ),
          children: [
            const PageHeader(
              title: 'My account',
              subtitle: 'Your details and how you sign in',
            ),
            const SizedBox(height: Insets.xl),

            _IdentityCard(user: user),
            const SizedBox(height: Insets.lg),

            SectionCard(
              title: 'Your details',
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _name,
                      enabled: !_saving,
                      decoration: const InputDecoration(
                        labelText: 'Full name',
                        prefixIcon: Icon(Icons.person_outline_rounded),
                      ),
                      validator: (value) =>
                          (value == null || value.trim().isEmpty)
                          ? 'Enter your name.'
                          : null,
                    ),
                    const SizedBox(height: Insets.lg),
                    TextFormField(
                      controller: _phone,
                      enabled: !_saving,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone number',
                        helperText: 'Optional',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                    ),
                    const SizedBox(height: Insets.xl),
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton(
                        onPressed: (!_dirty || _saving) ? null : _save,
                        child: _saving
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                ),
                              )
                            : const Text('Save changes'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Insets.lg),

            SectionCard(
              title: 'Email address',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _FactRow(label: 'Address', value: user.email),
                  const SizedBox(height: Insets.md),
                  Row(
                    children: [
                      Icon(
                        user.emailVerified
                            ? Icons.verified_rounded
                            : Icons.error_outline_rounded,
                        size: 18,
                        color: user.emailVerified ? p.goodText : p.warningText,
                      ),
                      const SizedBox(width: Insets.sm),
                      Expanded(
                        child: Text(
                          user.emailVerified
                              ? 'Confirmed'
                              : 'Not confirmed yet',
                          style: TextStyle(
                            color: user.emailVerified
                                ? p.goodText
                                : p.warningText,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Insets.lg),
                  Text(
                    'Changing your address needs your password, and the new '
                    'address has to be confirmed before it takes effect.',
                    style: TextStyle(color: p.inkSecondary, height: 1.5),
                  ),
                  const SizedBox(height: Insets.md),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () => context.go('/account/security'),
                      icon: const Icon(Icons.shield_outlined, size: 18),
                      label: const Text('Go to security settings'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Insets.lg),

            SectionCard(
              title: 'Access',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _FactRow(
                    label: 'Role',
                    value: user.roles.isEmpty
                        ? 'No role assigned'
                        : user.roles.map(_roleName).join(', '),
                  ),
                  const SizedBox(height: Insets.md),
                  _FactRow(label: 'Status', value: _statusLabel(user.status)),
                  const SizedBox(height: Insets.md),
                  _FactRow(
                    label: 'Last signed in',
                    value: user.lastLoginAt == null
                        ? 'This is your first sign-in'
                        : relativeTime(user.lastLoginAt!),
                  ),
                  const SizedBox(height: Insets.md),
                  _FactRow(
                    label: 'Account created',
                    value: user.createdAt == null
                        ? '—'
                        : dateTimeLabel(user.createdAt!),
                  ),
                  const SizedBox(height: Insets.lg),
                  Text(
                    'Only an administrator can change your role. Ask one if '
                    'you need different access.',
                    style: TextStyle(color: p.inkMuted, height: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _statusLabel(String status) => switch (status) {
    'active' => 'Active',
    'pending' => 'Pending activation',
    'disabled' => 'Disabled',
    _ => status,
  };

  static String _roleName(String key) => switch (key) {
    'administrator' => 'Administrator',
    'inventory_manager' => 'Inventory Manager',
    'staff' => 'Staff',
    _ => key,
  };
}

class _IdentityCard extends StatelessWidget {
  const _IdentityCard({required this.user});

  final AuthUser user;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.all(Insets.xl),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.card),
        border: Border.all(color: p.line),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: p.accentWash,
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
            child: Text(
              user.initials,
              style: TextStyle(
                color: p.accent,
                fontWeight: FontWeight.w700,
                fontSize: 20,
              ),
            ),
          ),
          const SizedBox(width: Insets.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.name.isEmpty ? user.email : user.name,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(user.email, style: TextStyle(color: p.inkSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 128,
          child: Text(label, style: TextStyle(color: p.inkMuted)),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(color: p.ink, fontWeight: FontWeight.w500),
          ),
        ),
      ],
    );
  }
}
