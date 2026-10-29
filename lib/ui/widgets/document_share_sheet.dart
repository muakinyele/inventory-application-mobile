import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/design.dart';
import '../../core/formatters.dart';
import '../../core/palette.dart';
import '../../data/browser_download.dart';
import '../../data/export_service.dart';
import '../../data/order_document.dart';
import '../../data/share_targets.dart';
import '../../state/inventory_controller.dart';
import 'app_message.dart';

/// Everything one document needs to be sent somewhere.
///
/// Built by the page that owns the document, so this widget knows nothing
/// about receipts or invoices — only that it has a name, a written summary,
/// a way to render a PDF, and somewhere to open it on screen.
class ShareableDocument {
  const ShareableDocument({
    required this.title,
    required this.filename,
    required this.summary,
    required this.buildPdf,
    this.onView,
    this.recipientPhone,
    this.recipientEmail,
  });

  /// "Receipt RC-0042" — used as the email subject and the sheet's heading.
  final String title;

  /// The name the PDF leaves with.
  final String filename;

  /// What a deep link carries. A few lines of plain text: what the document
  /// is, who it is for, what it comes to. It is the message somebody would
  /// otherwise type out, not a description of the attachment — because on
  /// WhatsApp there is no attachment.
  final String summary;

  final Future<Uint8List> Function() buildPdf;

  /// Opens the document on screen. Null when the caller is already there.
  final VoidCallback? onView;

  /// Prefilled where the customer's details are on file, so the common case
  /// is one tap rather than picking a contact.
  final String? recipientPhone;
  final String? recipientEmail;
}

/// Offers every way this app can get a document to somebody.
///
/// SPLIT INTO TWO GROUPS ON PURPOSE. The first sends the FILE: view it, print
/// it, save it, or hand it to another app through the system sheet — which is
/// how a PDF reaches WhatsApp, Telegram or anything else installed on a phone.
/// The second sends a MESSAGE: WhatsApp, email and SMS deep links carry text
/// and cannot carry an attachment, whatever the marketing says.
///
/// Calling both of those "share" is what makes people send an empty WhatsApp
/// message and wonder where the receipt went, so they are labelled apart and
/// the message ones say what they do.
Future<void> showDocumentShareSheet(
  BuildContext context,
  ShareableDocument document,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _ShareSheet(document: document),
  );
}

class _ShareSheet extends StatelessWidget {
  const _ShareSheet({required this.document});

  final ShareableDocument document;

  Future<void> _sharePdf(
    BuildContext context,
    Rect? origin, {
    bool download = false,
  }) async {
    final messenger = Navigator.of(context);
    try {
      final bytes = await document.buildPdf();
      const export = ExportService();
      if (download) {
        await export.shareBytes(
          filename: document.filename,
          bytes: bytes,
          mimeType: 'application/pdf',
          originRect: origin,
        );
      } else {
        await export.shareBytesWithApps(
          filename: document.filename,
          bytes: bytes,
          mimeType: 'application/pdf',
          originRect: origin,
        );
      }
      messenger.pop();
    } catch (error) {
      messenger.pop();
      if (context.mounted) {
        await showAppMessage(
          context,
          'The document could not be prepared, so nothing was sent.',
          tone: MessageTone.failure,
        );
      }
    }
  }

  Future<void> _open(BuildContext context, Uri target, String name) async {
    Navigator.of(context).pop();
    final opened = await openShareTarget(target);
    if (opened || !context.mounted) return;
    await showAppMessage(
      context,
      // Named, because "could not share" leaves somebody retrying the same
      // button. Nothing opening usually means the app is not installed, or
      // the browser blocked the new tab.
      '$name could not be opened. It may not be installed on this device, '
      'or the browser may have blocked the new window.',
      tone: MessageTone.failure,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.xl,
                Insets.lg,
                Insets.xl,
                Insets.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    document.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Send the document, or send a message about it.',
                    style: TextStyle(fontSize: 13, color: p.inkSecondary),
                  ),
                ],
              ),
            ),

            _GroupLabel(text: 'The document'),
            if (document.onView != null)
              _ShareTile(
                icon: Icons.visibility_outlined,
                label: 'View it',
                note: 'See the pages as they will print',
                onTap: () {
                  Navigator.of(context).pop();
                  document.onView!();
                },
              ),
            // In a browser, saving and sharing are different things: the
            // system share sheet on a Mac has no way to save. On a phone the
            // share sheet is how a file gets saved, so one tile does both.
            if (canDownloadInBrowser)
              Builder(
                builder: (tileContext) => _ShareTile(
                  icon: Icons.file_download_outlined,
                  label: 'Download the PDF',
                  note: 'Saves it to your Downloads folder',
                  onTap: () => _sharePdf(
                    tileContext,
                    shareOriginOf(tileContext),
                    download: true,
                  ),
                ),
              ),
            Builder(
              builder: (tileContext) => _ShareTile(
                icon: Icons.ios_share,
                label: canDownloadInBrowser
                    ? 'Share the PDF'
                    : 'Share or save the PDF',
                // On a phone the system sheet lists WhatsApp, Telegram, Drive
                // and mail, and the file really is attached.
                note: canDownloadInBrowser
                    ? 'Hands the file to another app'
                    : 'Hands the file to another app, or saves it',
                onTap: () => _sharePdf(tileContext, shareOriginOf(tileContext)),
              ),
            ),

            const SizedBox(height: Insets.sm),
            _GroupLabel(text: 'A message about it'),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Insets.xl,
                0,
                Insets.xl,
                Insets.sm,
              ),
              child: Text(
                'These carry the details as text. To send the PDF itself, use '
                'the options above.',
                style: TextStyle(fontSize: 12.5, color: p.inkMuted),
              ),
            ),
            _ShareTile(
              icon: Icons.chat_bubble_outline,
              label: 'WhatsApp',
              note: document.recipientPhone?.isNotEmpty == true
                  ? 'To ${document.recipientPhone}'
                  : 'Pick a contact in WhatsApp',
              onTap: () => _open(
                context,
                whatsAppUri(document.summary, phone: document.recipientPhone),
                'WhatsApp',
              ),
            ),
            _ShareTile(
              icon: Icons.mail_outline,
              label: 'Email',
              note: document.recipientEmail?.isNotEmpty == true
                  ? 'To ${document.recipientEmail}'
                  : 'Opens your mail app',
              onTap: () => _open(
                context,
                mailtoUri(
                  subject: document.title,
                  body: document.summary,
                  to: document.recipientEmail,
                ),
                'Your mail app',
              ),
            ),
            _ShareTile(
              icon: Icons.sms_outlined,
              label: 'Text message',
              note: 'Opens your messages app',
              onTap: () => _open(
                context,
                smsUri(document.summary, phone: document.recipientPhone),
                'Your messages app',
              ),
            ),
            _ShareTile(
              icon: Icons.copy_all_outlined,
              label: 'Copy the details',
              note: 'Paste anywhere — any app, any platform',
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: document.summary));
                if (!context.mounted) return;
                Navigator.of(context).pop();
                await showAppMessage(context, 'Copied. Paste it anywhere.');
              },
            ),
            const SizedBox(height: Insets.lg),
          ],
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.md, Insets.xl, 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: context.palette.inkMuted,
        ),
      ),
    );
  }
}

class _ShareTile extends StatelessWidget {
  const _ShareTile({
    required this.icon,
    required this.label,
    required this.note,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String note;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: Insets.xl),
      leading: Icon(icon, color: p.accent),
      title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(note, style: TextStyle(fontSize: 12.5, color: p.inkMuted)),
      onTap: onTap,
    );
  }
}

/// Offers a purchase or sales order as a document.
///
/// Shared by both order screens rather than written twice: they send the same
/// page to different people, and a supplier's copy drifting apart from a
/// customer's would be nobody's decision.
///
/// The written summary matters more here than on a receipt. An order is
/// forwarded to ask a question about it — "can you do these by Friday" — so
/// the message has to carry the lines and the total, not just name a file.
Future<void> shareOrderDocument(
  BuildContext context,
  InventoryController controller,
  OrderDocumentData data, {
  required String contactPhone,
  required String contactEmail,
}) {
  final settings = controller.settings;
  final doc = OrderDocument(data, settings);
  final kind = data.kind.toLowerCase();

  final lines = [
    '${settings.companyName} — $kind ${data.reference}',
    '${data.partyLabel}: ${data.partyName}',
    'Status: ${data.status}',
    if (data.dueAt != null) '${data.dueLabel}: ${longDate(data.dueAt!)}',
    '',
    for (final line in data.lines)
      '${number(line.quantity)} × ${line.itemName} — '
          '${money(line.lineTotal, settings.currency)}',
    '',
    'Order total: ${money(data.total, settings.currency)}',
    if (data.notes.trim().isNotEmpty) ...['', data.notes.trim()],
  ];

  return showDocumentShareSheet(
    context,
    ShareableDocument(
      // Sentence case: "Purchase order PO-0007" reads as a title, where the
      // document's own all-caps heading would read as shouting in a subject
      // line or a WhatsApp message.
      title: '${kind[0].toUpperCase()}${kind.substring(1)} ${data.reference}',
      filename: doc.filename('pdf'),
      summary: lines.join('\n'),
      buildPdf: doc.toPdf,
      recipientPhone: contactPhone,
      recipientEmail: contactEmail,
    ),
  );
}
