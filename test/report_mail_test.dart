import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_email_sender/flutter_email_sender.dart';
import 'package:malaria_care/application/controller.dart';
import 'package:malaria_care/main.dart';
import 'package:malaria_care/services/report_mail.dart';
import 'package:malaria_care/services/store.dart';

import 'widget_test.dart' show TestNotifications;

const supported = EmailCapabilities(
  canSend: true,
  supportsCc: true,
  supportsBcc: true,
  supportsSubject: true,
  supportsPlainTextBody: true,
  supportsHtmlBody: true,
  supportsAttachments: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final pdf = File('sample-report.pdf').readAsBytesSync();
  Future<void> compose(
    ReportMailService service, {
    Future<void> Function()? fallback,
  }) => service.compose(
    pdf: pdf,
    recipient: ' report@example.invalid ',
    subject: '服薬報告（テスト）',
    body: 'ご担当者様\n報告本文\n署名',
    fileName: 'medication-report-2026-11-03.pdf',
    shareFallback:
        fallback ??
        () async {
          fail('Unexpected fallback');
        },
  );

  test('メール作成へ実PDF・ファイル名・宛先・日本語件名・本文をまとめて渡す', () async {
    Email? captured;
    final service = ReportMailService(
      capabilities: () async => supported,
      openComposer: (email) async {
        captured = email;
        return EmailSendResult.unknown;
      },
    );
    await compose(service);
    expect(captured!.recipients, ['report@example.invalid']);
    expect(captured!.subject, '服薬報告（テスト）');
    expect(captured!.body, 'ご担当者様\n報告本文\n署名');
    expect(captured!.isHTML, false);
    expect(captured!.attachments.single.data, orderedEquals(pdf));
    expect(
      captured!.attachments.single.fileName,
      'medication-report-2026-11-03.pdf',
    );
    expect(captured!.attachments.single.mimeType, 'application/pdf');
  });
  for (final support in [
    const EmailCapabilities.none(),
    const EmailCapabilities.mailto(canSend: true),
  ]) {
    test(
      '${support.canSend ? '添付非対応' : 'メール利用不可'}なら添付なしメールを開かずPDF共有へ進む',
      () async {
        var shared = 0;
        final service = ReportMailService(
          capabilities: () async => support,
          openComposer: (_) async {
            fail('An attachment-free mail must not be opened');
          },
        );
        await compose(
          service,
          fallback: () async {
            shared++;
          },
        );
        expect(shared, 1);
      },
    );
  }
  for (final error in [
    const FlutterEmailSenderNotAvailableException(),
    const FlutterEmailSenderUnsupportedFeatureException(
      unsupportedFeatures: ['attachments'],
      message: 'unsupported',
    ),
  ]) {
    test('作成直前に${error.runtimeType}となった場合もPDF共有を提供する', () async {
      var shared = 0;
      final service = ReportMailService(
        capabilities: () async => supported,
        openComposer: (_) async => throw error,
      );
      await compose(
        service,
        fallback: () async {
          shared++;
        },
      );
      expect(shared, 1);
    });
  }
  test('利用者がメール作成をキャンセルしても再作成・共有を強制しない', () async {
    var opened = 0;
    final service = ReportMailService(
      capabilities: () async => supported,
      openComposer: (_) async {
        opened++;
        return EmailSendResult.cancelled;
      },
    );
    await compose(service);
    expect(opened, 1);
  });
  test('予期しないメールエラーは自動再送せず保存・共有の案内を返す', () async {
    final service = ReportMailService(
      capabilities: () async => supported,
      openComposer: (_) async =>
          throw const FlutterEmailSenderPlatformException(
            code: 'send_failed',
            message: 'failed',
          ),
    );
    await expectLater(compose(service), throwsArgumentError);
  });
  test('PDFがない場合はメール作成しない', () async {
    final service = ReportMailService(
      capabilities: () async {
        fail('No PDF');
      },
    );
    await expectLater(
      service.compose(
        pdf: Uint8List(0),
        recipient: '',
        subject: '',
        body: '',
        fileName: 'report.pdf',
        shareFallback: () async {
          fail('No PDF');
        },
      ),
      throwsArgumentError,
    );
  });
  testWidgets('残数確認後のメールボタンで、画面から生成したPDFを添付する', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await (FontLoader(
      'NotoSansJP',
    )..addFont(rootBundle.load('assets/fonts/NotoSansJP-Regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    Email? captured;
    final mail = ReportMailService(
      capabilities: () async => supported,
      openComposer: (email) async {
        captured = email;
        return EmailSendResult.unknown;
      },
    );
    final c = AppController.withDemoForTesting(
      MemoryStore(),
      TestNotifications(),
      reportMail: mail,
    );
    await c.init();
    await c.commit((d, e) => d.mail['to'] = 'report@example.invalid');
    await tester.pumpWidget(MalariaApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.description_outlined));
    await tester.pumpAndSettle();
    final button = find.byKey(const ValueKey('compose-report-mail'));
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    final stock = find.byKey(const ValueKey('actual-stock'));
    await tester.ensureVisible(stock);
    await tester.enterText(
      stock,
      c.engine.balance('demo-daily', c.now, c.now).toString(),
    );
    await tester.pumpAndSettle();
    final check = find.byKey(const ValueKey('stock-confirmation'));
    await tester.ensureVisible(check);
    await tester.tap(check);
    await tester.pumpAndSettle();
    await tester.ensureVisible(button);
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
    await tester.tap(button);
    for (var i = 0; i < 400 && captured == null; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(captured, isNotNull);
    expect(captured!.recipients, ['report@example.invalid']);
    expect(captured!.subject, contains('マラリア予防薬'));
    expect(captured!.body, contains(c.data.profile['name']!));
    expect(
      String.fromCharCodes(captured!.attachments.single.data!.take(4)),
      '%PDF',
    );
    expect(
      captured!.attachments.single.fileName,
      'medication-report-2026-11-03.pdf',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
