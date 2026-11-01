import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

class ReportPreview extends StatefulWidget {
  final Uint8List bytes;
  final Future<void> Function() onSave, onShare, onEmail;
  const ReportPreview({
    super.key,
    required this.bytes,
    required this.onSave,
    required this.onShare,
    required this.onEmail,
  });
  @override
  State<ReportPreview> createState() => _ReportPreviewState();
}

class _ReportPreviewState extends State<ReportPreview> {
  bool busy = false;
  Future<void> perform(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('操作を完了できませんでした：$error')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('PDFを確認')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: busy ? null : () => perform(widget.onSave),
                  icon: const Icon(Icons.save_alt),
                  label: const Text('保存'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: busy ? null : () => perform(widget.onShare),
                  icon: const Icon(Icons.ios_share),
                  label: const Text('共有'),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: busy ? null : () => perform(widget.onEmail),
              icon: const Icon(Icons.attach_email_outlined),
              label: const Text('PDFを添付してメールを作成'),
            ),
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        Expanded(
          child: PdfPreview(
            build: (_) => widget.bytes,
            initialPageFormat: PdfPageFormat.a3.landscape,
            useActions: false,
            canDebug: false,
            allowPrinting: false,
            allowSharing: false,
            canChangeOrientation: false,
            canChangePageFormat: false,
          ),
        ),
      ],
    ),
  );
}
