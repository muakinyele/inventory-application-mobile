import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/design.dart';
import '../../core/palette.dart';
import '../../data/auth_api.dart';
import '../../state/auth_controller.dart';
import '../auth/auth_scaffold.dart';
import '../widgets/app_message.dart';
import '../widgets/page_header.dart';
import '../widgets/section_card.dart';

/// Notification preferences (§14).
///
/// Two lists, and the split is the point. Application notices come from the
/// server with a switch each. Security notices are shown as a fixed list with
/// no switch at all — not a disabled one — because the API has no channel key
/// for them, so there is nothing a request could turn off.
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  List<NotificationChannel>? _channels;
  Map<String, bool> _preferences = const {};
  String? _error;
  String? _saving;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = await context
          .read<AuthController>()
          .api
          .notificationSettings();
      if (!mounted) return;
      setState(() {
        _channels = settings.channels;
        _preferences = settings.preferences;
        _error = null;
      });
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    }
  }

  Future<void> _set(String channel, bool enabled) async {
    setState(() {
      _saving = channel;
      // Applied optimistically so the switch moves under the finger; the
      // server's answer replaces it a moment later.
      _preferences = {..._preferences, channel: enabled};
    });

    try {
      final updated = await context
          .read<AuthController>()
          .api
          .setNotificationPreferences({channel: enabled});
      if (!mounted) return;
      setState(() {
        _preferences = updated;
        _saving = null;
      });
    } on AuthApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _preferences = {..._preferences, channel: !enabled};
        _saving = null;
      });
      await showAppMessage(context, error.message, tone: MessageTone.failure);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

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
              title: 'Notifications',
              subtitle: 'What Stockpile emails you about',
            ),
            const SizedBox(height: Insets.xl),

            if (_error != null) ...[
              AuthNotice(message: _error!),
              const SizedBox(height: Insets.lg),
            ],

            SectionCard(
              title: 'Application notifications',
              child: _channels == null
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: Insets.xl),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < _channels!.length; i++) ...[
                          if (i > 0) Divider(color: p.line, height: Insets.lg),
                          SwitchListTile.adaptive(
                            contentPadding: EdgeInsets.zero,
                            value: _preferences[_channels![i].key] ?? true,
                            onChanged: _saving != null
                                ? null
                                : (value) => _set(_channels![i].key, value),
                            title: Text(
                              _channels![i].name,
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: p.ink,
                              ),
                            ),
                            subtitle: Text(
                              _channels![i].description,
                              style: TextStyle(color: p.inkSecondary),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: Insets.lg),

            SectionCard(
              title: 'Security notifications',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(Insets.md),
                    decoration: BoxDecoration(
                      color: p.infoWash,
                      borderRadius: BorderRadius.circular(Radii.control),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.shield_rounded, size: 18, color: p.info),
                        const SizedBox(width: Insets.sm),
                        Expanded(
                          child: Text(
                            'These are always sent. They are how you find out '
                            'if someone else is using your account.',
                            style: TextStyle(color: p.info, height: 1.45),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Insets.lg),
                  for (final notice in _securityNotices) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: Insets.md),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.check_rounded,
                            size: 18,
                            color: p.goodText,
                          ),
                          const SizedBox(width: Insets.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  notice.$1,
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: p.ink,
                                  ),
                                ),
                                Text(
                                  notice.$2,
                                  style: TextStyle(color: p.inkSecondary),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Mirrors the security mail the server actually sends. Listed so the user
  /// knows what to expect, not so it can be configured.
  static const List<(String, String)> _securityNotices = [
    ('Password changed', 'Whenever your password is changed or reset.'),
    ('New sign-in', 'When your account is used on a device we have not seen.'),
    ('Email address changed', 'Sent to both the old and the new address.'),
    ('Account locked', 'After too many failed sign-in attempts.'),
    (
      'Account enabled or disabled',
      'When an administrator changes your access.',
    ),
  ];
}
