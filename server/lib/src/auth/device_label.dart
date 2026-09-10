/// Turns a User-Agent into a short, human-readable device description.
///
/// Deliberately lossy. The raw header is a high-entropy fingerprint, and the
/// only thing the security screen actually needs is enough for someone to
/// recognise their own laptop — so the header is reduced to a browser and an
/// operating system and the original is never stored (§17).
String describeDevice(String? userAgent) {
  if (userAgent == null || userAgent.trim().isEmpty) return 'Unknown device';

  final ua = userAgent;
  final browser = _firstMatch(ua, const {
    // Order matters: Edge and Opera both claim to be Chrome, and Chrome
    // claims to be Safari, so the most specific pattern has to win.
    'Edge': r'Edg[A-Z]?/',
    'Opera': r'OPR/|Opera',
    'Samsung Internet': r'SamsungBrowser/',
    'Firefox': r'Firefox/|FxiOS/',
    'Chrome': r'Chrome/|CriOS/',
    'Safari': r'Safari/',
  });

  final platform = _firstMatch(ua, const {
    'iPhone': r'iPhone',
    'iPad': r'iPad',
    'Android': r'Android',
    'Windows': r'Windows NT',
    'macOS': r'Macintosh|Mac OS X',
    'Linux': r'Linux',
  });

  // The Flutter app identifies itself, so it does not have to be guessed at
  // from a browser string it does not really have.
  if (RegExp(r'Stockpile/', caseSensitive: false).hasMatch(ua)) {
    final app = platform ?? 'Mobile';
    return 'Stockpile app ($app)';
  }

  if (browser == null && platform == null) return 'Unknown device';
  if (browser == null) return platform!;
  if (platform == null) return browser;
  return '$browser on $platform';
}

String? _firstMatch(String value, Map<String, String> patterns) {
  for (final entry in patterns.entries) {
    if (RegExp(entry.value).hasMatch(value)) return entry.key;
  }
  return null;
}
