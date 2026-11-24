import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_validation/dartcore_validation.dart';

/// Connects the `unique` / `exists` validation rules to a database.
///
/// ```dart
/// final v = await Validate.requestAsync(data, {'email': 'required|unique:users,email'},
///     exists: databaseExistenceChecker(app.database));
/// ```
///
/// Table and column names come from your rule strings (developer-controlled),
/// are validated as identifiers by the query builder, and the value is always
/// a bound parameter.
ExistenceChecker databaseExistenceChecker(DatabaseOperations db) =>
    (table, column, value, {ignoreId, ignoreColumn = 'id'}) {
      final q = db.table(table).where(column, value);
      if (ignoreId != null) {
        final id = ignoreId is String
            ? (int.tryParse(ignoreId) ?? ignoreId)
            : ignoreId;
        q.where(ignoreColumn, '<>', id);
      }
      return q.exists();
    };
