import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../application/controller.dart';

class NotificationDiagnosticsPage extends StatefulWidget {
  final AppController controller;
  const NotificationDiagnosticsPage({super.key, required this.controller});
  @override
  State<NotificationDiagnosticsPage> createState() =>
      _NotificationDiagnosticsPageState();
}

class _NotificationDiagnosticsPageState
    extends State<NotificationDiagnosticsPage> {
  bool busy = false;
  Future<void> operate(Future<void> Function() action) async {
    setState(() => busy = true);
    try {
      await action();
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('通知の確認に失敗しました。下の診断ログをご確認ください。')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = widget.controller.notifications;
    return Scaffold(
      appBar: AppBar(title: const Text('通知の診断（確認用）')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              service.ready ? '通知の準備：完了' : '通知の準備：未完了',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            Text(service.permissionStatus),
            if (service.initFailure != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(service.initFailure!.summary),
              ),
            const SizedBox(height: 12),
            const Text(
              '「再診断」→「テスト通知」の順でお試しください。デモモードでもテスト通知だけを表示します。服用記録は変更しません。',
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              key: const ValueKey('retry-notifications'),
              onPressed: busy
                  ? null
                  : () => operate(() => widget.controller.retryNotifications()),
              icon: const Icon(Icons.refresh),
              label: const Text('再診断'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('show-test-notification'),
              onPressed: busy
                  ? null
                  : () => operate(service.showTestNotification),
              icon: const Icon(Icons.notifications_active_outlined),
              label: const Text('テスト通知を表示'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('copy-notification-diagnostics'),
              onPressed: busy
                  ? null
                  : () async {
                      await Clipboard.setData(
                        ClipboardData(text: service.diagnosticReport),
                      );
                      if (context.mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('コピーしました。このチャットに貼り付けてください。'),
                          ),
                        );
                    },
              icon: const Icon(Icons.copy),
              label: const Text('診断ログをコピー'),
            ),
            if (busy) const LinearProgressIndicator(),
            const SizedBox(height: 16),
            const Text(
              '診断ログには端末名・Androidバージョン・タイムゾーン・通知処理の結果を含みます。氏名や服用記録は出力しません。',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            SelectableText(
              service.diagnosticReport,
              key: const ValueKey('notification-diagnostic-report'),
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
    );
  }
}
