/// A runtime monitoring dashboard for DartCore apps.
///
/// ```dart
/// final app = DartCore();
/// Dashboard.attach(app, token: Config.require('DASHBOARD_TOKEN'));
/// // open http://localhost:8080/_dashboard
/// ```
library;

export 'src/collector.dart'
    show Collector, DashboardOptions, EndpointStats, Impact;
export 'src/dashboard.dart' show Dashboard;
