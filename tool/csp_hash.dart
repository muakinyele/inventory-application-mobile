import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Prints the CSP source expression for index.html's inline script.
///
///     dart run tool/csp_hash.dart build/web/index.html
///
/// WHY THIS IS COMPUTED RATHER THAN WRITTEN DOWN. The page carries one inline
/// script — the boot splash — and the policy allows it by hash so that
/// `'unsafe-inline'`, which would allow every *other* inline script too, is
/// not needed. A hash pasted into the config by hand goes stale the moment the
/// splash is edited, and a stale hash does not fail loudly: the browser
/// silently refuses the script, the overlay is never removed, and the app
/// looks like it hung on a blank page. So the build derives it from the file
/// it is actually shipping.
///
/// Exits non-zero when the page does not hold exactly one inline script, so a
/// second one added later fails the build instead of being quietly unallowed.
void main(List<String> arguments) {
  final path = arguments.isEmpty ? 'build/web/index.html' : arguments.first;
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('csp_hash: no such file: $path');
    exit(1);
  }

  final html = file.readAsStringSync();

  // Inline only: a tag carrying `src` is a fetched script and is covered by
  // the origin part of the policy instead.
  final pattern = RegExp(
    r'<script(?![^>]*\ssrc=)[^>]*>([\s\S]*?)</script>',
    caseSensitive: false,
  );
  final matches = pattern.allMatches(html).toList();

  if (matches.length != 1) {
    stderr.writeln(
      'csp_hash: expected exactly one inline script in $path, '
      'found ${matches.length}. The policy allows one by hash; a new one has '
      'to be hashed too, or moved to a file of its own.',
    );
    exit(1);
  }

  // Hashed over the bytes BETWEEN the tags, exactly as they appear — which is
  // what a browser does. Any difference in whitespace is a different hash and
  // a refused script.
  final source = matches.single.group(1)!;
  final digest = sha256.convert(utf8.encode(source));
  stdout.write('sha256-${base64.encode(digest.bytes)}');
}
