/// HTTP layer for DartCore: router, request/response abstractions, middleware
/// and the application server. Built on Shelf, but Shelf types never appear in
/// the public API (except the explicit [Request.toShelf] escape hatch).
library;

export 'src/app.dart';
export 'src/json.dart' show encodeJson;
export 'src/middleware/builtin.dart';
export 'src/middleware/middleware.dart';
export 'src/observer.dart';
export 'src/request.dart';
export 'src/response.dart';
export 'src/router.dart' show Route;
