/// Naming helpers shared by generators.
abstract final class Names {
  /// `UserController`, `user_controller`, `user-controller` -> `UserController`.
  static String pascal(String input) {
    final parts = input
        .replaceAllMapped(
          RegExp(r'([a-z0-9])([A-Z])'),
          (m) => '${m[1]}_${m[2]}',
        )
        .split(RegExp(r'[_\-\s]+'))
        .where((p) => p.isNotEmpty);
    return parts
        .map((p) => p[0].toUpperCase() + p.substring(1).toLowerCase())
        .join();
  }

  /// `UserController` -> `user_controller`.
  static String snake(String input) => input
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
      .replaceAll(RegExp(r'[\-\s]+'), '_')
      .toLowerCase();

  /// Naive English plural for table names (`user` -> `users`, `category` -> `categories`).
  static String plural(String snake) {
    if (snake.endsWith('s')) return snake;
    if (snake.endsWith('y') && !RegExp(r'[aeiou]y$').hasMatch(snake)) {
      return '${snake.substring(0, snake.length - 1)}ies';
    }
    if (RegExp(r'(x|z|ch|sh)$').hasMatch(snake)) return '${snake}es';
    return '${snake}s';
  }

  static final _valid = RegExp(r'^[A-Za-z][A-Za-z0-9_\-]*$');

  /// Rejects anything that could escape the target directory or break Dart syntax.
  static String validated(String input, String what) {
    if (!_valid.hasMatch(input)) {
      throw ArgumentError(
        'Invalid $what "$input": use letters, digits, "_" or "-" and start with a letter.',
      );
    }
    return input;
  }

  static String dartPackageName(String input) {
    final n = snake(input).replaceAll('-', '_');
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(n)) {
      throw ArgumentError('"$input" is not a valid Dart package name.');
    }
    return n;
  }
}
