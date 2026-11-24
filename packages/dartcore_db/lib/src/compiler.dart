import 'package:dartcore_core/dartcore_core.dart';

import 'dialect.dart';
import 'results.dart';

/// Validates identifiers (tables, columns). Anything that is not a plain,
/// optionally dotted, identifier is rejected, so user-controlled column names
/// can never smuggle SQL.
abstract final class Identifier {
  static final _part = RegExp(r'^[A-Za-z_][A-Za-z0-9_$]*$');
  static final _alias = RegExp(
    r'^(.+?)\s+as\s+([A-Za-z_][A-Za-z0-9_$]*)$',
    caseSensitive: false,
  );

  static bool isValidPart(String s) => _part.hasMatch(s);

  /// Returns the quoted form of [raw] (`users.id`, `u.*`, `*`, `name as n`).
  static String quote(SqlDialect d, String raw, {bool allowAlias = false}) {
    var value = raw.trim();
    String? alias;
    if (allowAlias) {
      final m = _alias.firstMatch(value);
      if (m != null) {
        value = m.group(1)!.trim();
        alias = m.group(2);
      }
    }
    if (value == '*') return '*';
    final parts = value.split('.');
    if (parts.isEmpty || parts.length > 3) _bad(raw);
    final quoted = <String>[];
    for (var i = 0; i < parts.length; i++) {
      final p = parts[i];
      if (p == '*' && i == parts.length - 1 && parts.length > 1) {
        quoted.add('*');
      } else if (_part.hasMatch(p)) {
        quoted.add(d.quote(p));
      } else {
        _bad(raw);
      }
    }
    final q = quoted.join('.');
    return alias == null ? q : '$q AS ${d.quote(alias)}';
  }

  static Never _bad(String raw) => throw QueryException(
    'Invalid identifier "$raw". Only letters, digits, "_" and "." are allowed; '
    'use the raw APIs for anything else.',
  );
}

abstract final class Operators {
  static const _allowed = {
    '=',
    '<',
    '>',
    '<=',
    '>=',
    '<>',
    '!=',
    'like',
    'not like',
    'ilike',
    'not ilike',
  };

  static String normalize(SqlDialect d, String op) {
    final o = op.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    if (!_allowed.contains(o)) {
      throw QueryException('Unsupported operator "$op".');
    }
    if (o.contains('ilike') && !d.supportsIlike) {
      throw QueryException(
        'ILIKE is not supported by ${d.name}; use LIKE (collation decides case sensitivity).',
      );
    }
    return o == '!=' ? '<>' : o.toUpperCase();
  }
}

// ---- where clause model -----------------------------------------------------

sealed class Cond {
  Cond(this.or);
  final bool or;
}

class BasicCond extends Cond {
  BasicCond(this.column, this.op, this.value, {bool or = false}) : super(or);
  final String column, op;
  final Object? value;
}

class NullCond extends Cond {
  NullCond(this.column, this.not, {bool or = false}) : super(or);
  final String column;
  final bool not;
}

class InCond extends Cond {
  InCond(this.column, this.values, this.not, {bool or = false}) : super(or);
  final String column;
  final List<Object?> values;
  final bool not;
}

class BetweenCond extends Cond {
  BetweenCond(this.column, this.low, this.high, {bool or = false}) : super(or);
  final String column;
  final Object? low, high;
}

class RawCond extends Cond {
  RawCond(this.sql, this.bindings, {bool or = false}) : super(or);
  final String sql;
  final List<Object?> bindings;
}

class GroupCond extends Cond {
  GroupCond(this.conds, {bool or = false}) : super(or);
  final List<Cond> conds;
}

class JoinClause {
  JoinClause(this.type, this.table, this.first, this.op, this.second);
  final String type, table, first, op, second;
}

class OrderClause {
  OrderClause(this.column, this.descending, [this.raw]);
  final String column;
  final bool descending;
  final String? raw;
}

class HavingClause {
  HavingClause(this.column, this.op, this.value)
    : rawSql = null,
      rawBindings = const [];
  HavingClause.raw(this.rawSql, this.rawBindings)
    : column = '',
      op = '',
      value = null;
  final String column, op;
  final Object? value;
  final String? rawSql;
  final List<Object?> rawBindings;
}

/// Immutable snapshot of a query used by [SqlCompiler].
class QueryState {
  QueryState({
    required this.table,
    this.columns = const [],
    this.rawColumns = const [],
    this.distinct = false,
    this.wheres = const [],
    this.joins = const [],
    this.orders = const [],
    this.groups = const [],
    this.havings = const [],
    this.limit,
    this.offset,
  });

  final String table;
  final List<String> columns;
  final List<String> rawColumns;
  final bool distinct;
  final List<Cond> wheres;
  final List<JoinClause> joins;
  final List<OrderClause> orders;
  final List<String> groups;
  final List<HavingClause> havings;
  final int? limit, offset;
}

/// Translates query state into dialect-specific SQL with bound parameters.
class SqlCompiler {
  SqlCompiler(this.dialect);
  final SqlDialect dialect;

  CompiledQuery select(QueryState q) {
    final b = _Bindings(dialect);
    return CompiledQuery(_select(q, b), b.values);
  }

  /// `SELECT 1 ... LIMIT 1` used by `exists()`.
  CompiledQuery existsQuery(QueryState q) {
    final b = _Bindings(dialect);
    final sql = _select(
      QueryState(
        table: q.table,
        rawColumns: const ['1 AS dc_exists'],
        wheres: q.wheres,
        joins: q.joins,
        groups: q.groups,
        havings: q.havings,
        limit: 1,
      ),
      b,
    );
    return CompiledQuery(sql, b.values);
  }

  /// `SELECT fn(col) AS aggregate`. Falls back to a subquery for DISTINCT /
  /// GROUP BY / LIMIT queries so the count is of the *result set*.
  CompiledQuery aggregate(QueryState q, String fn, String column) {
    final b = _Bindings(dialect);
    final col = Identifier.quote(dialect, column);
    final needsWrap =
        q.distinct ||
        q.groups.isNotEmpty ||
        q.limit != null ||
        q.offset != null;
    if (!needsWrap) {
      final sql = _select(
        QueryState(
          table: q.table,
          rawColumns: ['${fn.toUpperCase()}($col) AS aggregate'],
          wheres: q.wheres,
          joins: q.joins,
          havings: q.havings,
        ),
        b,
      );
      return CompiledQuery(sql, b.values);
    }
    final inner = _select(q, b);
    return CompiledQuery(
      'SELECT ${fn.toUpperCase()}(${column == '*' ? '*' : dialect.quote(column.split('.').last)}) AS aggregate '
      'FROM ($inner) AS ${dialect.quote('dc_sub')}',
      b.values,
    );
  }

  CompiledQuery insert(String table, List<Row> rows, {bool returning = true}) {
    if (rows.isEmpty) throw QueryException('Cannot insert zero rows.');
    final keys = rows.first.keys.toList();
    if (keys.isEmpty) throw QueryException('Cannot insert an empty row.');
    for (final r in rows) {
      if (r.length != keys.length || !keys.every(r.containsKey)) {
        throw QueryException(
          'insertMany requires every row to have exactly the same keys.',
        );
      }
    }
    final b = _Bindings(dialect);
    final cols = keys.map((k) => Identifier.quote(dialect, k)).join(', ');
    final tuples = [
      for (final r in rows) '(${keys.map((k) => b.add(r[k])).join(', ')})',
    ].join(', ');
    return CompiledQuery(
      'INSERT INTO ${Identifier.quote(dialect, table)} ($cols)'
      '${returning ? dialect.insertOutput() : ''} VALUES $tuples'
      '${returning ? dialect.insertReturning() : ''}',
      b.values,
    );
  }

  /// [increments] are applied as `col = col + ?`.
  CompiledQuery update(
    QueryState q,
    Row values, {
    Map<String, num> increments = const {},
  }) {
    if (values.isEmpty && increments.isEmpty) {
      throw QueryException('update() requires at least one column.');
    }
    final b = _Bindings(dialect);
    final sets = <String>[
      for (final e in values.entries)
        '${Identifier.quote(dialect, e.key)} = ${b.add(e.value)}',
      for (final e in increments.entries)
        '${Identifier.quote(dialect, e.key)} = ${Identifier.quote(dialect, e.key)} + ${b.add(e.value)}',
    ];
    final where = _where(q.wheres, b);
    return CompiledQuery(
      'UPDATE ${Identifier.quote(dialect, q.table)} SET ${sets.join(', ')}$where',
      b.values,
    );
  }

  CompiledQuery delete(QueryState q) {
    final b = _Bindings(dialect);
    final where = _where(q.wheres, b);
    return CompiledQuery(
      'DELETE FROM ${Identifier.quote(dialect, q.table)}$where',
      b.values,
    );
  }

  CompiledQuery truncate(String table) =>
      CompiledQuery(dialect.truncateSql(Identifier.quote(dialect, table)));

  /// Translates `?` placeholders in user-written raw SQL to the dialect's
  /// style, skipping quoted literals.
  CompiledQuery raw(String sql, List<Object?> bindings) {
    final b = _Bindings(dialect);
    return CompiledQuery(_rawSql(sql, bindings, b), b.values);
  }

  // ---- internals ------------------------------------------------------------

  String _select(QueryState q, _Bindings b) {
    final cols = [
      for (final c in q.columns) Identifier.quote(dialect, c, allowAlias: true),
      ...q.rawColumns,
    ];
    final sb = StringBuffer('SELECT ');
    if (q.distinct) sb.write('DISTINCT ');
    sb.write(cols.isEmpty ? '*' : cols.join(', '));
    sb.write(' FROM ${Identifier.quote(dialect, q.table, allowAlias: true)}');
    for (final j in q.joins) {
      sb.write(
        ' ${j.type} JOIN ${Identifier.quote(dialect, j.table, allowAlias: true)}'
        ' ON ${Identifier.quote(dialect, j.first)} ${Operators.normalize(dialect, j.op)} '
        '${Identifier.quote(dialect, j.second)}',
      );
    }
    sb.write(_where(q.wheres, b));
    if (q.groups.isNotEmpty) {
      sb.write(
        ' GROUP BY ${q.groups.map((g) => Identifier.quote(dialect, g)).join(', ')}',
      );
    }
    if (q.havings.isNotEmpty) {
      sb.write(' HAVING ');
      sb.write(
        [
          for (final h in q.havings)
            h.rawSql != null
                ? '(${_rawSql(h.rawSql!, h.rawBindings, b)})'
                : '${_havingColumn(h.column)} ${Operators.normalize(dialect, h.op)} ${b.add(h.value)}',
        ].join(' AND '),
      );
    }
    if (q.orders.isNotEmpty) {
      sb.write(' ORDER BY ');
      sb.write(
        [
          for (final o in q.orders)
            '${Identifier.quote(dialect, o.column)} ${o.descending ? 'DESC' : 'ASC'}',
        ].join(', '),
      );
    }
    sb.write(
      dialect.limitOffset(q.limit, q.offset, hasOrder: q.orders.isNotEmpty),
    );
    return sb.toString();
  }

  // HAVING may reference aggregates such as COUNT(*) only through havingRaw
  // style input; here columns are plain identifiers.
  String _havingColumn(String c) => Identifier.quote(dialect, c);

  String _where(List<Cond> conds, _Bindings b) {
    if (conds.isEmpty) return '';
    return ' WHERE ${_conds(conds, b)}';
  }

  String _conds(List<Cond> conds, _Bindings b) {
    final sb = StringBuffer();
    for (var i = 0; i < conds.length; i++) {
      final c = conds[i];
      if (i > 0) sb.write(c.or ? ' OR ' : ' AND ');
      sb.write(_cond(c, b));
    }
    return sb.toString();
  }

  String _cond(Cond c, _Bindings b) {
    switch (c) {
      case BasicCond():
        final col = Identifier.quote(dialect, c.column);
        if (c.value == null) {
          if (c.op == '=') return '$col IS NULL';
          if (c.op == '<>') return '$col IS NOT NULL';
          throw QueryException(
            'Operator "${c.op}" cannot be compared with null.',
          );
        }
        return '$col ${c.op} ${b.add(c.value)}';
      case NullCond():
        return '${Identifier.quote(dialect, c.column)} IS ${c.not ? 'NOT ' : ''}NULL';
      case InCond():
        // Empty IN () is invalid SQL; the logically equivalent constant is used.
        if (c.values.isEmpty) return c.not ? '1 = 1' : '1 = 0';
        return '${Identifier.quote(dialect, c.column)} ${c.not ? 'NOT IN' : 'IN'} '
            '(${c.values.map(b.add).join(', ')})';
      case BetweenCond():
        return '${Identifier.quote(dialect, c.column)} BETWEEN ${b.add(c.low)} AND ${b.add(c.high)}';
      case RawCond():
        return '(${_rawSql(c.sql, c.bindings, b)})';
      case GroupCond():
        return '(${_conds(c.conds, b)})';
    }
  }

  String _rawSql(String sql, List<Object?> bindings, _Bindings b) {
    final out = StringBuffer();
    var used = 0;
    String? quote;
    for (var i = 0; i < sql.length; i++) {
      final ch = sql[i];
      if (quote != null) {
        out.write(ch);
        if (ch == quote) quote = null;
      } else if (ch == "'" || ch == '"' || ch == '`') {
        quote = ch;
        out.write(ch);
      } else if (ch == '?') {
        if (used >= bindings.length) {
          throw QueryException(
            'Raw SQL has more "?" placeholders than bindings.',
          );
        }
        out.write(b.add(bindings[used++]));
      } else {
        out.write(ch);
      }
    }
    if (used != bindings.length) {
      throw QueryException('Raw SQL has fewer "?" placeholders than bindings.');
    }
    return out.toString();
  }
}

class _Bindings {
  _Bindings(this.dialect);
  final SqlDialect dialect;
  final List<Object?> values = [];

  String add(Object? v) {
    values.add(v);
    return dialect.placeholder(values.length);
  }
}
