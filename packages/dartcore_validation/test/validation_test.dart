import 'package:dartcore_core/dartcore_core.dart';
import 'package:dartcore_validation/dartcore_validation.dart';
import 'package:test/test.dart';

void main() {
  group('basic rules', () {
    test('required / string / min / email', () {
      final v = Validate.request(
        {'name': 'Jo', 'email': 'bad'},
        {
          'name': 'required|string|min:3',
          'email': 'required|email',
          'password': 'required|min:8',
        },
      );
      expect(v.fails, isTrue);
      expect(v.errors['name'], ['The name must be at least 3 characters.']);
      expect(v.errors['email'], ['The email must be a valid email address.']);
      expect(v.errors['password'], ['The password field is required.']);
    });

    test(
      'valid input yields only validated fields (mass-assignment guard)',
      () {
        final v = Validate.request(
          {'name': 'John', 'email': 'a@b.co', 'is_admin': true},
          {'name': 'required|string', 'email': 'required|email'},
        );
        expect(v.passes, isTrue);
        expect(v.validated, {'name': 'John', 'email': 'a@b.co'});
        expect(v.get<String>('name'), 'John');
        expect(() => v.get<int>('name'), throwsStateError);
      },
    );

    test(
      'accessing validated on failure throws; orThrow -> ValidationException',
      () {
        final v = Validate.request({}, {'a': 'required'});
        expect(() => v.validated, throwsStateError);
        expect(v.orThrow, throwsA(isA<ValidationException>()));
      },
    );

    test('optional fields skip rules when absent; nullable accepts null', () {
      expect(Validate.request({}, {'age': 'integer|min:18'}).passes, isTrue);
      expect(
        Validate.request({'age': null}, {'age': 'nullable|integer'}).passes,
        isTrue,
      );
      expect(
        Validate.request({'age': 'x'}, {'age': 'nullable|integer'}).fails,
        isTrue,
      );
    });

    test('numeric min/max vs string length', () {
      expect(Validate.request({'n': 5}, {'n': 'integer|min:10'}).fails, isTrue);
      expect(
        Validate.request({'n': 15}, {'n': 'integer|min:10|max:20'}).passes,
        isTrue,
      );
      expect(
        Validate.request({'n': '15'}, {'n': 'integer|min:10'}).passes,
        isTrue,
        reason: 'numeric strings from forms compare numerically',
      );
      expect(
        Validate.request({'s': 'abcd'}, {'s': 'string|max:3'}).fails,
        isTrue,
      );
      expect(
        Validate.request(
          {
            't': [1, 2, 3],
          },
          {'t': 'array|max:2'},
        ).fails,
        isTrue,
      );
    });

    test('type rules', () {
      expect(Validate.request({'b': 'true'}, {'b': 'boolean'}).passes, isTrue);
      expect(Validate.request({'b': 'yes'}, {'b': 'boolean'}).fails, isTrue);
      expect(
        Validate.request({'u': 'https://x.io/a'}, {'u': 'url'}).passes,
        isTrue,
      );
      expect(
        Validate.request({'u': 'javascript:alert(1)'}, {'u': 'url'}).fails,
        isTrue,
      );
      expect(
        Validate.request({'d': '2025-02-30x'}, {'d': 'date'}).fails,
        isTrue,
      );
      expect(
        Validate.request({'d': '2025-02-10'}, {'d': 'date'}).passes,
        isTrue,
      );
      expect(Validate.request({'n': '1.5'}, {'n': 'numeric'}).passes, isTrue);
    });

    test('size, regex, in, not_in, confirmed, same', () {
      expect(Validate.request({'c': 'ab'}, {'c': 'size:3'}).fails, isTrue);
      expect(
        Validate.request({'c': 'ABC'}, {'c': r'regex:^[A-Z]{3}$'}).passes,
        isTrue,
      );
      expect(
        Validate.request({'r': 'x'}, {'r': 'in:admin,user'}).fails,
        isTrue,
      );
      expect(
        Validate.request({'r': 'admin'}, {'r': 'in:admin,user'}).passes,
        isTrue,
      );
      expect(
        Validate.request({'r': 'admin'}, {'r': 'not_in:admin'}).fails,
        isTrue,
      );
      expect(
        Validate.request(
          {'p': 'a', 'p_confirmation': 'b'},
          {'p': 'confirmed'},
        ).fails,
        isTrue,
      );
      expect(
        Validate.request(
          {'p': 'a', 'p_confirmation': 'a'},
          {'p': 'confirmed'},
        ).passes,
        isTrue,
      );
    });

    test('unknown rule is a programmer error, not a silent pass', () {
      expect(
        () => Validate.request({'a': 1}, {'a': 'frobnicate'}),
        throwsArgumentError,
      );
    });
  });

  group('structure', () {
    test('nested objects with dot notation', () {
      final v = Validate.request(
        {
          'address': {'city': ''},
        },
        {'address.city': 'required|string', 'address.zip': 'required'},
      );
      expect(v.errors.keys, containsAll(['address.city', 'address.zip']));
    });

    test('array wildcards', () {
      final v = Validate.request(
        {
          'items': [
            {'id': 1, 'qty': 2},
            {'id': 'x', 'qty': 0},
          ],
        },
        {
          'items': 'required|array|min:1',
          'items.*.id': 'required|integer',
          'items.*.qty': 'required|integer|min:1',
        },
      );
      expect(v.errors.keys, unorderedEquals(['items.1.id', 'items.1.qty']));
    });

    test('conditional rules', () {
      final rules = {
        'company': 'required_if:type,business',
        'phone': 'required_with:company',
      };
      expect(Validate.request({'type': 'personal'}, rules).passes, isTrue);
      final v = Validate.request({'type': 'business'}, rules);
      expect(v.errors.keys, ['company']);
      expect(
        Validate.request({
          'type': 'personal',
          'company': 'X',
        }, rules).errors.keys,
        ['phone'],
      );
    });
  });

  group('messages & custom rules', () {
    test('custom messages and attribute names', () {
      final v = Validate.request(
        {},
        {'email': 'required'},
        messages: {'email.required': 'We need your email!'},
      );
      expect(v.errors['email'], ['We need your email!']);
      final v2 = Validate.request(
        {},
        {'user_name': 'required'},
        attributes: {'user_name': 'username'},
      );
      expect(v2.errors['user_name'], ['The username field is required.']);
    });

    test('custom rule objects', () {
      final even = Rule.custom(
        (v, c) => (v as int) % 2 == 0 ? null : 'Must be even.',
        name: 'even',
      );
      expect(
        Validate.request(
          {'n': 3},
          {
            'n': [even],
          },
        ).errors['n'],
        ['Must be even.'],
      );
      expect(
        Validate.request(
          {'n': 4},
          {
            'n': ['integer', even],
          },
        ).passes,
        isTrue,
      );
    });
  });

  group('async rules', () {
    final taken = {'a@x.io'};
    Future<bool> checker(
      String table,
      String column,
      Object? v, {
      Object? ignoreId,
      String ignoreColumn = 'id',
    }) async => taken.contains(v);

    test('unique / exists via checker', () async {
      final r = await Validate.requestAsync(
        {'email': 'a@x.io', 'ref': 'nope'},
        {'email': 'unique:users,email', 'ref': 'exists:users,email'},
        exists: checker,
      );
      expect(r.errors['email'], ['The email has already been taken.']);
      expect(r.errors['ref'], ['The selected ref is invalid.']);
      expect(
        (await Validate.requestAsync(
          {'email': 'new@x.io'},
          {'email': 'unique:users'},
          exists: checker,
        )).passes,
        isTrue,
      );
    });

    test(
      'sync API refuses I/O rules; missing checker is a config error',
      () async {
        expect(
          () => Validate.request({'e': 'a'}, {'e': 'unique:users'}),
          throwsStateError,
        );
        await expectLater(
          Validate.requestAsync({'e': 'a'}, {'e': 'unique:users'}),
          throwsA(isA<ConfigurationException>()),
        );
      },
    );

    test('async custom rule', () async {
      final r = await Validate.requestAsync(
        {'n': 1},
        {
          'n': [Rule.customAsync((v, c) async => 'always bad', name: 'bad')],
        },
      );
      expect(r.errors['n'], ['always bad']);
    });
  });
}
