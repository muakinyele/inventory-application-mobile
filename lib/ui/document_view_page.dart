import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

import '../core/design.dart';
import '../core/palette.dart';
import '../data/export_service.dart';
import 'widgets/app_message.dart';
import 'widgets/empty_state.dart';
import 'widgets/page_header.dart';

/// Widest a page is drawn, however much room there is. Past this a sheet of A4
/// is bigger on screen than it is on the desk.
const _maxPageWidth = 760.0;

/// Shows a generated PDF as it will actually print — the rendered pages
/// themselves, not a second drawing of the same figures in Flutter widgets —
/// so what is checked on screen is exactly what leaves the app.
///
/// Reached by its own URL, like every other page here, rather than pushed on
/// top of the shell: the browser's back button then behaves, and a document
/// can be linked to.
class DocumentViewPage extends StatefulWidget {
  const DocumentViewPage({
    super.key,
    required this.title,
    required this.filename,
    required this.build,
    this.subtitle,
    this.pageFormat = PdfPageFormat.a4,
  });

  final String title;
  final String? subtitle;

  /// The name the file leaves with when it is downloaded from here.
  final String filename;

  /// Builds the document. Called once and held, so paging, the download and
  /// the print all work off the one render.
  final Future<Uint8List> Function() build;

  final PdfPageFormat pageFormat;

  @override
  State<DocumentViewPage> createState() => _DocumentViewPageState();
}

class _DocumentViewPageState extends State<DocumentViewPage> {
  Future<Uint8List>? _document;
  bool _canPrint = false;
  bool _sharing = false;

  /// Builds the document once and hands back the same bytes thereafter.
  ///
  /// A method rather than a closure written inline in [build]: the preview
  /// re-renders whenever this callback is not the object it saw last time,
  /// and a fresh closure per rebuild would raster the pages over and over.
  Future<Uint8List> _render(PdfPageFormat _) => _document ??= widget.build();

  @override
  void initState() {
    super.initState();
    // Printing is a real printer or a system print dialog: present on the
    // phones and desktops, absent in a headless test. Ask before offering it.
    Printing.info()
        .then((info) {
          if (mounted) setState(() => _canPrint = info.canPrint);
        })
        .catchError((_) => null);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final media = MediaQuery.of(context);
    final wide = media.size.width >= Breakpoints.sidebar;
    final gutter = wide ? Insets.pageWide : Insets.pageNarrow;

    return Scaffold(
      backgroundColor: p.plane,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(gutter, Insets.xl, gutter, 0),
              child: PageHeader(
                title: widget.title,
                subtitle: widget.subtitle,
                showBack: true,
                actions: [
                  if (_canPrint)
                    OutlinedButton.icon(
                      onPressed: _print,
                      icon: const Icon(Icons.print_outlined, size: 18),
                      label: const Text('Print'),
                    ),
                  Builder(
                    builder: (buttonContext) => FilledButton.icon(
                      onPressed: _sharing
                          ? null
                          : () => _download(shareOriginOf(buttonContext)),
                      icon: _sharing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.download_outlined, size: 18),
                      label: const Text('Download PDF'),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: PdfPreviewCustom(
                build: _render,
                pageFormat: widget.pageFormat,
                dpi: _dpi(media),
                maxPageWidth: _maxPageWidth,
                padding: EdgeInsets.symmetric(horizontal: gutter),
                previewPageMargin: const EdgeInsets.only(bottom: Insets.lg),
                scrollViewDecoration: BoxDecoration(color: p.surfaceSunken),
                pdfPreviewPageDecoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(Radii.control),
                  border: Border.all(color: p.line),
                ),
                onError: (context, error) => _CannotShow(error: error),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// How finely to raster, worked out here rather than left to the preview.
  ///
  /// Left unset it reads the screen size off a timer, from a context that may
  /// have gone by the time the timer fires. Measured in `build`, where the
  /// context is what it claims to be, and capped so a high-density screen does
  /// not ask for a page image several times the size of the window.
  double _dpi(MediaQueryData media) {
    final width = min(media.size.width - Insets.lg, _maxPageWidth);
    final dpi =
        width *
        media.devicePixelRatio /
        widget.pageFormat.width *
        PdfPageFormat.inch;
    return dpi.clamp(72.0, 300.0);
  }

  Future<void> _print() async {
    try {
      await Printing.layoutPdf(
        onLayout: _render,
        name: widget.filename,
        format: widget.pageFormat,
      );
    } catch (error) {
      if (mounted) {
        await showAppMessage(
          context,
          'That document could not be sent to a printer: $error',
          tone: MessageTone.failure,
        );
      }
    }
  }

  Future<void> _download(Rect? origin) async {
    setState(() => _sharing = true);
    try {
      await const ExportService().shareBytes(
        filename: widget.filename,
        bytes: await _render(widget.pageFormat),
        mimeType: 'application/pdf',
        originRect: origin,
      );
    } catch (error) {
      if (mounted) {
        await showAppMessage(
          context,
          'That file could not be produced: $error',
          tone: MessageTone.failure,
        );
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }
}

/// Rendering a PDF on screen needs the platform's own drawing, which not
/// every one of them offers. The document itself is still fine — it can be
/// downloaded from the button above.
class _CannotShow extends StatelessWidget {
  const _CannotShow({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return EmptyState(
      icon: Icons.visibility_off_outlined,
      title: 'This document cannot be shown here',
      body: 'Download it instead — the file itself is fine.\n$error',
    );
  }
}

/// Shown when the document's own record has gone while it was being read.
class DocumentGone extends StatelessWidget {
  const DocumentGone({super.key, required this.what, required this.onBack});

  final String what;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(leading: const BackButton()),
      body: EmptyState(
        icon: Icons.help_outline,
        title: '$what not found',
        body: 'It may have been deleted.',
        action: FilledButton(onPressed: onBack, child: const Text('Go back')),
      ),
    );
  }
}
