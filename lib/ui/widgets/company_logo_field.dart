import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/palette.dart';
import '../../data/logo_service.dart';
import '../../models/app_settings.dart';

/// Upload, preview and remove the logo printed on invoices and receipts.
///
/// Validation happens in [LogoService] against the file's bytes, and whatever
/// it refuses is reported here in its own words — the service writes the
/// sentence, because it is the only thing that knows *why* a file was turned
/// down.
class CompanyLogoField extends StatefulWidget {
  const CompanyLogoField({
    super.key,
    required this.settings,
    required this.onChanged,
    this.service = const LogoService(),
  });

  final AppSettings settings;

  /// Called with the new base64 logo, or an empty string to remove it.
  final ValueChanged<String> onChanged;

  /// Injectable so a test can drive the field without a file picker.
  final LogoService service;

  @override
  State<CompanyLogoField> createState() => _CompanyLogoFieldState();
}

class _CompanyLogoFieldState extends State<CompanyLogoField> {
  bool _busy = false;
  String? _error;
  String? _note;

  Future<void> _upload() async {
    setState(() {
      _busy = true;
      _error = null;
      _note = null;
    });

    final result = await widget.service.pick();
    if (!mounted) return;

    switch (result) {
      case LogoCancelled():
        setState(() => _busy = false);

      case LogoRejected(:final message):
        setState(() {
          _busy = false;
          _error = message;
        });

      case LogoAccepted(
        :final encoded,
        :final width,
        :final height,
        :final originalBytes,
        :final storedBytes,
      ):
        widget.onChanged(encoded);
        setState(() {
          _busy = false;
          // Says what was actually kept. A 4 MB upload becoming a 40 KB
          // stored image is surprising enough to be worth stating.
          _note = storedBytes < originalBytes
              ? 'Saved at $width×$height, '
                    '${formatBytes(storedBytes)} '
                    '(from ${formatBytes(originalBytes)}).'
              : 'Saved at $width×$height, ${formatBytes(storedBytes)}.';
        });
    }
  }

  void _remove() {
    widget.onChanged('');
    setState(() {
      _error = null;
      _note = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final settings = widget.settings;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _LogoPreview(settings: settings),
            const SizedBox(width: Insets.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Company logo',
                    style: TextStyle(fontWeight: FontWeight.w600, color: p.ink),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Printed at the head of every invoice and receipt. '
                    'JPEG or PNG, up to ${formatBytes(LogoService.maxBytes)}. '
                    'A PNG with a transparent background prints best.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: p.inkMuted,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: Insets.md),
                  Wrap(
                    spacing: Insets.sm,
                    runSpacing: Insets.sm,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _upload,
                        icon: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                ),
                              )
                            : const Icon(Icons.upload_rounded, size: 18),
                        label: Text(
                          settings.hasCompanyLogo
                              ? 'Replace logo'
                              : 'Upload logo',
                        ),
                      ),
                      if (settings.hasCompanyLogo)
                        TextButton.icon(
                          onPressed: _busy ? null : _remove,
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            size: 18,
                          ),
                          label: const Text('Remove'),
                          style: TextButton.styleFrom(
                            foregroundColor: p.critical,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),

        if (_error != null) ...[
          const SizedBox(height: Insets.md),
          _Notice(
            message: _error!,
            colour: p.critical,
            wash: p.criticalWash,
            icon: Icons.error_rounded,
          ),
        ],
        if (_note != null) ...[
          const SizedBox(height: Insets.md),
          _Notice(
            message: _note!,
            colour: p.goodText,
            wash: p.goodWash,
            icon: Icons.check_circle_rounded,
          ),
        ],
      ],
    );
  }
}

/// The preview tile — the uploaded logo, or a placeholder saying there is none.
class _LogoPreview extends StatelessWidget {
  const _LogoPreview({required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return Container(
      width: 104,
      height: 104,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(Insets.sm),
      decoration: BoxDecoration(
        // A logo is usually transparent, and most are dark. A pale, flat tile
        // is the honest backdrop: it is what the paper looks like.
        color: Colors.white,
        borderRadius: BorderRadius.circular(Radii.tile),
        border: Border.all(color: p.line),
      ),
      child: settings.hasCompanyLogo
          ? _decoded(context)
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.image_outlined, size: 22, color: p.inkMuted),
                const SizedBox(height: Insets.xs),
                Text(
                  'No logo',
                  style: TextStyle(fontSize: 11.5, color: p.inkMuted),
                ),
              ],
            ),
    );
  }

  Widget _decoded(BuildContext context) {
    final p = context.palette;
    try {
      return Image.memory(
        base64Decode(settings.companyLogo),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        // A stored image that will not decode is shown as a broken preview
        // rather than a red error box, and the documents fall back to the
        // company name for the same reason.
        errorBuilder: (context, _, _) =>
            Icon(Icons.broken_image_outlined, size: 22, color: p.critical),
      );
    } catch (_) {
      return Icon(Icons.broken_image_outlined, size: 22, color: p.critical);
    }
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.message,
    required this.colour,
    required this.wash,
    required this.icon,
  });

  final String message;
  final Color colour;
  final Color wash;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: wash,
        borderRadius: BorderRadius.circular(Radii.control),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 17, color: colour),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: colour, height: 1.45, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
