/// The deployment environment an application is running in.
enum AppEnvironment {
  development,
  testing,
  staging,
  production;

  /// Parses common spellings (`prod`, `dev`, `test`, ...). Unknown values
  /// fall back to [production] so that a typo never enables debug behaviour.
  static AppEnvironment parse(String? value) {
    switch (value?.trim().toLowerCase()) {
      case 'development' || 'dev' || 'local':
        return development;
      case 'testing' || 'test':
        return testing;
      case 'staging' || 'stage':
        return staging;
      default:
        return production;
    }
  }

  bool get isProduction => this == production;
  bool get isDevelopment => this == development;
}
