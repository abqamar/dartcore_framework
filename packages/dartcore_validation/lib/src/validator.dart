import 'package:dartcore_core/dartcore_core.dart';

/// Checks whether a row exists, for the `unique` / `exists` rules. The
/// umbrella `dartcore` package wires this to the database; keep it
/// parameterized (never build SQL from these strings yourself).
typedef ExistenceChecker =
    Future<bool> Function(
      String table,
      String column,
      Object? value, {
      Object? ignoreId,
      String ignoreColumn,
    });

/// Passed to custom rules.
class RuleContext {
  RuleContext(this.field, this.data);
  final String field;
  final Map<String, dynamic> data;

  /// Value of another field (dot notation supported).
  Object? other(String path) => _read(data, path.split('.'));
}

/// A custom rule. Return `null` when valid, or an error message.
class Rule {
  Rule.custom(this.check, {this.name = 'custom'}) : checkAsync = null;
  Rule.customAsync(this.checkAsync, {this.name = 'custom'}) : check = null;

  final String name;
  final String? Function(Object? value, RuleContext context)? check;
  final Future<String?> Function(Object? value, RuleContext context)?
  checkAsync;
}

class ValidationResult {
  ValidationResult(this.errors, this._validated);

  /// Field -> messages. Empty when valid.
  final Map<String, List<String>> errors;
  final Map<String, Object?> _validated;

  bool get passes => errors.isEmpty;
  bool get fails => errors.isNotEmpty;

  /// Only the fields that had rules *and* were present, so unvalidated
  /// (potentially malicious) extra input never leaks through.
  Map<String, Object?> get validated {
    if (fails) {
      throw StateError('Cannot read validated data from a failed validation.');
    }
    return Map.unmodifiable(_validated);
  }

  /// Typed access to a validated value.
  T? get<T>(String field) {
    final v = validated[field];
    if (v == null) return null;
    if (v is T) return v as T;
    throw StateError('Field "$field" is ${v.runtimeType}, not $T.');
  }

  /// Throws [ValidationException] (HTTP 422) when invalid.
  ValidationResult orThrow() {
    if (fails) throw ValidationException(errors);
    return this;
  }
}

abstract final class Validate {
  /// Validates [data] synchronously. Rules `unique` and `exists` need I/O and
  /// are rejected here: use [requestAsync].
  static ValidationResult request(
    Map<String, dynamic> data,
    Map<String, Object> rules, {
    Map<String, String> messages = const {},
    Map<String, String> attributes = const {},
  }) => _sync(_Engine(data, rules, messages, attributes, null));

  static Future<ValidationResult> requestAsync(
    Map<String, dynamic> data,
    Map<String, Object> rules, {
    Map<String, String> messages = const {},
    Map<String, String> attributes = const {},
    ExistenceChecker? exists,
  }) => _Engine(data, rules, messages, attributes, exists).runAsync();

  static ValidationResult _sync(_Engine e) {
    final f = e.run(allowAsync: false);
    return f;
  }
}

Object? _read(Object? node, List<String> path) {
  var cur = node;
  for (final p in path) {
    if (cur is Map && cur.containsKey(p)) {
      cur = cur[p];
    } else if (cur is List &&
        int.tryParse(p) != null &&
        int.parse(p) < cur.length) {
      cur = cur[int.parse(p)];
    } else {
      return null;
    }
  }
  return cur;
}

bool _has(Object? node, List<String> path) {
  var cur = node;
  for (final p in path) {
    if (cur is Map && cur.containsKey(p)) {
      cur = cur[p];
    } else if (cur is List &&
        int.tryParse(p) != null &&
        int.parse(p) < cur.length) {
      cur = cur[int.parse(p)];
    } else {
      return false;
    }
  }
  return true;
}

class _Parsed {
  _Parsed(this.name, this.args, [this.custom]);
  final String name;
  final List<String> args;
  final Rule? custom;
}

class _Engine {
  _Engine(this.data, this.rules, this.messages, this.attributes, this.exists);

  final Map<String, dynamic> data;
  final Map<String, Object> rules;
  final Map<String, String> messages, attributes;
  final ExistenceChecker? exists;

  final Map<String, List<String>> errors = {};
  final Map<String, Object?> validated = {};

  static final _email = RegExp(
    r"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$",
  );

  List<_Parsed> _parse(Object spec) {
    final items = spec is String ? spec.split('|') : (spec as List);
    return [
      for (final i in items)
        if (i is Rule)
          _Parsed(i.name, const [], i)
        else if ((i as String).trim().isNotEmpty)
          () {
            final s = i.trim();
            final c = s.indexOf(':');
            return _Parsed(
              c < 0 ? s : s.substring(0, c),
              c < 0 ? const [] : s.substring(c + 1).split(','),
            );
          }(),
    ];
  }

  /// Expands `items.*.id` into concrete dot paths present in [data].
  List<String> _expand(String pattern) {
    var paths = <List<String>>[[]];
    for (final seg in pattern.split('.')) {
      final next = <List<String>>[];
      for (final p in paths) {
        if (seg == '*') {
          final node = _read(data, p);
          if (node is List) {
            for (var i = 0; i < node.length; i++) {
              next.add([...p, '$i']);
            }
          } else if (node is Map) {
            for (final k in node.keys) {
              next.add([...p, k.toString()]);
            }
          }
        } else {
          next.add([...p, seg]);
        }
      }
      paths = next;
    }
    return [for (final p in paths) p.join('.')];
  }

  ValidationResult run({required bool allowAsync}) {
    for (final entry in rules.entries) {
      for (final path in _expand(entry.key)) {
        final parsed = _parse(entry.value);
        _field(path, entry.key, parsed, allowAsync: allowAsync);
      }
    }
    return ValidationResult(errors, validated);
  }

  Future<ValidationResult> runAsync() async {
    for (final entry in rules.entries) {
      for (final path in _expand(entry.key)) {
        final parsed = _parse(entry.value);
        final pending = <Future<void> Function()>[];
        _field(path, entry.key, parsed, allowAsync: true, pending: pending);
        for (final p in pending) {
          await p();
        }
      }
    }
    return ValidationResult(errors, validated);
  }

  bool _isEmpty(Object? v) =>
      v == null ||
      (v is String && v.trim().isEmpty) ||
      (v is List && v.isEmpty);

  void _fail(
    String path,
    String patternKey,
    String rule,
    String defaultMsg, {
    Map<String, String> replace = const {},
  }) {
    var msg =
        messages['$patternKey.$rule'] ??
        messages['$path.$rule'] ??
        messages[rule] ??
        defaultMsg;
    final label =
        attributes[path] ??
        attributes[patternKey] ??
        path.split('.').last.replaceAll('_', ' ');
    msg = msg.replaceAll(':attribute', label);
    replace.forEach((k, v) => msg = msg.replaceAll(':$k', v));
    (errors[path] ??= []).add(msg);
  }

  void _field(
    String path,
    String patternKey,
    List<_Parsed> rs, {
    required bool allowAsync,
    List<Future<void> Function()>? pending,
  }) {
    final segs = path.split('.');
    final value = _read(data, segs);
    final present = _has(data, segs);
    final names = rs.map((r) => r.name).toSet();
    final nullable = names.contains('nullable');
    final sometimes = names.contains('sometimes');
    if (sometimes && !present) return;

    // required family
    var requiredRule = names.contains('required');
    for (final r in rs) {
      if (r.name == 'required_if' && r.args.length >= 2) {
        if ('${_read(data, r.args[0].split('.'))}' == r.args[1]) {
          requiredRule = true;
        }
      } else if (r.name == 'required_with' &&
          r.args.any((a) => !_isEmpty(_read(data, a.split('.'))))) {
        requiredRule = true;
      } else if (r.name == 'required_unless' && r.args.length >= 2) {
        if ('${_read(data, r.args[0].split('.'))}' != r.args[1]) {
          requiredRule = true;
        }
      }
    }
    if (requiredRule && _isEmpty(value)) {
      _fail(path, patternKey, 'required', 'The :attribute field is required.');
      return;
    }
    if (_isEmpty(value) || (value == null && nullable)) {
      if (present && value != null) validated[path] = value;
      if (present && value == null) validated[path] = null;
      return;
    }

    var ok = true;
    for (final r in rs) {
      if (const {
        'required',
        'nullable',
        'sometimes',
        'required_if',
        'required_with',
        'required_unless',
        'bail',
      }.contains(r.name)) {
        continue;
      }
      if (r.custom != null) {
        final c = r.custom!;
        if (c.check != null) {
          final m = c.check!(value, RuleContext(path, data));
          if (m != null) {
            ok = false;
            _fail(path, patternKey, c.name, m);
          }
        } else {
          if (!allowAsync) {
            throw StateError(
              'Rule "${c.name}" is async; use Validate.requestAsync.',
            );
          }
          pending!.add(() async {
            final m = await c.checkAsync!(value, RuleContext(path, data));
            if (m != null) _fail(path, patternKey, c.name, m);
          });
        }
      } else if (r.name == 'unique' || r.name == 'exists') {
        if (!allowAsync) {
          throw StateError(
            'Rule "${r.name}" needs I/O; use Validate.requestAsync.',
          );
        }
        final checker =
            exists ??
            (throw ConfigurationException(
              'The "${r.name}" rule needs an ExistenceChecker (pass exists: to requestAsync).',
            ));
        if (r.args.isEmpty) {
          throw ArgumentError('${r.name} requires a table name.');
        }
        final table = r.args[0];
        final column = r.args.length > 1 ? r.args[1] : path.split('.').last;
        pending!.add(() async {
          final found = await checker(
            table,
            column,
            value,
            ignoreId: r.args.length > 2 ? r.args[2] : null,
            ignoreColumn: r.args.length > 3 ? r.args[3] : 'id',
          );
          if (r.name == 'unique' && found) {
            _fail(
              path,
              patternKey,
              'unique',
              'The :attribute has already been taken.',
            );
          } else if (r.name == 'exists' && !found) {
            _fail(
              path,
              patternKey,
              'exists',
              'The selected :attribute is invalid.',
            );
          }
        });
      } else {
        final msg = _check(r, value, path);
        if (msg != null) {
          ok = false;
          _fail(path, patternKey, r.name, msg.$1, replace: msg.$2);
          if (names.contains('bail')) break;
        }
      }
    }
    if (ok) validated[path] = value;
  }

  num? _size(Object? v) => switch (v) {
    num n => n,
    String s => s.runes.length,
    List<Object?> l => l.length,
    Map<Object?, Object?> m => m.length,
    _ => null,
  };

  (String, Map<String, String>)? _check(_Parsed r, Object? v, String path) {
    (String, Map<String, String>) m(
      String s, [
      Map<String, String> rep = const {},
    ]) => (s, rep);
    switch (r.name) {
      case 'string':
        return v is String ? null : m('The :attribute must be a string.');
      case 'integer':
        final ok = v is int || (v is String && int.tryParse(v.trim()) != null);
        return ok ? null : m('The :attribute must be an integer.');
      case 'numeric' || 'number':
        final ok = v is num || (v is String && num.tryParse(v.trim()) != null);
        return ok ? null : m('The :attribute must be a number.');
      case 'boolean':
        final ok =
            v is bool || const [0, 1, '0', '1', 'true', 'false'].contains(v);
        return ok ? null : m('The :attribute must be true or false.');
      case 'array':
        return v is List ? null : m('The :attribute must be an array.');
      case 'object':
        return v is Map ? null : m('The :attribute must be an object.');
      case 'email':
        return v is String && v.length <= 254 && _email.hasMatch(v)
            ? null
            : m('The :attribute must be a valid email address.');
      case 'url':
        final u = v is String ? Uri.tryParse(v) : null;
        return u != null &&
                (u.scheme == 'http' || u.scheme == 'https') &&
                u.host.isNotEmpty
            ? null
            : m('The :attribute must be a valid URL.');
      case 'date':
        return v is DateTime || (v is String && DateTime.tryParse(v) != null)
            ? null
            : m('The :attribute must be a valid date.');
      case 'min' || 'max':
        final limit = num.tryParse(r.args.firstOrNull ?? '');
        if (limit == null) {
          throw ArgumentError('${r.name} requires a numeric argument.');
        }
        final n =
            v is String &&
                v.isNotEmpty &&
                num.tryParse(v.trim()) != null &&
                _numericContext(path)
            ? num.parse(v.trim())
            : _size(v);
        if (n == null) return m('The :attribute is not comparable.');
        final bad = r.name == 'min' ? n < limit : n > limit;
        final unit = v is num ? '' : (v is List ? ' items' : ' characters');
        return bad
            ? m(
                'The :attribute must be ${r.name == 'min' ? 'at least' : 'at most'} :limit$unit.',
                {'limit': r.args.first},
              )
            : null;
      case 'size' || 'length':
        final want = num.tryParse(r.args.firstOrNull ?? '');
        if (want == null) {
          throw ArgumentError('size requires a numeric argument.');
        }
        return _size(v) == want
            ? null
            : m('The :attribute must be exactly :size.', {
                'size': r.args.first,
              });
      case 'regex':
        final pattern = r.args.join(',');
        return v is String && RegExp(pattern).hasMatch(v)
            ? null
            : m('The :attribute format is invalid.');
      case 'in':
        return r.args.contains('$v')
            ? null
            : m('The selected :attribute is invalid.');
      case 'not_in':
        return !r.args.contains('$v')
            ? null
            : m('The selected :attribute is invalid.');
      case 'confirmed':
        final other = _read(data, '${path}_confirmation'.split('.'));
        return other == v
            ? null
            : m('The :attribute confirmation does not match.');
      case 'same':
        return _read(data, (r.args.firstOrNull ?? '').split('.')) == v
            ? null
            : m('The :attribute must match ${r.args.firstOrNull}.');
    }
    throw ArgumentError('Unknown validation rule "${r.name}".');
  }

  // min/max compare numerically only when the rules also declare numeric/integer.
  bool _numericContext(String path) {
    final spec =
        rules[path] ??
        rules.entries
            .firstWhere(
              (e) =>
                  e.key.replaceAll('*', '') ==
                  path.replaceAll(RegExp(r'\d+'), ''),
              orElse: () => const MapEntry('', ''),
            )
            .value;
    final names = _parse(spec).map((p) => p.name);
    return names.contains('integer') ||
        names.contains('numeric') ||
        names.contains('number');
  }
}
