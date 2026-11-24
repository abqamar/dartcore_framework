# Validation (`dartcore_validation`)

```dart
final v = Validate.request(await request.json(), {
  'name': 'required|string|min:3',
  'email': 'required|email',
  'password': 'required|min:8|confirmed',          // needs password_confirmation
  'age': 'nullable|integer|min:18|max:120',
  'role': 'in:admin,user',
  'address.city': 'required|string',               // nested objects: dot notation
  'items': 'required|array|min:1',
  'items.*.qty': 'required|integer|min:1',         // array wildcards
  'company': 'required_if:type,business',          // conditional
});

if (v.fails) return Response.validationError(v.errors);   // {"email": ["The email must be a valid email address."]}
final clean = v.validated;                                 // ONLY fields that had rules (and were present)
final name = v.get<String>('name');                        // typed; StateError if the type differs
v.orThrow();                                               // throws ValidationException (HTTP 422)
```

Reading `validated` on a failed result throws, so unvalidated data cannot slip through.

`validated` is a **flat map keyed by the rule path**. A rule on a nested field (`address.city`) or a wildcard rule
(`items.*.qty`) adds a dotted key (`address.city`, `items.0.qty`) next to its parent, and a parent that has its own rule
(`items`) is copied whole, including nested keys that have no rule of their own. So do not insert `validated` straight
into a table when you use nested or wildcard rules; pick the columns you mean:

```dart
await DB.table('orders').insert({
  'customer': v.get<String>('customer'),
  'items': jsonEncode(v.get<List>('items')),     // whole list, as sent
});
```


## Rules

`required` `nullable` `sometimes` `string` `integer` `numeric`/`number` `boolean` `array` `object` `email` `url` (http/https only)
`date` `min:n` `max:n` `size:n` `regex:pattern` `in:a,b` `not_in:a,b` `confirmed` `same:field` `required_if:field,value`
`required_with:field` `required_unless:field,value` `bail` `unique:table,column[,ignoreId[,idColumn]]` `exists:table,column`.

* `min`/`max`: numeric value when `integer`/`numeric` is also declared (or the value is a number), string length for strings, item
  count for lists.
* Absent/empty optional fields skip their other rules; `required` fails first and stops the field.
* An **unknown rule throws `ArgumentError`**: typos are never silent passes.
* `regex:` patterns cannot contain `|` in the string form (it separates rules): use a `Rule` object.

## Messages

```dart
Validate.request(data, rules,
    messages: {'email.required': 'We need your email!', 'min': 'Too short: :attribute needs :limit'},
    attributes: {'user_name': 'username'});
```

Placeholders: `:attribute`, `:limit`, `:size`. Lookup order: `field.rule`, `rule`, default.

## Custom and async rules

```dart
final even = Rule.custom((value, ctx) => (value as int).isEven ? null : 'Must be even.', name: 'even');
Validate.request(data, {'n': ['integer', even]});            // mix strings and Rule objects in a list

final v = await Validate.requestAsync(data, {'email': 'required|email|unique:users,email'},
    exists: databaseExistenceChecker(DB.manager));           // from package:dartcore_framework
```

`unique`/`exists` (and `Rule.customAsync`) need `requestAsync`; the sync API throws `StateError` instead of skipping them.
Table/column names come from your rule strings and are validated as identifiers; values are bound.
