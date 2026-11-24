import 'package:dartcore_auth/dartcore_auth.dart';
import 'package:dartcore_framework/dartcore_framework.dart';

/// Tasks belong to the signed-in user. Every query is scoped by `user_id`, so
/// one user can never read or change another user's task (a foreign id looks
/// exactly like a missing one: 404).
class TaskController {
  static const _statuses = 'todo,doing,done';
  static const _columns = [
    'id',
    'title',
    'description',
    'status',
    'due_at',
    'created_at',
    'updated_at',
  ];
  static const _sortable = ['id', 'title', 'status', 'due_at', 'created_at'];

  Future<Object> _userId(Request request) async =>
      (await Auth.user(request))!.id;

  Future<Response> index(Request request) async {
    final userId = await _userId(request);
    final page = int.tryParse(request.query('page') ?? '') ?? 1;
    final limit = (int.tryParse(request.query('limit') ?? '') ?? 20).clamp(
      1,
      100,
    );
    final status = request.query('status');
    final search = request.query('q');
    final result = await DB
        .table('tasks')
        .select(_columns)
        .where('user_id', userId)
        .when(status != null, (q) => q.where('status', status))
        .when(
          search != null && search.isNotEmpty,
          (q) => q.where('title', 'like', '%$search%'),
        )
        .orderByAllowed(request.query('sort'), _sortable, fallback: 'id')
        .paginate(page: page < 1 ? 1 : page, limit: limit);
    return Response.success(result.data, meta: result.meta);
  }

  Future<Response> show(Request request) async {
    final row = await _find(request);
    return row == null
        ? Response.notFound('Task not found')
        : Response.success(row);
  }

  Future<Response> store(Request request) async {
    final v = Validate.request(await request.json(), {
      'title': 'required|string|min:2|max:200',
      'description': 'nullable|string|max:5000',
      'status': 'sometimes|in:$_statuses',
      'due_at': 'nullable|date',
    });
    if (v.fails) return Response.validationError(v.errors);
    final now = DateTime.now().toUtc();
    final created = await DB.table('tasks').insert({
      ...v.validated,
      'user_id': await _userId(request),
      'created_at': now,
      'updated_at': now,
    });
    return Response.success(
      await DB.table('tasks').select(_columns).find(created['id']!),
      message: 'Task created',
      status: 201,
    );
  }

  Future<Response> update(Request request) async {
    final v = Validate.request(await request.json(), {
      'title': 'sometimes|string|min:2|max:200',
      'description': 'nullable|string|max:5000',
      'status': 'sometimes|in:$_statuses',
      'due_at': 'nullable|date',
    });
    if (v.fails) return Response.validationError(v.errors);
    if (v.validated.isEmpty) return Response.badRequest('Nothing to update');
    final affected = await DB
        .table('tasks')
        .where('id', request.param('id')!)
        .where('user_id', await _userId(request))
        .update({...v.validated, 'updated_at': DateTime.now().toUtc()});
    if (affected == 0) return Response.notFound('Task not found');
    return Response.success(await _find(request), message: 'Task updated');
  }

  Future<Response> destroy(Request request) async {
    final affected = await DB
        .table('tasks')
        .where('id', request.param('id')!)
        .where('user_id', await _userId(request))
        .delete();
    return affected == 0
        ? Response.notFound('Task not found')
        : Response.noContent();
  }

  Future<Map<String, Object?>?> _find(Request request) async => DB
      .table('tasks')
      .select(_columns)
      .where('id', request.param('id')!)
      .where('user_id', await _userId(request))
      .first();
}
