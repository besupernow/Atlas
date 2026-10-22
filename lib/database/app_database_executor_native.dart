import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

QueryExecutor createDatabaseExecutor(Object? file) {
  return NativeDatabase.createInBackground(
    file as File,
    setup: (db) {
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('PRAGMA synchronous=NORMAL');
      // Enforce ProfileConnections → Connections cascades.
      // SQLite requires this on every connection — it is not persisted.
      db.execute('PRAGMA foreign_keys = ON');
    },
  );
}
