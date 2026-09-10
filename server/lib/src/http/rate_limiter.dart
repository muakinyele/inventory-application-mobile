/// A fixed-window counter, keyed by whatever the caller chooses.
///
/// In-process on purpose. It protects a single instance from the obvious
/// abuse — hammering `/auth/login` or `/auth/forgot-password` — and needs no
/// Redis to do it. Behind more than one instance the effective limit is the
/// configured limit times the instance count, which is documented rather than
/// pretended away; the durable protections (account lockout, token issue
/// caps) live in the database and are shared across instances regardless.
class RateLimiter {
  RateLimiter({required this.limit, required this.window});

  final int limit;
  final Duration window;

  final Map<String, _Window> _windows = {};

  /// Records a hit and reports whether the caller is over the limit.
  ({bool allowed, Duration? retryAfter}) hit(String key) {
    final now = DateTime.now();
    _sweep(now);

    final existing = _windows[key];
    if (existing == null || now.isAfter(existing.resetsAt)) {
      _windows[key] = _Window(count: 1, resetsAt: now.add(window));
      return (allowed: true, retryAfter: null);
    }

    existing.count++;
    if (existing.count > limit) {
      return (allowed: false, retryAfter: existing.resetsAt.difference(now));
    }
    return (allowed: true, retryAfter: null);
  }

  /// Clears a key, so a successful sign-in does not leave the caller part-way
  /// through their allowance.
  void reset(String key) => _windows.remove(key);

  DateTime _lastSweep = DateTime.fromMillisecondsSinceEpoch(0);

  /// Drops expired windows so the map cannot grow without bound — otherwise a
  /// flood of distinct keys is itself a memory-exhaustion attack.
  void _sweep(DateTime now) {
    if (now.difference(_lastSweep) < const Duration(minutes: 1)) return;
    _lastSweep = now;
    _windows.removeWhere((_, w) => now.isAfter(w.resetsAt));
  }
}

class _Window {
  _Window({required this.count, required this.resetsAt});
  int count;
  final DateTime resetsAt;
}
