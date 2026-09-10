import 'dart:convert';

import 'package:drift/drift.dart';

import '../auth/tokens.dart';
import '../db/database.dart';

/// One page of audit records.
class AuditPage {
  const AuditPage({required this.entries, required this.total});
  final List<AuditLog> entries;
  final int total;
}

/// Writes and queries the audit trail (§20).
///
/// Two rules hold here and are the reason this is a service rather than an
/// inline insert:
///
///  * **Nothing sensitive is recorded.** [metadata] is JSON-encoded from a map
///    the caller supplies, and [_redactedKeys] strips anything that looks like
///    a credential even if a caller passes one by mistake. Passwords and
///    tokens never reach this table.
///  * **Recording never breaks the action.** A failure to write an audit row
///    is reported to the log and swallowed. An audit trail that can 500 a
///    successful password change is worse than one with a gap in it.
class AuditService {
  AuditService(this._db, {this.onError});

  final AuthDatabase _db;
  final void Function(Object error, StackTrace stackTrace)? onError;

  /// Field names that must never be persisted, whatever a caller passes.
  static const _redactedKeys = {
    'password',
    'newPassword',
    'currentPassword',
    'confirmPassword',
    'passwordHash',
    'token',
    'accessToken',
    'refreshToken',
    'tokenHash',
    'secret',
    'pepper',
    'authorization',
    'cookie',
  };

  Future<void> record({
    required String action,
    String? actorId,
    String? actorEmail,
    String? targetType,
    String? targetId,
    String? targetLabel,
    String result = 'success',
    Map<String, Object?>? metadata,
    String? ipAddress,
  }) async {
    try {
      await _db
          .into(_db.auditLogs)
          .insert(
            AuditLogsCompanion.insert(
              id: newId(),
              actorId: Value(actorId),
              actorEmail: Value(actorEmail),
              action: action,
              targetType: Value(targetType),
              targetId: Value(targetId),
              targetLabel: Value(targetLabel),
              result: Value(result),
              metadata: Value(_encode(metadata)),
              ipAddress: Value(ipAddress),
              createdAt: DateTime.now().toUtc(),
            ),
          );
    } catch (error, stackTrace) {
      onError?.call(error, stackTrace);
    }
  }

  static String? _encode(Map<String, Object?>? metadata) {
    if (metadata == null || metadata.isEmpty) return null;
    final safe = <String, Object?>{};
    metadata.forEach((key, value) {
      if (_redactedKeys.contains(key)) return;
      safe[key] = value;
    });
    if (safe.isEmpty) return null;
    return jsonEncode(safe);
  }

  /// Paged, filtered query for the admin screen.
  ///
  /// Ordered newest-first and tie-broken on `id`, because several rows are
  /// routinely written in the same microsecond and would otherwise page
  /// unstably — an entry could appear on both page one and page two.
  Future<AuditPage> query({
    String? actorId,
    String? action,
    String? targetId,
    String? search,
    DateTime? from,
    DateTime? to,
    int limit = 50,
    int offset = 0,
  }) async {
    Expression<bool> filter($AuditLogsTable t) {
      var predicate = const Constant(true) as Expression<bool>;
      if (actorId != null) predicate = predicate & t.actorId.equals(actorId);
      if (action != null) predicate = predicate & t.action.equals(action);
      if (targetId != null) predicate = predicate & t.targetId.equals(targetId);
      if (from != null) {
        predicate = predicate & t.createdAt.isBiggerOrEqualValue(from);
      }
      if (to != null) {
        predicate = predicate & t.createdAt.isSmallerOrEqualValue(to);
      }
      if (search != null && search.trim().isNotEmpty) {
        final term = '%${search.trim().toLowerCase()}%';
        predicate =
            predicate &
            (t.actorEmail.lower().like(term) |
                t.targetLabel.lower().like(term) |
                t.action.lower().like(term));
      }
      return predicate;
    }

    final rows =
        await (_db.select(_db.auditLogs)
              ..where(filter)
              ..orderBy([
                (t) => OrderingTerm.desc(t.createdAt),
                (t) => OrderingTerm.desc(t.id),
              ])
              ..limit(limit, offset: offset))
            .get();

    final countExpression = _db.auditLogs.id.count();
    final countQuery = _db.selectOnly(_db.auditLogs)
      ..addColumns([countExpression])
      ..where(filter(_db.auditLogs));
    final total = (await countQuery.getSingle()).read(countExpression) ?? 0;

    return AuditPage(entries: rows, total: total);
  }
}
