import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:malaria_care/domain/model.dart';
import 'package:malaria_care/domain/engine.dart';

void main() {
  test('実際のv0.1架空バックアップを全履歴保持でv3へ移行', () {
    final data = AppData.parse(
      File('test/fixtures/v1-backup.json').readAsStringSync(),
    );
    expect(data.medicines.length, 2);
    expect(data.doses, isNotEmpty);
    expect(data.losses, isEmpty);
    expect(data.hasOverlappingMedicines, true);
    expect(data.toJson()['schemaVersion'], 3);
    data.validate();
    final engine = MedicationEngine(data);
    engine.materialize(DateTime(2026, 11, 3, 9));
    expect(AppData.parse(data.export()).doses.length, data.doses.length);
  });
}
