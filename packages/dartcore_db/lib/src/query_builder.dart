import 'package:dartcore_core/dartcore_core.dart';

import 'adapter.dart';
import 'compiler.dart';
import 'dialect.dart';
import 'pagination.dart';
import 'results.dart';

const Object _unset = Object();

/// Fluent, parameterized query builder.
///
/// All values are bound as parameters and all identifiers are validated, so
/// request data can be passed straight into `where(...)` safely. Dynamic
/// *column names* from requests must still be whitelisted: see [orderByAllowed].
///
/// A builder is mutable and returns `this`; use [clone] to branch.
class QueryBuilder {
  QueryBuilder(
    this._executor,
    this._dialect,
    String table, {
    this.primaryKey = 'id',
  }) : _table = table {
    Identifier.quote(_dialect, table, allowAlias: true); // validate eagerly
  }

  final DatabaseExecutor _executor;
  final SqlDialect _dialect;
  final String _table;
  final String primaryKey;

  final List<String> _columns = [];
  final List<String> _rawColumns = [];
  bool _distinct = false;
  final List<Cond> _wheres = [];
  final List<JoinClause> _joins = [];
  final List<OrderClause> _orders = [];
  final List<String> _groups = [];
  final List<HavingClause> _havings = [];
  int? _limit, _offset;

  SqlCompiler get _compiler => SqlCompiler(_dialect);

  QueryState get _state => QueryState(
    table: _table,
    columns: List.of(_columns),
    rawColumns: List.of(_rawColumns),
    distinct: _distinct,
    wheres: List.of(_wheres),
    joins: List.of(_joins),
    orders: List.of(_orders),
    groups: List.of(_groups),
    havings: List.of(_havings),
    limit: _limit,
    offset: _offset,
  );

  QueryBuilder clone() =>
      QueryBuilder(_executor, _dialect, _table, primaryKey: primaryKey)
        .._columns.addAll(_columns)
        .._rawColumns.addAll(_rawColumns)
        .._distinct = _distinct
        .._wheres.addAll(_wheres)
        .._joins.addAll(_joins)
        .._orders.addAll(_orders)
        .._groups.addAll(_groups)
        .._havings.addAll(_havings)
        .._limit = _limit
        .._offset = _offset;

  /// Compiles the SELECT without running it (useful for logging and tests).
  CompiledQuery toCompiled() => _compiler.select(_state);

  // ---- select ---------------------------------------------------------------

  QueryBuilder select([List<String> columns = const []]) {
    _columns
      ..clear()
      ..addAll(columns);
    return this;
  }

  QueryBuilder selectAll() {
    _columns.clear();
    _rawColumns.clear();
    return this;
  }

  /// **Advanced**: adds a raw select expression (e.g. `COUNT(*) AS n`).
  /// Never put user input in [expression].
  QueryBuilder selectRaw(String expression) {
    _rawColumns.add(expression);
    return this;
  }

  QueryBuilder distinct([bool value = true]) {
    _distinct = value;
    return this;
  }

  // ---- where ----------------------------------------------------------------

  /// `where('status', 'active')`, `where('age', '>', 18)`.
  /// A `null` value with `=`/`<>` becomes `IS NULL` / `IS NOT NULL`.
  QueryBuilder where(
    String column,
    Object? operatorOrValue, [
    Object? value = _unset,
  ]) => _addBasic(column, operatorOrValue, value, or: false);

  QueryBuilder orWhere(
    String column,
    Object? operatorOrValue, [
    Object? value = _unset,
  ]) => _addBasic(column, operatorOrValue, value, or: true);

  QueryBuilder _addBasic(
    String column,
    Object? a,
    Object? b, {
    required bool or,
  }) {
    final String op;
    final Object? value;
    if (identical(b, _unset)) {
      op = '=';
      value = a;
    } else {
      if (a is! String) {
        throw QueryException('The operator must be a string.');
      }
      op = Operators.normalize(_dialect, a);
      value = b;
    }
    _wheres.add(BasicCond(column, op, value, or: or));
    return this;
  }

  QueryBuilder whereIn(String column, Iterable<Object?> values) {
    _wheres.add(InCond(column, values.toList(), false));
    return this;
  }

  QueryBuilder whereNotIn(String column, Iterable<Object?> values) {
    _wheres.add(InCond(column, values.toList(), true));
    return this;
  }

  QueryBuilder whereNull(String column) {
    _wheres.add(NullCond(column, false));
    return this;
  }

  QueryBuilder whereNotNull(String column) {
    _wheres.add(NullCond(column, true));
    return this;
  }

  QueryBuilder whereBetween(String column, Object? low, Object? high) {
    _wheres.add(BetweenCond(column, low, high));
    return this;
  }

  /// `LIKE` with a bound pattern. Wildcards in [pattern] (`%`, `_`) are
  /// honoured; escape user input yourself if it must match literally.
  QueryBuilder whereLike(String column, String pattern) {
    _wheres.add(BasicCond(column, 'LIKE', pattern));
    return this;
  }

  /// **Advanced**: raw condition with `?` placeholders for [bindings].
  QueryBuilder whereRaw(String sql, [List<Object?> bindings = const []]) {
    _wheres.add(RawCond(sql, bindings));
    return this;
  }

  /// Parenthesised group: `WHERE ... AND (role = 'admin' OR role = 'manager')`.
  QueryBuilder whereGroup(void Function(QueryBuilder q) build) =>
      _group(build, or: false);

  QueryBuilder orWhereGroup(void Function(QueryBuilder q) build) =>
      _group(build, or: true);

  QueryBuilder _group(void Function(QueryBuilder q) build, {required bool or}) {
    final inner = QueryBuilder(
      _executor,
      _dialect,
      _table,
      primaryKey: primaryKey,
    );
    build(inner);
    if (inner._wheres.isEmpty) return this;
    _wheres.add(GroupCond(inner._wheres, or: or));
    return this;
  }

  /// Applies [then] when [condition] is true, otherwise [otherwise].
  QueryBuilder when(
    bool condition,
    void Function(QueryBuilder q) then, [
    void Function(QueryBuilder q)? otherwise,
  ]) {
    if (condition) {
      then(this);
    } else if (otherwise != null) {
      otherwise(this);
    }
    return this;
  }

  // ---- joins ----------------------------------------------------------------

  QueryBuilder join(String table, String first, String op, String second) =>
      innerJoin(table, first, op, second);

  QueryBuilder innerJoin(
    String table,
    String first,
    String op,
    String second,
  ) => _join('INNER', table, first, op, second);

  QueryBuilder leftJoin(String table, String first, String op, String second) =>
      _join('LEFT', table, first, op, second);

  QueryBuilder rightJoin(
    String table,
    String first,
    String op,
    String second,
  ) => _join('RIGHT', table, first, op, second);

  QueryBuilder _join(
    String type,
    String table,
    String first,
    String op,
    String second,
  ) {
    _joins.add(
      JoinClause(type, table, first, Operators.normalize(_dialect, op), second),
    );
    return this;
  }

  // ---- ordering / grouping / paging -------------------------------------------

  QueryBuilder orderBy(String column, {bool descending = false}) {
    _orders.add(OrderClause(column, descending));
    return this;
  }

  /// Orders by a column that came from user input, restricted to [allowed].
  /// Unknown columns fall back to [fallback] (or are ignored if null).
  QueryBuilder orderByAllowed(
    String? column,
    List<String> allowed, {
    bool descending = false,
    String? fallback,
  }) {
    final chosen = (column != null && allowed.contains(column))
        ? column
        : fallback;
    if (chosen != null) orderBy(chosen, descending: descending);
    return this;
  }

  QueryBuilder groupBy(List<String> columns) {
    _groups.addAll(columns);
    return this;
  }

  QueryBuilder having(String column, String op, Object? value) {
    _havings.add(HavingClause(column, op, value));
    return this;
  }

  /// **Advanced**: `havingRaw('COUNT(*) > ?', [5])`.
  QueryBuilder havingRaw(String sql, [List<Object?> bindings = const []]) {
    _havings.add(HavingClause.raw(sql, bindings));
    return this;
  }

  QueryBuilder limit(int value) {
    if (value < 0) throw QueryException('limit must be >= 0.');
    _limit = value;
    return this;
  }

  QueryBuilder offset(int value) {
    if (value < 0) throw QueryException('offset must be >= 0.');
    _offset = value;
    return this;
  }

  // ---- reading --------------------------------------------------------------

  Future<List<Row>> get() async => (await _executor.execute(toCompiled())).rows;

  Future<Row?> first() async {
    final rows = await (clone()..limit(1)).get();
    return rows.isEmpty ? null : rows.first;
  }

  Future<Row?> find(Object id, {String? key}) =>
      (clone()..where(key ?? primaryKey, id)).first();

  Future<bool> exists() async =>
      (await _executor.execute(_compiler.existsQuery(_state))).rows.isNotEmpty;

  Future<int> count([String column = '*']) async =>
      (await _aggregate('COUNT', column))?.toInt() ?? 0;

  Future<num?> sum(String column) => _aggregate('SUM', column);
  Future<num?> avg(String column) => _aggregate('AVG', column);
  Future<num?> min(String column) => _aggregate('MIN', column);
  Future<num?> max(String column) => _aggregate('MAX', column);

  Future<num?> _aggregate(String fn, String column) async {
    final res = await _executor.execute(
      _compiler.aggregate(_state, fn, column),
    );
    if (res.rows.isEmpty) return null;
    final v = res.rows.first.values.first;
    if (v == null) return null;
    if (v is num) return v;
    return num.tryParse(v.toString()) ??
        (throw QueryException('Aggregate returned a non-numeric value.'));
  }

  /// Page-based pagination. Runs a COUNT query and a page query (not atomic
  /// unless executed inside a transaction).
  Future<Paginator> paginate({int page = 1, int limit = 20}) async {
    if (page < 1) throw QueryException('page must be >= 1.');
    if (limit < 1) throw QueryException('limit must be >= 1.');
    final countQuery = clone()
      .._orders.clear()
      .._limit = null
      .._offset = null;
    final total = await countQuery.count();
    final data =
        await (clone()
              ..limit(limit)
              ..offset((page - 1) * limit))
            .get();
    return Paginator(
      data: data,
      currentPage: page,
      perPage: limit,
      total: total,
    );
  }

  // ---- writing --------------------------------------------------------------

  /// Inserts one row and returns it. PostgreSQL/SQLite/MSSQL return the stored
  /// row (RETURNING/OUTPUT). MySQL has no RETURNING: the row is re-read by
  /// the generated id when one exists, otherwise [values] is returned as given.
  Future<Row> insert(Row values) async {
    final res = await _executor.execute(_compiler.insert(_table, [values]));
    if (_dialect.supportsReturning && res.rows.isNotEmpty) {
      return res.rows.first;
    }
    final id = res.insertId;
    if (id != null && id != 0) {
      final row = await QueryBuilder(
        _executor,
        _dialect,
        _table,
        primaryKey: primaryKey,
      ).find(id);
      if (row != null) return row;
    }
    return Map.of(values);
  }

  /// Inserts many rows (same keys required) and returns the affected count.
  /// Large inputs are split into multiple statements to respect the engine's
  /// parameter limit; wrap in a transaction for all-or-nothing behaviour.
  Future<int> insertMany(List<Row> rows) async {
    if (rows.isEmpty) return 0;
    final perRow = rows.first.length;
    final chunk = (_dialect.maxParameters ~/ (perRow == 0 ? 1 : perRow)).clamp(
      1,
      1000,
    );
    var affected = 0;
    for (var i = 0; i < rows.length; i += chunk) {
      final part = rows.sublist(
        i,
        i + chunk > rows.length ? rows.length : i + chunk,
      );
      final res = await _executor.execute(
        _compiler.insert(_table, part, returning: false),
      );
      affected += res.affectedRows;
    }
    return affected;
  }

  /// Updates matching rows. Refuses to run without a WHERE unless
  /// [allowAll] is set, so a forgotten condition cannot wipe a table.
  Future<int> update(Row values, {bool allowAll = false}) async {
    _requireWhere('update', allowAll);
    final res = await _executor.execute(_compiler.update(_state, values));
    return res.affectedRows;
  }

  Future<int> increment(
    String column, [
    num amount = 1,
    Row extra = const {},
    bool allowAll = false,
  ]) async {
    _requireWhere('increment', allowAll);
    final res = await _executor.execute(
      _compiler.update(_state, extra, increments: {column: amount}),
    );
    return res.affectedRows;
  }

  Future<int> decrement(
    String column, [
    num amount = 1,
    Row extra = const {},
    bool allowAll = false,
  ]) => increment(column, -amount, extra, allowAll);

  /// Deletes matching rows; requires a WHERE unless [allowAll] is set.
  Future<int> delete({bool allowAll = false}) async {
    _requireWhere('delete', allowAll);
    return (await _executor.execute(_compiler.delete(_state))).affectedRows;
  }

  /// Removes all rows. SQLite has no TRUNCATE; it runs `DELETE FROM` (and does
  /// not reset autoincrement counters).
  Future<void> truncate() async {
    await _executor.execute(_compiler.truncate(_table));
  }

  void _requireWhere(String op, bool allowAll) {
    if (_wheres.isEmpty && !allowAll) {
      throw QueryException(
        '$op() without a where() clause would affect every row. '
        'Pass allowAll: true if that is intended.',
      );
    }
  }
}
