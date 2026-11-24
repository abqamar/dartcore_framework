// Rule-string validation (no server needed).
//
// Observed output of `dart run example/dartcore_validation_example.dart`:
//
//   bad.fails = true
//   errors    = {name: [The name must be at least 3 characters.], email: [The email must be a valid email address.], items.0.qty: [The qty must be at least 1.]}
//   good.fails = false
//   validated  = {name: Alice, email: alice@example.com, items: [{qty: 2}], items.0.qty: 2}
//   name       = Alice
//   {n: [Must be even.]}

import 'package:dartcore_validation/dartcore_validation.dart';

void main() {
  final rules = {
    'name': 'required|string|min:3',
    'email': 'required|email',
    'age': 'nullable|integer|min:18|max:120',
    'items': 'required|array|min:1',
    'items.*.qty': 'required|integer|min:1',
  };

  final bad = Validate.request({
    'name': 'Al',
    'email': 'not-an-email',
    'items': [
      {'qty': 0},
    ],
  }, rules);
  print('bad.fails = ${bad.fails}');
  print('errors    = ${bad.errors}');

  final good = Validate.request({
    'name': 'Alice',
    'email': 'alice@example.com',
    'extra': 'ignored',
    'items': [
      {'qty': 2},
    ],
  }, rules);
  print('good.fails = ${good.fails}');
  // Only fields that had rules are returned: "extra" is dropped.
  print('validated  = ${good.validated}');
  print('name       = ${good.get<String>('name')}');

  // Custom rule objects can be mixed with string rules.
  final even = Rule.custom(
    (value, ctx) => (value as int).isEven ? null : 'Must be even.',
    name: 'even',
  );
  print(
    Validate.request(
      {'n': 3},
      {
        'n': ['integer', even],
      },
    ).errors,
  );
}
