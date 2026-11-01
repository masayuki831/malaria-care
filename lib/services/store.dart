import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain/model.dart';

abstract class DataStore {
  Future<bool> loadMode();
  Future<void> saveMode(bool demo);
  Future<AppData?> load(bool demo);
  Future<void> save(AppData data, bool demo);

  /// Mutations always start from the latest saved snapshot.
  Future<AppData?> update(
    bool demo,
    void Function(AppData) change, {
    AppData Function()? ifAbsent,
  }) async {
    final latest = await load(demo) ?? ifAbsent?.call();
    if (latest == null) return null;
    change(latest);
    await save(latest, demo);
    return latest;
  }
}

class SqliteStore extends DataStore {
  Database? _db;
  Future<Database> get db async => _db ??= await openDatabase(
    p.join(await getDatabasesPath(), 'malaria_care.db'),
    version: 1,
    onCreate: (db, _) async {
      await db.execute(
        'CREATE TABLE snapshots (namespace TEXT PRIMARY KEY, payload TEXT NOT NULL)',
      );
    },
  );
  @override
  Future<bool> loadMode() async {
    final rows = await (await db).query(
      'snapshots',
      where: 'namespace = ?',
      whereArgs: ['mode'],
    );
    return rows.isNotEmpty && rows.single['payload'] == 'demo';
  }

  @override
  Future<void> saveMode(bool demo) async {
    await (await db).insert('snapshots', {
      'namespace': 'mode',
      'payload': demo ? 'demo' : 'personal',
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<AppData?> load(bool demo) async {
    final rows = await (await db).query(
      'snapshots',
      where: 'namespace = ?',
      whereArgs: [demo ? 'demo' : 'personal'],
    );
    return rows.isEmpty
        ? null
        : AppData.parse(rows.single['payload'] as String);
  }

  @override
  Future<void> save(AppData data, bool demo) async {
    data.validate();
    await (await db).transaction((txn) async {
      await txn.insert('snapshots', {
        'namespace': demo ? 'demo' : 'personal',
        'payload': data.export(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  @override
  Future<AppData?> update(
    bool demo,
    void Function(AppData) change, {
    AppData Function()? ifAbsent,
  }) async => (await db).transaction((txn) async {
    final namespace = demo ? 'demo' : 'personal';
    final rows = await txn.query(
      'snapshots',
      where: 'namespace = ?',
      whereArgs: [namespace],
    );
    final latest = rows.isEmpty
        ? ifAbsent?.call()
        : AppData.parse(rows.single['payload'] as String);
    if (latest == null) return null;
    change(latest);
    latest.validate();
    await txn.insert('snapshots', {
      'namespace': namespace,
      'payload': latest.export(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    return latest;
  });
}

/// Test injection; the mobile entry point always selects SQLite.
class MemoryStore extends DataStore {
  final Map<bool, String> _saved = {};
  bool mode = true;
  Future<void> _updates = Future<void>.value();
  @override
  Future<AppData?> update(
    bool demo,
    void Function(AppData) change, {
    AppData Function()? ifAbsent,
  }) {
    final operation = _updates.then(
      (_) => super.update(demo, change, ifAbsent: ifAbsent),
    );
    _updates = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  @override
  Future<bool> loadMode() async => mode;
  @override
  Future<void> saveMode(bool demo) async {
    mode = demo;
  }

  @override
  Future<AppData?> load(bool demo) async =>
      _saved[demo] == null ? null : AppData.parse(_saved[demo]!);
  @override
  Future<void> save(AppData data, bool demo) async {
    _saved[demo] = data.export();
  }
}

DataStore defaultStore() => kIsWeb ? MemoryStore() : SqliteStore();
