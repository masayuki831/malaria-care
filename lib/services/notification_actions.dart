import '../domain/engine.dart';
import '../domain/model.dart';
import 'store.dart';

/// Shared persistence rules for notification buttons, with no screen dependency.
class NotificationActionProcessor {
  final DataStore store;
  final Future<void> Function(String payload) cancel;
  NotificationActionProcessor(this.store, {required this.cancel});

  Future<bool> handle(String? payload, String? action, DateTime now) async {
    if (payload == null) return false;
    final reminder =
        payload.startsWith('reminder:') || payload == 'preview:reminder';
    final previous = payload.startsWith('check:') || payload == 'preview:check';
    if (!(reminder && action == 'reminder_confirm') &&
        !(previous &&
            (action == 'previous_taken' || action == 'previous_missed'))) {
      return false;
    }
    if (payload.startsWith('preview:')) {
      await cancel(payload);
      return true;
    }
    // Scheduled OS notifications belong only to the personal namespace.
    final id = payload.substring(payload.indexOf(':') + 1);
    final separator = id.lastIndexOf('@');
    final date = separator < 0
        ? null
        : DateTime.tryParse(id.substring(separator + 1));
    if (date == null) return false;
    var found = false;
    final result = await store.update(false, (data) {
      final engine = MedicationEngine(data);
      final dose = engine
          .generate(date, date)
          .where((d) => d.id == id)
          .firstOrNull;
      if (dose == null) return;
      found = true;
      if (reminder) {
        if (!data.reminderAcknowledgements.contains(payload)) {
          data.reminderAcknowledgements.add(payload);
        }
      } else if (data.nextDay &&
          day(date).isBefore(day(now)) &&
          dose.explicit == null &&
          engine.effectiveStatus(dose, now) == DoseStatus.assumed &&
          action == 'previous_missed') {
        engine.record(dose, DoseStatus.missed, now);
      }
      // "Taken" and duplicate/obsolete answers never overwrite corrected history.
    });
    if (result == null || !found) return false;
    // Only dismiss after the transaction committed successfully.
    await cancel(payload);
    if (previous) await cancel('reminder:$id');
    return true;
  }
}
