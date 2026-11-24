# ORM and relationships (`dartcore_orm`)

Dart compiled apps have no reflection, so models declare their mapping explicitly. `dartcore make:model Post -m
--fields=title:string,views:int` generates all of this.

```dart
class Post extends Model {
  int? id; String? title; int? userId;

  @override String get table => 'posts';
  @override bool get softDeletes => true;                    // uses deleted_at
  @override List<String> get fillable => ['title', 'user_id'];   // mass-assignment whitelist (empty = nothing)
  @override List<String> get hidden => [];                   // removed from toJson()
  @override Map<String, Object> get rules => {'title': 'required|string|min:2'};  // validated before save()

  @override Map<String, Object?> toMap() => {'id': id, 'title': title, 'user_id': userId};
  @override void fillFromMap(Map<String, Object?> m) {
    if (m.containsKey('id')) id = Casts.asInt(m['id']);
    if (m.containsKey('title')) title = m['title'] as String?;
    if (m.containsKey('user_id')) userId = Casts.asInt(m['user_id']);
  }

  @override Map<String, RelationDef> get relationDefs => {'author': BelongsTo<User>(User.new)};

  static final repo = ModelRepository<Post>(Post.new);
  static Future<Post?> find(Object id) => repo.find(id);
  static ModelQuery<Post> query() => repo.query();
  static Future<Post> create(Map<String, Object?> a) => repo.create(a);
}
```

## Usage

```dart
final posts = await Post.query().where('user_id', 1).orderBy('id').get();
final post  = await Post.find(1);
final saved = await Post.create({'title': 'Hello', 'user_id': 1});   // only fillable keys are applied
await post?.update({'title': 'Updated'});
await post?.delete();                  // soft delete → trashed == true
await post?.restore();  await post?.forceDelete();
await post?.refresh();
Post.query().withTrashed(); Post.query().onlyTrashed();
final page = await Post.query().paginate(page: 1, limit: 20);       // page.data are Post models, page.meta
```

Timestamps: `created_at`/`updated_at` are set on save (disable with `timestamps => false`) and exposed as `createdAt`,
`updatedAt`, `deletedAt`. Hooks (override, throw to abort): `onSaving onCreating onCreated onUpdating onUpdated onSaved
onDeleting onDeleted`. `validate()` runs the `rules` and throws `ValidationException`. Use `forceFill` only with trusted data.
Use `Casts.asInt/asBool/asDouble/asDate` in `fillFromMap` — engines return different primitive types.

## Relationships

Pass constructor tear-offs (`Post.new`), not types:

```dart
user.hasMany(Post.new)                    // ModelQuery<Post>, foreign key defaults to user_id
user.hasOne(Profile.new)
post.belongsTo(User.new)                  // foreign key user_id on the post, owner key id
user.belongsToMany(Role.new, pivotTable: 'role_user', foreignPivotKey: 'user_id', relatedPivotKey: 'role_id')
await user.hasMany(Post.new).where('title', 'like', 'A%').get();
```

Defaults derive from table names naively (`users` → `user_id`); pass explicit keys otherwise.

### Eager loading (no N+1)

Declare `relationDefs` on the model, then:

```dart
final users = await User.query().withRelations(['posts', 'profile', 'roles']).get();
users.first.many<Post>('posts');          // List<Post>
users.first.one<Profile>('profile');      // Profile?
users.first.toJson();                     // includes loaded relations
```

One extra query per relation (two for many-to-many), regardless of the number of parents — asserted in
`orm_test.dart`. Soft-deleted related rows are excluded.

## Limits

No identity map, no dirty tracking (updates write all `toMap()` columns), no lazy-loading on property access, no polymorphic
relations. Typed code generation is on the [roadmap](../ROADMAP.md).
