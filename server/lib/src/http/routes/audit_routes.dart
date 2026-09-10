import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';

import '../../audit/audit_actions.dart';
import '../../audit/audit_service.dart';
import '../middleware.dart';
import '../request_context.dart';
import '../serializers.dart';

/// The administrator's view of the audit trail (§20).
///
/// Read-only by design: there is no endpoint that edits or deletes a record,
/// because a trail that can be rewritten from the same interface it is read
/// from is not evidence of anything.
Router auditRoutes({required AuditService audit}) {
  final router = Router();

  router.get('/', (Request request) async {
    request.require('audit_logs.view');

    final query = request.url.queryParameters;
    final page = await audit.query(
      actorId: _blankToNull(query['actor']),
      action: _blankToNull(query['action']),
      targetId: _blankToNull(query['target']),
      search: _blankToNull(query['search']),
      from: _parseBoundary(query['from'], endOfDay: false),
      // A bare date as `to` means the *end* of that day, so filtering
      // "to today" includes what happened this morning.
      to: _parseBoundary(query['to'], endOfDay: true),
      limit: _boundedInt(query['limit'], fallback: 50, min: 1, max: 200),
      offset: _boundedInt(query['offset'], fallback: 0, min: 0, max: 1 << 30),
    );

    return jsonResponse({
      'entries': [for (final entry in page.entries) auditLogJson(entry)],
      'total': page.total,
    });
  });

  /// The closed list of event types, so the filter dropdown does not have to
  /// be kept in step with the server by hand.
  router.get('/actions', (Request request) async {
    request.require('audit_logs.view');
    return jsonResponse({'actions': AuditAction.all});
  });

  return router;
}

String? _blankToNull(String? value) =>
    (value == null || value.trim().isEmpty) ? null : value.trim();

/// Parses a filter boundary.
///
/// A bare `YYYY-MM-DD` means a whole day in UTC — the start of it for `from`,
/// the last instant of it for `to`. Anything else is parsed as a full
/// timestamp.
///
/// Whether the input is a bare date is decided from the *string*, never from
/// the parsed value's fields: `DateTime.parse('2026-09-09')` yields local
/// midnight, and converting that to UTC generally leaves a non-zero hour, so
/// inspecting the result would misclassify a bare date everywhere except UTC
/// and quietly drop the current day from the range.
DateTime? _parseBoundary(String? value, {required bool endOfDay}) {
  final trimmed = _blankToNull(value);
  if (trimmed == null) return null;

  if (_bareDate.hasMatch(trimmed)) {
    // The trailing `Z` pins it to UTC, so the boundary does not drift with
    // the server's timezone.
    final start = DateTime.parse('${trimmed}T00:00:00Z');
    if (!endOfDay) return start;
    return start
        .add(const Duration(days: 1))
        .subtract(const Duration(microseconds: 1));
  }

  return DateTime.tryParse(trimmed)?.toUtc();
}

final RegExp _bareDate = RegExp(r'^\d{4}-\d{2}-\d{2}$');

int _boundedInt(
  String? raw, {
  required int fallback,
  required int min,
  required int max,
}) {
  final parsed = int.tryParse(raw ?? '');
  if (parsed == null) return fallback;
  return parsed.clamp(min, max);
}
