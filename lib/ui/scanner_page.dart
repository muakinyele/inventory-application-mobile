import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/palette.dart';

/// Full-screen camera scanner with a manual-entry fallback.
///
/// Pops with the scanned code, or null if the user backs out. Camera scanning
/// is unavailable on desktop and unreliable on some web browsers, so the
/// manual field is always reachable rather than being an error path.
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  static bool get cameraSupported {
    if (kIsWeb) return true;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.macOS => true,
      _ => false,
    };
  }

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  MobileScannerController? _controller;
  final _manual = TextEditingController();
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    if (ScannerPage.cameraSupported) {
      _controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
        formats: const [
          BarcodeFormat.ean13,
          BarcodeFormat.ean8,
          BarcodeFormat.code128,
          BarcodeFormat.code39,
          BarcodeFormat.upcA,
          BarcodeFormat.upcE,
          BarcodeFormat.qrCode,
        ],
      );
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _manual.dispose();
    super.dispose();
  }

  void _submit(String code) {
    final trimmed = code.trim();
    if (trimmed.isEmpty || _handled) return;
    _handled = true;
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(trimmed);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(
          'Scan barcode',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        actions: [
          if (controller != null)
            IconButton(
              tooltip: 'Toggle torch',
              onPressed: () => controller.toggleTorch(),
              icon: const Icon(Icons.flashlight_on_outlined),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: controller == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Camera scanning is not available on this platform. '
                        'Enter the code by hand below.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: p.inkSecondary),
                      ),
                    ),
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      MobileScanner(
                        controller: controller,
                        onDetect: (capture) {
                          for (final barcode in capture.barcodes) {
                            final value = barcode.rawValue;
                            if (value != null && value.isNotEmpty) {
                              _submit(value);
                              return;
                            }
                          }
                        },
                        errorBuilder: (context, error) => Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'Camera unavailable: ${error.errorCode.name}. '
                              'Enter the code by hand below.',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ),
                      IgnorePointer(
                        child: Center(
                          child: FractionallySizedBox(
                            widthFactor: 0.78,
                            heightFactor: 0.42,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.85),
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const Positioned(
                        left: 0,
                        right: 0,
                        bottom: 14,
                        child: Text(
                          'Point the camera at a barcode',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            shadows: [
                              Shadow(blurRadius: 4, color: Colors.black87),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _manual,
                      keyboardType: TextInputType.number,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(
                        labelText: 'Enter code manually',
                        hintText: 'e.g. 8801234567890',
                      ),
                      onSubmitted: _submit,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 48,
                    child: FilledButton(
                      onPressed: () => _submit(_manual.text),
                      child: const Text('Use'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
