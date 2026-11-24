/// Database abstraction for DartCore: query builder, SQL dialects, pooling,
/// transactions and the adapter contract implemented by driver packages.
library;

export 'src/adapter.dart';
export 'src/compiler.dart' show SqlCompiler, Operators, Identifier;
export 'src/config.dart';
export 'src/dialect.dart';
export 'src/manager.dart';
export 'src/pagination.dart';
export 'src/pool.dart';
export 'src/query_builder.dart';
export 'src/results.dart';
