import 'results.dart';

class Paginator {
  const Paginator({
    required this.data,
    required this.currentPage,
    required this.perPage,
    required this.total,
  });

  final List<Row> data;
  final int currentPage;
  final int perPage;
  final int total;

  int get lastPage => total == 0 ? 1 : (total + perPage - 1) ~/ perPage;
  bool get hasNextPage => currentPage < lastPage;
  bool get hasPreviousPage => currentPage > 1;

  /// Pagination metadata, suitable for the `meta` field of an API response.
  Map<String, Object?> get meta => {
    'current_page': currentPage,
    'per_page': perPage,
    'total': total,
    'last_page': lastPage,
    'has_next_page': hasNextPage,
    'has_previous_page': hasPreviousPage,
  };

  Map<String, Object?> toJson() => {'data': data, 'meta': meta};
}
