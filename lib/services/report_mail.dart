import 'dart:typed_data';

import 'package:flutter_email_sender/flutter_email_sender.dart';

/// Opens the user's mail composer; this service never sends in the background.
class ReportMailService {
  final Future<EmailCapabilities> Function() capabilities;
  final Future<EmailSendResult> Function(Email) openComposer;
  ReportMailService({
    Future<EmailCapabilities> Function()? capabilities,
    Future<EmailSendResult> Function(Email)? openComposer,
  }) : capabilities = capabilities ?? FlutterEmailSender.getCapabilities,
       openComposer = openComposer ?? FlutterEmailSender.send;

  Future<void> compose({
    required Uint8List pdf,
    required String recipient,
    required String subject,
    required String body,
    required String fileName,
    required Future<void> Function() shareFallback,
  }) async {
    if (pdf.length < 4 || String.fromCharCodes(pdf.take(4)) != '%PDF') {
      throw ArgumentError('添付するPDFを作成できませんでした。PDFを作成し直してください。');
    }
    var fallback = false;
    try {
      final support = await capabilities();
      if (!support.canSend ||
          !support.supportsAttachments ||
          !support.supportsSubject ||
          !support.supportsPlainTextBody) {
        fallback = true;
      } else {
        await openComposer(
          Email(
            recipients: recipient.trim().isEmpty
                ? const []
                : [recipient.trim()],
            subject: subject,
            body: body,
            isHTML: false,
            attachments: [
              EmailAttachment.data(
                pdf,
                fileName: fileName,
                mimeType: 'application/pdf',
              ),
            ],
          ),
        );
      }
    } on FlutterEmailSenderNotAvailableException {
      fallback = true;
    } on FlutterEmailSenderUnsupportedFeatureException {
      fallback = true;
    } on FlutterEmailSenderPlatformException {
      throw ArgumentError('PDF付きメールを開けませんでした。「共有」または「保存」からPDFを渡してください。');
    }
    // Keep the PDF in the fallback too; never silently downgrade to mailto.
    if (fallback) await shareFallback();
  }
}
