import 'package:flutter_test/flutter_test.dart';
import 'package:malaria_care/domain/engine.dart';
import 'package:malaria_care/services/store.dart';

import 'engine_test.dart' show fixture;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('TC20/21 保存後の新規読込で同一データ・モード保持（保存契約テスト）', () async {
    final store = MemoryStore(),
        data = fixture(),
        now = DateTime(2026, 11, 4, 21);
    final engine = MedicationEngine(data);
    engine.materialize(now);
    await store.save(data, false);
    await store.saveMode(false);
    final loaded = await store.load(false);
    expect(loaded!.export(), data.export());
    expect(await store.loadMode(), false);
    expect(MedicationEngine(loaded).balance('a', now, now), 27);
    expect(await store.load(true), isNull);
  });
}
