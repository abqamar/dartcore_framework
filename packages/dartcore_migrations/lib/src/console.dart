import 'dart:io';

import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';

import 'migrator.dart';
import 'schema.dart';

/// Command-line front end for migrations. Projects call it from
/// `bin/console.dart`; the `dartcore` CLI invokes that script.
///
/// Commands: `migrate`, `migrate:rollback [--step=N]`, `migrate:reset`,
/// `migrate:fresh [--seed]`, `migrate:status`, `db:seed [--class=Name]`,
/// `db:status`. Destructive commands ask for confirmation unless `--force` is
/// passed; in production `--force` is required explicitly.
class MigrationConsole {
  MigrationConsole({
    required this.database,
    required this.migrations,
    this.seeders = const [],
    this.environment = AppEnvironment.development,
    StringSink? out,
    bool Function(String question)? confirm,
  }) : _out = out ?? stdout,
       _confirm = confirm ?? _askStdin;

  final Database database;
  final List<Migration> migrations;
  final List<Seeder> seeders;
  final AppEnvironment environment;
  final StringSink _out;
  final bool Function(String) _confirm;

  static bool _askStdin(String q) {
    stdout.write('$q (yes/no) [no]: ');
    return (stdin.readLineSync() ?? '').trim().toLowerCase() == 'yes';
  }

  /// Returns a process exit code.
  Future<int> run(List<String> args) async {
    if (args.isEmpty) {
      _out.writeln(
        'No command given. Try: migrate, migrate:status, migrate:rollback, '
        'migrate:reset, migrate:fresh, db:seed, db:status, doctor',
      );
      return 64;
    }
    final cmd = args.first;
    final flags = args.skip(1).toList();
    final force = flags.contains('--force');
    final migrator = Migrator(database, migrations);
    try {
      switch (cmd) {
        case 'migrate':
          final ran = await migrator.migrate(onProgress: _out.writeln);
          _out.writeln(
            ran.isEmpty
                ? 'Nothing to migrate.'
                : 'Ran ${ran.length} migration(s).',
          );
        case 'migrate:rollback':
          final step = _intFlag(flags, '--step') ?? 1;
          if (!_ok('roll back $step batch(es)', force)) return 1;
          final ran = await migrator.rollback(
            steps: step,
            onProgress: _out.writeln,
          );
          _out.writeln(
            ran.isEmpty
                ? 'Nothing to roll back.'
                : 'Rolled back ${ran.length} migration(s).',
          );
        case 'migrate:reset':
          if (!_ok('roll back ALL migrations', force)) return 1;
          final ran = await migrator.reset(confirm: true);
          _out.writeln('Rolled back ${ran.length} migration(s).');
        case 'migrate:fresh':
          if (!_ok('DROP ALL TABLES and re-run migrations', force)) return 1;
          final ran = await migrator.fresh(confirm: true);
          _out.writeln('Dropped all tables; ran ${ran.length} migration(s).');
          if (flags.contains('--seed')) await migrator.seed(seeders);
        case 'migrate:status' || 'db:status':
          final rows = await migrator.status();
          if (rows.isEmpty) _out.writeln('No migrations found.');
          for (final r in rows) {
            _out.writeln(
              '${r.ran ? '[x] batch ${r.batch}' : '[ ] pending'}  ${r.id}',
            );
          }
        case 'db:seed':
          final only = flags
              .where((f) => f.startsWith('--class='))
              .map((f) => f.substring(8))
              .firstOrNull;
          if (environment.isProduction && !force) {
            _out.writeln('Seeding in production requires --force.');
            return 1;
          }
          await migrator.seed(seeders, only: only);
          _out.writeln('Seeded.');
        default:
          _out.writeln('Unknown command "$cmd".');
          return 64;
      }
      return 0;
    } on DartCoreException catch (e) {
      _out.writeln('Error: ${e.message}');
      return 1;
    }
  }

  /// Health checks used by `dartcore doctor`. Runs inside the project so it
  /// uses the project's registered adapter and `.env`.
  ///
  /// [connect] opens the connection (a project's `connectDatabase`) and
  /// [database] returns it afterwards. Prints one line per check, each
  /// starting with `OK`, `WARN` or `FAIL`, and returns 1 if any check failed.
  /// Never prints the password. Does not create the migrations table or
  /// disconnect (the caller does).
  static Future<int> doctor({
    required Future<void> Function() connect,
    required Database Function() database,
    required List<Migration> migrations,
    StringSink? out,
  }) async {
    final o = out ?? stdout;
    var failed = false;
    void line(String status, String text) {
      if (status == 'FAIL') failed = true;
      o.writeln('${status.padRight(4)}  $text');
    }

    Database db;
    try {
      await connect();
      db = database();
    } catch (e) {
      line(
        'FAIL',
        'Database connection: could not connect. ${_describe(e)}\n'
            '      Fix: check DB_HOST, DB_PORT, DB_USERNAME, DB_PASSWORD, DB_DATABASE and DB_SSL in .env, '
            'and that the database server is running and reachable from this machine.',
      );
      return 1;
    }
    final c = db.config;
    final target = '${c.driver.name}://${c.host}:${c.port}/${c.database}';
    try {
      final rows = await db.select('SELECT 1');
      if (rows.isEmpty) throw StateError('SELECT 1 returned no rows');
      line('OK', 'Database connection: SELECT 1 succeeded ($target).');
    } catch (e) {
      line(
        'FAIL',
        'Database connection: connected but SELECT 1 failed ($target). ${_describe(e)}\n'
            '      Fix: check that the user may connect to this database.',
      );
      return 1;
    }
    try {
      final hasTable = await SchemaBuilder(db).hasTable('dartcore_migrations');
      final rows = hasTable ? await Migrator(db, migrations).status() : null;
      final applied = rows?.where((r) => r.ran).length ?? 0;
      final pending = migrations.length - applied;
      if (pending > 0) {
        line(
          'WARN',
          'Migrations: $applied applied, $pending pending.\n'
              '      Fix: run "dartcore migrate" (or install.sh --migrate on the server).',
        );
      } else {
        line('OK', 'Migrations: $applied applied, none pending.');
      }
    } catch (e) {
      line('FAIL', 'Migrations: could not read status. ${_describe(e)}');
    }
    return failed ? 1 : 0;
  }

  /// `toString()` plus the driver's `details` / `hint` when the exception
  /// provides them (looked up dynamically so older cores still compile).
  static String _describe(Object e) {
    final b = StringBuffer(e.toString());
    final dynamic d = e;
    for (final name in ['details', 'hint']) {
      try {
        final v = name == 'details' ? d.details : d.hint;
        if (v != null && '$v'.isNotEmpty) b.write('\n      $name: $v');
      } catch (_) {}
    }
    return b.toString();
  }

  bool _ok(String action, bool force) {
    if (force) return true;
    if (environment.isProduction) {
      _out.writeln('Refusing to $action in production without --force.');
      return false;
    }
    final yes = _confirm(
      'This will $action on "${database.config.database}". Continue?',
    );
    if (!yes) _out.writeln('Aborted.');
    return yes;
  }

  int? _intFlag(List<String> flags, String name) {
    for (final f in flags) {
      if (f.startsWith('$name=')) {
        return int.tryParse(f.substring(name.length + 1));
      }
    }
    return null;
  }
}
