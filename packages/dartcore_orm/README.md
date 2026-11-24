# dartcore_orm

An explicit, lightweight ORM for DartCore: models, relationships, eager loading without N+1, soft deletes and events.

Part of [DartCore](https://github.com/abqamar/dartcore_framework), a pure-Dart backend SDK.

## Install

```sh
dart pub add dartcore_orm
```

Needs `dartcore_db` with a connected database adapter. Dart AOT has no reflection, so each model declares its mapping explicitly
(`dartcore make:model Post -m` generates this for you).

## Usage

```dart
import 'package:dartcore_orm/dartcore_orm.dart';

class Post extends Model {
  int? id;
  String? title;

  @override String get table => 'posts';
  @override bool get softDeletes => true;
  @override List<String> get fillable => ['title'];                  // mass-assignment whitelist
  @override Map<String, Object> get rules => {'title': 'required|string|min:2'};

  @override Map<String, Object?> toMap() => {'id': id, 'title': title};
  @override void fillFromMap(Map<String, Object?> m) {
    if (m.containsKey('id')) id = Casts.asInt(m['id']);
    if (m.containsKey('title')) title = m['title'] as String?;
  }

  static final repo = ModelRepository<Post>(Post.new);
}

final post = await Post.repo.create({'title': 'Hello'});    // validates, sets timestamps
await post.update({'title': 'Updated'});
await post.delete();                                        // soft delete
await post.restore();
final posts = await Post.repo.query().where('title', 'like', 'H%').orderBy('id').get();
final page = await Post.repo.query().paginate(page: 1, limit: 20);
```

Relations: `HasMany`, `HasOne`, `BelongsTo`, `BelongsToMany`. Declare them in `relationDefs` and eager-load with
`query().withRelations(['posts'])`: one extra query per relation regardless of how many parents. Lifecycle hooks
(`onCreating`, `onSaved`, `onDeleted`, ...) can throw to abort.

The runnable [example](https://github.com/abqamar/dartcore_framework/blob/main/packages/dartcore_orm/example/dartcore_orm_example.dart) uses SQLite `:memory:`.

## Status and limits

Pre-1.0: the API may change. No identity map, no dirty tracking (updates write all `toMap()` columns), no lazy loading on
property access, no polymorphic relations, no code generation yet. See the [ORM guide](https://github.com/abqamar/dartcore_framework/blob/main/docs/orm.md).
