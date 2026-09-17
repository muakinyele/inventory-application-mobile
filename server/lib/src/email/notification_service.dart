import 'package:drift/drift.dart';

import '../db/database.dart';
import 'mailer.dart';

/// The application notifications a user may switch off (§14).
///
/// Security mail is deliberately absent from this list. There is no key for
/// "password changed" or "new sign-in", so there is nothing for a preferences
/// endpoint to set — the guarantee is structural rather than a check someone
/// has to remember to write.
class AppNotificationChannel {
  const AppNotificationChannel(this.key, this.name, this.description);

  final String key;
  final String name;
  final String description;
}

const List<AppNotificationChannel> appNotificationChannels = [
  AppNotificationChannel(
    'low_stock',
    'Low stock alerts',
    'When an item reaches its reorder level.',
  ),
  AppNotificationChannel(
    'reports',
    'Scheduled reports',
    'Periodic stock and sales summaries.',
  ),
  AppNotificationChannel(
    'announcements',
    'Product announcements',
    'Occasional notes about new features.',
  ),
];

final Set<String> appNotificationChannelKeys = {
  for (final channel in appNotificationChannels) channel.key,
};

/// Sends mail, applying preferences only where they are allowed to apply.
///
/// Every security message goes through [sendSecurity], which never consults
/// the preferences table. Application messages go through [sendApplication],
/// which does. Splitting the two at the method boundary means a future caller
/// cannot accidentally make a security notice optional by passing a flag.
class NotificationService {
  NotificationService({required this.db, required this.mailer});

  final AuthDatabase db;
  final Mailer mailer;

  /// Always delivered. Password changes, sign-ins, lockouts, account status.
  Future<void> sendSecurity(EmailMessage message) => mailer.send(message);

  /// [sendSecurity], for a caller entitled to know whether it arrived.
  Future<bool> trySendSecurity(EmailMessage message) async {
    final inner = mailer;
    if (inner is FailSafeMailer) return inner.trySend(message);
    await inner.send(message);
    return true;
  }

  /// Delivered unless the user has opted out of [channel].
  ///
  /// Absence of a row means enabled: a user who has never touched their
  /// preferences gets the mail, and adding a new channel does not require
  /// backfilling a row for everyone.
  Future<void> sendApplication({
    required String userId,
    required String channel,
    required EmailMessage message,
  }) async {
    if (!await isEnabled(userId: userId, channel: channel)) return;
    await mailer.send(message);
  }

  Future<bool> isEnabled({
    required String userId,
    required String channel,
  }) async {
    final row =
        await (db.select(db.notificationPreferences)
              ..where((t) => t.userId.equals(userId))
              ..where((t) => t.channel.equals(channel)))
            .getSingleOrNull();
    return row?.enabled ?? true;
  }

  /// Every channel with its current setting, for the preferences screen.
  Future<Map<String, bool>> preferencesFor(String userId) async {
    final rows = await (db.select(
      db.notificationPreferences,
    )..where((t) => t.userId.equals(userId))).get();
    final stored = {for (final row in rows) row.channel: row.enabled};
    return {
      for (final channel in appNotificationChannels)
        channel.key: stored[channel.key] ?? true,
    };
  }

  /// Sets one channel. Rejects anything not in the catalogue, which is what
  /// stops a caller inventing `password_changed` and switching it off.
  Future<bool> setPreference({
    required String userId,
    required String channel,
    required bool enabled,
  }) async {
    if (!appNotificationChannelKeys.contains(channel)) return false;
    await db
        .into(db.notificationPreferences)
        .insertOnConflictUpdate(
          NotificationPreferencesCompanion.insert(
            userId: userId,
            channel: channel,
            enabled: Value(enabled),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
    return true;
  }
}
