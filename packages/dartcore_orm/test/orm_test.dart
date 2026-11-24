import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_db/dartcore_db.dart';
import 'package:dartcore_orm/dartcore_orm.dart';
import 'package:dartcore_sqlite/dartcore_sqlite.dart';
import 'package:test/test.dart';

final events = <String>[];

class User extends Model {
  int? id;
  String? name;
  String? email;
  bool active = true;
  String? passwordHash;
  int? companyId;

  @override
  String get table => 'users';
  @override
  List<String> get fillable => ['name', 'email', 'active'];
  @override
  List<String> get hidden => ['password_hash'];
  @override
  Map<String, Object> get rules => {
    'name': 'required|string|min:2',
    'email': 'required|email',
  };
  @override
  Map<String, RelationDef> get relationDefs => {
    'posts': HasMany<Post>(Post.new),
    'profile': HasOne<Profile>(Profile.new),
    'company': BelongsTo<Company>(Company.new),
    'roles': BelongsToMany<Role>(Role.new),
  };

  @override
  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'email': email,
    'active': active,
    'password_hash': passwordHash,
    'company_id': companyId,
  };

  @override
  void fillFromMap(Map<String, Object?> m) {
    if (m.containsKey('id')) id = Casts.asInt(m['id']);
    if (m.containsKey('name')) name = m['name'] as String?;
    if (m.containsKey('email')) email = m['email'] as String?;
    if (m.containsKey('active')) active = Casts.asBool(m['active']) ?? true;
    if (m.containsKey('password_hash')) {
      passwordHash = m['password_hash'] as String?;
    }
    if (m.containsKey('company_id')) companyId = Casts.asInt(m['company_id']);
  }

  @override
  Future<void> onCreating() async => events.add('creating');
  @override
  Future<void> onCreated() async => events.add('created');
  @override
  Future<void> onUpdated() async => events.add('updated');
  @override
  Future<void> onDeleted() async => events.add('deleted');

  static final repo = ModelRepository<User>(User.new);
  static Future<User?> find(Object id) => repo.find(id);
  static ModelQuery<User> query() => repo.query();
  static Future<User> create(Map<String, Object?> a) => repo.create(a);
}

class Post extends Model {
  int? id, userId;
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
}

class Profile extends Model {
  int? id, userId;
  String? bio;
  @override
  String get table => 'profiles';
  @override
  List<String> get fillable => ['bio', 'user_id'];
  @override
  Map<String, Object?> toMap() => {'id': id, 'user_id': userId, 'bio': bio};
  @override
  void fillFromMap(Map<String, Object?> m) {
    if (m.containsKey('id')) id = Casts.asInt(m['id']);
    if (m.containsKey('user_id')) userId = Casts.asInt(m['user_id']);
    if (m.containsKey('bio')) bio = m['bio'] as String?;
  }
}

class Company extends Model {
  int? id;
  String? name;
  @override
  String get table => 'companies';
  @override
  bool get timestamps => false;
  @override
  List<String> get fillable => ['name'];
  @override
  Map<String, Object?> toMap() => {'id': id, 'name': name};
  @override
  void fillFromMap(Map<String, Object?> m) {
    if (m.containsKey('id')) id = Casts.asInt(m['id']);
    if (m.containsKey('name')) name = m['name'] as String?;
  }
}

class Role extends Model {
  int? id;
  String? name;
  @override
  String get table => 'roles';
  @override
  bool get timestamps => false;
  @override
  Map<String, Object?> toMap() => {'id': id, 'name': name};
  @override
  void fillFromMap(Map<String, Object?> m) {
    if (m.containsKey('id')) id = Casts.asInt(m['id']);
    if (m.containsKey('name')) name = m['name'] as String?;
  }
}

/// Wraps an adapter and counts executed statements.
class CountingAdapter implements DatabaseAdapter {
  CountingAdapter(this.inner);
  final DatabaseAdapter inner;
  int count = 0;
  @override
  SqlDialect get dialect => inner.dialect;
  @override
  AdapterCapabilities get capabilities => inner.capabilities;
  @override
  Future<void> connect() => inner.connect();
  @override
  Future<void> disconnect() => inner.disconnect();
  @override
  Future<QueryResult> execute(CompiledQuery q) {
    count++;
    return inner.execute(q);
  }

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseExecutor tx) a) =>
      inner.transaction(a);
  @override
  Future<bool> ping() => inner.ping();
}

void main() {
  late DatabaseManager m;
  late CountingAdapter counter;

  setUpAll(registerSqlite);
  setUp(() async {
    events.clear();
    m = DatabaseManager();
    DB.use(m);
    const cfg = ConnectionConfig(
      driver: DatabaseDriver.sqlite,
      database: ':memory:',
    );
    final inner = PooledAdapter(
      cfg,
      DatabaseManager.registeredDrivers[DatabaseDriver.sqlite]!,
      maxPoolSize: 1,
    );
    counter = CountingAdapter(inner);
    final db = await m.useAdapter(counter, cfg);
    for (final ddl in [
      'CREATE TABLE companies (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)',
      'CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, email TEXT, active INTEGER DEFAULT 1, password_hash TEXT, company_id INTEGER, created_at TEXT, updated_at TEXT)',
      'CREATE TABLE posts (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, title TEXT, created_at TEXT, updated_at TEXT, deleted_at TEXT)',
      'CREATE TABLE profiles (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, bio TEXT, created_at TEXT, updated_at TEXT)',
      'CREATE TABLE roles (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)',
      'CREATE TABLE role_user (user_id INTEGER, role_id INTEGER)',
    ]) {
      await db.statement(ddl);
    }
  });
  tearDown(() => m.disconnect());

  group('CRUD', () {
    test('create/find/update/delete with timestamps and events', () async {
      final u = await User.create({
        'name': 'John',
        'email': 'john@example.com',
      });
      expect(u.exists, isTrue);
      expect(u.id, 1);
      expect(u.createdAt, isNotNull);
      expect(events, ['creating', 'created']);

      final found = await User.find(1);
      expect(found!.name, 'John');
      expect(found.active, isTrue);
      expect(found.createdAt, isNotNull);

      await found.update({'name': 'Updated John'});
      expect((await User.find(1))!.name, 'Updated John');
      expect(
        found.updatedAt!.isAfter(found.createdAt!) ||
            found.updatedAt == found.createdAt,
        isTrue,
      );
      expect(events, contains('updated'));

      await found.delete();
      expect(await User.find(1), isNull);
      expect(found.exists, isFalse);
      expect(events.last, 'deleted');
    });

    test('save() inserts new, updates existing; refresh() reloads', () async {
      final u = User()
        ..name = 'Ann'
        ..email = 'ann@x.io';
      await u.save();
      u.name = 'Anna';
      await u.save();
      await m.table('users').where('id', u.id!).update({'name': 'External'});
      await u.refresh();
      expect(u.name, 'External');
      expect(await User.query().count(), 1);
    });

    test(
      'mass assignment drops non-fillable attributes; forceFill allows',
      () async {
        final u = await User.create({
          'name': 'Eve',
          'email': 'e@x.io',
          'password_hash': 'x',
          'id': 99,
        });
        expect(u.passwordHash, isNull);
        expect(u.id, 1);
        final f = User()..forceFill({'password_hash': 'trusted'});
        expect(f.passwordHash, 'trusted');
      },
    );

    test(
      'validation runs before save and throws ValidationException',
      () async {
        final u = User()
          ..name = 'X'
          ..email = 'bad';
        try {
          await u.save();
          fail('expected ValidationException');
        } on ValidationException catch (e) {
          expect(e.errors.keys, containsAll(['name', 'email']));
        }
        expect(await User.query().count(), 0);
      },
    );

    test('toJson hides fields and includes timestamps', () async {
      final u = await User.create({'name': 'Zed', 'email': 'z@x.io'});
      u.passwordHash = 'secret';
      final j = u.toJson();
      expect(j.containsKey('password_hash'), isFalse);
      expect(j['name'], 'Zed');
      expect(j['created_at'], isA<DateTime>());
    });

    test('operations on unsaved models fail clearly', () async {
      expect(() => User().delete(), throwsA(isA<DatabaseException>()));
      expect(() => User().refresh(), throwsA(isA<DatabaseException>()));
    });
  });

  group('queries', () {
    test('where, orderBy, limit, count, exists, find via query', () async {
      for (final n in ['A', 'B', 'C']) {
        await User.create({
          'name': 'User $n',
          'email': '${n.toLowerCase()}@x.io',
          'active': n != 'C',
        });
      }
      final active = await User.query()
          .where('active', true)
          .orderBy('name', descending: true)
          .get();
      expect(active.map((u) => u.name), ['User B', 'User A']);
      expect(
        await User.query().where('name', 'like', 'User%').limit(2).get(),
        hasLength(2),
      );
      expect(await User.query().where('email', 'c@x.io').exists(), isTrue);
      expect(
        (await User.query().whereIn('name', ['User A']).first())!.email,
        'a@x.io',
      );
    });

    test('pagination returns models and meta', () async {
      for (var i = 1; i <= 25; i++) {
        await m.table('users').insert({'name': 'u$i', 'email': 'u$i@x'});
      }
      final p = await User.query().orderBy('id').paginate(page: 2, limit: 10);
      expect(p.data.first.name, 'u11');
      expect(p.total, 25);
      expect(p.lastPage, 3);
      expect(p.hasNextPage, isTrue);
      expect(p.toJson()['meta'], containsPair('total', 25));
    });
  });

  group('soft deletes', () {
    test(
      'delete hides, withTrashed/onlyTrashed reveal, restore, forceDelete',
      () async {
        final p = await Post.repo.create({'title': 'T', 'user_id': 1});
        await p.delete();
        expect(p.trashed, isTrue);
        expect(await Post.repo.query().count(), 0);
        expect(await Post.repo.query().withTrashed().count(), 1);
        expect(await Post.repo.query().onlyTrashed().count(), 1);
        expect(await Post.repo.find(p.id!), isNull);
        await p.restore();
        expect(await Post.repo.query().count(), 1);
        await p.forceDelete();
        expect(await Post.repo.query().withTrashed().count(), 0);
      },
    );
  });

  group('relationships', () {
    late User john, jane;
    setUp(() async {
      final acme = await m.table('companies').insert({'name': 'Acme'});
      john = await User.create({'name': 'John', 'email': 'john@x.io'});
      jane = await User.create({'name': 'Jane', 'email': 'jane@x.io'});
      await m.table('users').where('id', john.id!).update({
        'company_id': acme['id'],
      });
      await john.refresh();
      await Post.repo.create({'title': 'J1', 'user_id': john.id});
      await Post.repo.create({'title': 'J2', 'user_id': john.id});
      await Post.repo.create({'title': 'N1', 'user_id': jane.id});
      await m.table('profiles').insert({'user_id': john.id, 'bio': 'hi'});
      for (final r in ['admin', 'editor']) {
        await m.table('roles').insert({'name': r});
      }
      await m.table('role_user').insertMany([
        {'user_id': john.id, 'role_id': 1},
        {'user_id': john.id, 'role_id': 2},
        {'user_id': jane.id, 'role_id': 2},
      ]);
    });

    test('lazy: hasMany, hasOne, belongsTo, belongsToMany', () async {
      expect(
        (await john.hasMany(Post.new).orderBy('id').get()).map((p) => p.title),
        ['J1', 'J2'],
      );
      expect((await john.hasOne(Profile.new).first())!.bio, 'hi');
      expect((await john.belongsTo(Company.new).first())!.name, 'Acme');
      expect(
        (await john.belongsToMany(Role.new).orderBy('id').get()).map(
          (r) => r.name,
        ),
        ['admin', 'editor'],
      );
      expect((await jane.belongsToMany(Role.new).get()).map((r) => r.name), [
        'editor',
      ]);
      expect(await jane.hasOne(Profile.new).first(), isNull);
    });

    test('eager loading uses one extra query per relation (no N+1)', () async {
      counter.count = 0;
      final users = await User.query().orderBy('id').withRelations([
        'posts',
        'profile',
        'company',
        'roles',
      ]).get();
      // 1 users query + 1 per relation (belongsToMany = pivot + related = 2)
      expect(counter.count, 1 + 1 + 1 + 1 + 2);
      final j = users[0], n = users[1];
      expect(j.many<Post>('posts').map((p) => p.title), ['J1', 'J2']);
      expect(j.one<Profile>('profile')!.bio, 'hi');
      expect(j.one<Company>('company')!.name, 'Acme');
      expect(j.many<Role>('roles').map((r) => r.name), ['admin', 'editor']);
      expect(n.many<Post>('posts').map((p) => p.title), ['N1']);
      expect(n.one<Profile>('profile'), isNull);
      expect(n.one<Company>('company'), isNull);
      expect(n.many<Role>('roles').map((r) => r.name), ['editor']);
      final json = j.toJson();
      expect((json['posts'] as List), hasLength(2));
      expect(json['company'], containsPair('name', 'Acme'));
    });

    test(
      'eager loading respects soft deletes and unknown relation fails loudly',
      () async {
        final p = (await john.hasMany(Post.new).first())!;
        await p.delete();
        final u = (await User.query()
            .withRelations(['posts'])
            .where('id', john.id!)
            .first())!;
        expect(u.many<Post>('posts'), hasLength(1));
        await expectLater(
          User.query().withRelations(['nope']).get(),
          throwsArgumentError,
        );
      },
    );
  });
}
