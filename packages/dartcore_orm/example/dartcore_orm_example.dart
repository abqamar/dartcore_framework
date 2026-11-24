// Model, validation, eager loading and soft deletes on SQLite :memory: (ran for real).
//
// Observed output of `dart run example/dartcore_orm_example.dart`:
//
//   created user 1 with createdAt set: true
//   invalid -> ValidationException: {name: [The name must be at least 2 characters.]}
//   Ada has 2 posts
//   posts after soft delete: 1
//   with trashed: 2
//   after restore: 2
//   page.data are Post models: First, total=2

import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_orm/dartcore_orm.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';

class User extends Model {
  int? id;
  String? name;

  @override
  String get table => 'users';
  @override
  List<String> get fillable => ['name'];
  @override
  Map<String, Object> get rules => {'name': 'required|string|min:2'};
  @override
  Map<String, RelationDef> get relationDefs => {
    'posts': HasMany<Post>(Post.new),
  };

  @override
  Map<String, Object?> toMap() => {'id': id, 'name': name};
  @override
  void fillFromMap(Map<String, Object?> m) {
    if (m.containsKey('id')) id = Casts.asInt(m['id']);
    if (m.containsKey('name')) name = m['name'] as String?;
  }

  static final repo = ModelRepository<User>(User.new);
  static ModelQuery<User> query() => repo.query();
  static Future<User> create(Map<String, Object?> a) => repo.create(a);
}

class Post extends Model {
  int? id;
  int? userId;
  String? title;

  @override
  String get table => 'posts';
  @override
  bool get softDeletes => true;
  @override
  List<String> get fillable => ['title', 'user_id'];

  @override
  Map<String, Object?> toMap() => {'id': id, 'user_id': userId, 'title': title};
  @override
  void fillFromMap(Map<String, Object?> m) {
    if (m.containsKey('id')) id = Casts.asInt(m['id']);
    if (m.containsKey('user_id')) userId = Casts.asInt(m['user_id']);
    if (m.containsKey('title')) title = m['title'] as String?;
  }

  static final repo = ModelRepository<Post>(Post.new);
  static Future<Post> create(Map<String, Object?> a) => repo.create(a);
  static ModelQuery<Post> query() => repo.query();
}

Future<void> main() async {
  registerSqlite();
  await DB.connect(driver: DatabaseDriver.sqlite, database: ':memory:');
  await DB.statement(
    'CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, '
    'created_at TEXT, updated_at TEXT)',
  );
  await DB.statement(
    'CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, '
    'title TEXT, created_at TEXT, updated_at TEXT, deleted_at TEXT)',
  );

  final ada = await User.create({'name': 'Ada'});
  await Post.create({'title': 'First', 'user_id': ada.id});
  final second = await Post.create({'title': 'Second', 'user_id': ada.id});
  print('created user ${ada.id} with createdAt set: ${ada.createdAt != null}');

  // Validation runs on save() using the model's `rules`.
  try {
    await User.create({'name': 'A'});
  } on ValidationException catch (e) {
    print('invalid -> ValidationException: ${e.errors}');
  }

  // Eager loading: one extra query for all parents (no N+1).
  final users = await User.query().withRelations(['posts']).get();
  print(
    '${users.first.name} has ${users.first.many<Post>('posts').length} posts',
  );

  // Soft deletes.
  await second.delete();
  print('posts after soft delete: ${await Post.query().count()}');
  print('with trashed: ${await Post.query().withTrashed().count()}');
  await second.restore();
  print('after restore: ${await Post.query().count()}');

  final page = await Post.query().orderBy('id').paginate(page: 1, limit: 1);
  print(
    'page.data are Post models: ${page.data.first.title}, total=${page.total}',
  );

  await DB.reset();
}
