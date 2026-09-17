import 'dart:io';

/// A misconfigured server should refuse to start rather than run with an
/// insecure default, so every lookup that has no safe fallback throws.
class ConfigError implements Exception {
  ConfigError(this.message);
  final String message;
  @override
  String toString() => 'ConfigError: $message';
}

/// Server configuration, read once at boot.
///
/// Values come from the real process environment first and a `.env` file
/// second, so a container's injected variables always beat a file that was
/// copied into the image by accident. Nothing here is ever sent to a client:
/// the API exposes no configuration endpoint, and [toString] is deliberately
/// not implemented so a stray log line cannot spill the SMTP password.
class Env {
  Env._({
    required this.port,
    required this.databaseUrl,
    required this.appUrl,
    required this.appName,
    required this.tokenPepper,
    required this.smtp,
    required this.mailFrom,
    required this.corsOrigins,
    required this.accessTokenTtl,
    required this.refreshTokenTtl,
    required this.invitationTtl,
    required this.passwordResetTtl,
    required this.emailVerificationTtl,
    required this.maxFailedLogins,
    required this.lockoutDuration,
    required this.trustProxyHeaders,
    required this.isProduction,
  });

  final int port;
  final String databaseUrl;

  /// Base URL the *user* clicks through to. Every emailed link is built from
  /// this rather than from a request header, so a spoofed `Host` cannot
  /// redirect a password-reset link at an attacker's domain.
  final String appUrl;
  final String appName;

  /// Mixed into every token hash. A leaked database alone is then not enough
  /// to forge a session token, because the pepper lives in the environment
  /// rather than in the table beside the hash.
  final String tokenPepper;

  final SmtpConfig? smtp;
  final String mailFrom;
  final List<String> corsOrigins;

  final Duration accessTokenTtl;
  final Duration refreshTokenTtl;
  final Duration invitationTtl;
  final Duration passwordResetTtl;
  final Duration emailVerificationTtl;

  final int maxFailedLogins;
  final Duration lockoutDuration;

  /// Whether the database connection must be TLS.
  ///
  /// Derived from the connection string rather than from `APP_ENV`, because
  /// production covers two quite different situations. A managed database
  /// reached across a network must have TLS. A container on the same Docker
  /// bridge cannot: the official `postgres` image ships with TLS switched
  /// off, so demanding it there fails every connection forever — which is
  /// exactly what it did.
  ///
  /// So the connection string decides, the way libpq's own `sslmode` does:
  ///   * `?sslmode=require` (or verify-full) — TLS, and fail without it.
  ///   * `?sslmode=disable` — no TLS.
  ///   * neither — TLS if the host looks remote, off for a local or
  ///     compose-network host, which is the case that has no TLS to offer.
  bool get databaseRequiresSsl {
    final uri = Uri.tryParse(databaseUrl);
    final mode = uri?.queryParameters['sslmode']?.toLowerCase();
    if (mode != null) {
      return mode != 'disable' && mode != 'allow' && mode != 'prefer';
    }

    final host = uri?.host ?? '';
    const localish = {'localhost', '127.0.0.1', '::1', 'db', 'postgres'};
    if (localish.contains(host)) return false;
    // A bare name with no dots is a container or LAN hostname, not a managed
    // service endpoint.
    if (!host.contains('.')) return false;
    return isProduction;
  }

  /// Only trust `X-Forwarded-For` when a reverse proxy is genuinely in front,
  /// otherwise a client can spoof its own IP and slip past per-IP throttling.
  final bool trustProxyHeaders;

  final bool isProduction;

  /// True when email should actually be delivered. Without SMTP configured the
  /// app still runs — the sender writes to the log instead — which keeps a
  /// fresh clone working before anyone has SMTP credentials.
  bool get emailEnabled => smtp != null;

  static Env load({Map<String, String>? overrides, String? envFile}) {
    final values = <String, String>{};

    final file = File(envFile ?? '.env');
    if (file.existsSync()) {
      values.addAll(_parseDotEnv(file.readAsStringSync()));
    }
    values.addAll(Platform.environment);
    if (overrides != null) values.addAll(overrides);

    String? read(String key) {
      final value = values[key]?.trim();
      return (value == null || value.isEmpty) ? null : value;
    }

    String require(String key, String why) {
      final value = read(key);
      if (value == null) {
        throw ConfigError('$key is not set. $why');
      }
      return value;
    }

    final environment = read('APP_ENV') ?? 'development';
    final isProduction = environment == 'production';

    final pepper = read('TOKEN_PEPPER');
    if (isProduction && pepper == null) {
      throw ConfigError(
        'TOKEN_PEPPER is not set. Generate one with '
        '`dart run bin/generate_secret.dart` and set it before starting in '
        'production; without it every issued token would be invalidated on '
        'the next restart.',
      );
    }
    if (pepper != null && pepper.length < 32) {
      throw ConfigError(
        'TOKEN_PEPPER must be at least 32 characters; got ${pepper.length}.',
      );
    }

    SmtpConfig? smtp;
    final host = read('EMAIL_HOST');
    if (host != null) {
      smtp = SmtpConfig(
        host: host,
        port: int.tryParse(read('EMAIL_PORT') ?? '587') ?? 587,
        username: read('EMAIL_USERNAME'),
        password: read('EMAIL_PASSWORD'),
        useSsl: (read('EMAIL_SSL') ?? 'false').toLowerCase() == 'true',
        allowInsecure:
            (read('EMAIL_ALLOW_INSECURE') ?? 'false').toLowerCase() == 'true',
      );
    } else if (isProduction) {
      throw ConfigError(
        'EMAIL_HOST is not set. In production the server must be able to send '
        'password-reset and invitation mail; set EMAIL_* or explicitly run '
        'with APP_ENV=development.',
      );
    }

    Duration minutes(String key, int fallback) =>
        Duration(minutes: int.tryParse(read(key) ?? '') ?? fallback);
    Duration hours(String key, int fallback) =>
        Duration(hours: int.tryParse(read(key) ?? '') ?? fallback);

    final appUrl = read('APP_URL') ?? 'http://localhost:8080';
    if (isProduction && !appUrl.startsWith('https://')) {
      throw ConfigError(
        'APP_URL must be an https:// URL in production; got "$appUrl". '
        'Reset and invitation links are built from it.',
      );
    }

    return Env._(
      port: int.tryParse(read('PORT') ?? '8080') ?? 8080,
      databaseUrl: require(
        'DATABASE_URL',
        'Expected e.g. postgres://user:password@localhost:5432/stockpile_auth',
      ),
      appUrl: _stripTrailingSlash(appUrl),
      appName: read('APP_NAME') ?? 'Stockpile',
      // Development gets a fixed, obviously-not-secret pepper so tokens
      // survive a hot restart. Production has already thrown above.
      tokenPepper: pepper ?? 'development-pepper-not-for-production-use',
      smtp: smtp,
      // Falls back to the SMTP account rather than a placeholder. The old
      // default was `no-reply@localhost`, which is not a routable address —
      // the mailer rejects it as an invalid message before anything reaches
      // the server, and the error says nothing about where it came from.
      // Whoever we authenticate as can always send as itself.
      mailFrom:
          read('EMAIL_FROM') ??
          smtp?.username ??
          'Stockpile <no-reply@localhost>',
      corsOrigins: (read('CORS_ORIGINS') ?? appUrl)
          .split(',')
          .map((o) => _stripTrailingSlash(o.trim()))
          .where((o) => o.isNotEmpty)
          .toList(growable: false),
      accessTokenTtl: minutes('ACCESS_TOKEN_TTL_MINUTES', 15),
      refreshTokenTtl: hours('REFRESH_TOKEN_TTL_HOURS', 24 * 30),
      invitationTtl: hours('INVITATION_TTL_HOURS', 72),
      passwordResetTtl: minutes('PASSWORD_RESET_TTL_MINUTES', 60),
      emailVerificationTtl: hours('EMAIL_VERIFICATION_TTL_HOURS', 24),
      maxFailedLogins: int.tryParse(read('MAX_FAILED_LOGINS') ?? '') ?? 8,
      lockoutDuration: minutes('LOCKOUT_MINUTES', 15),
      trustProxyHeaders:
          (read('TRUST_PROXY_HEADERS') ?? 'false').toLowerCase() == 'true',
      isProduction: isProduction,
    );
  }

  static String _stripTrailingSlash(String value) =>
      value.endsWith('/') ? value.substring(0, value.length - 1) : value;

  /// Deliberately small: `KEY=value`, `#` comments, and optional matching
  /// quotes. Anything fancier belongs in the real environment.
  static Map<String, String> _parseDotEnv(String contents) {
    final result = <String, String>{};
    for (final rawLine in contents.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final separator = line.indexOf('=');
      if (separator <= 0) continue;
      final key = line.substring(0, separator).trim();
      var value = line.substring(separator + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      result[key] = value;
    }
    return result;
  }
}

class SmtpConfig {
  const SmtpConfig({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.useSsl,
    required this.allowInsecure,
  });

  final String host;
  final int port;
  final String? username;
  final String? password;
  final bool useSsl;
  final bool allowInsecure;
}
