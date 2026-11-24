import 'dart:async';
import 'dart:collection';

import 'package:dartcore_core/dartcore_core.dart';

class PoolStats {
  const PoolStats({
    required this.size,
    required this.idle,
    required this.inUse,
    required this.waiting,
  });
  final int size, idle, inUse, waiting;

  @override
  String toString() =>
      'PoolStats(size: $size, idle: $idle, inUse: $inUse, waiting: $waiting)';
}

class _Idle<T> {
  _Idle(this.resource) : since = DateTime.now();
  final T resource;
  DateTime since;
}

/// A bounded async resource pool with idle eviction, health validation and a
/// FIFO wait queue. It is driver-agnostic and is what gives *every* DartCore
/// adapter the same pooling behaviour.
class ConnectionPool<T extends Object> {
  ConnectionPool({
    required this.create,
    required this.destroy,
    this.validate,
    this.maxSize = 10,
    this.idleTimeout = const Duration(minutes: 5),
    this.acquireTimeout = const Duration(seconds: 30),
    this.validateAfterIdle = const Duration(seconds: 30),
  }) : assert(maxSize > 0) {
    final every = idleTimeout ~/ 2;
    _reaper = Timer.periodic(
      every < const Duration(milliseconds: 50)
          ? const Duration(milliseconds: 50)
          : every,
      (_) => _evictIdle(),
    );
  }

  final Future<T> Function() create;
  final Future<void> Function(T) destroy;

  /// Returns false when a resource is dead. Called on idle resources that have
  /// been parked longer than [validateAfterIdle].
  final Future<bool> Function(T)? validate;
  final int maxSize;
  final Duration idleTimeout, acquireTimeout, validateAfterIdle;

  final Queue<_Idle<T>> _idle = Queue();
  final Queue<Completer<T>> _waiters = Queue();
  int _total = 0; // idle + in use + being created
  bool _closed = false;
  Timer? _reaper;

  PoolStats get stats => PoolStats(
    size: _total,
    idle: _idle.length,
    inUse: _total - _idle.length,
    waiting: _waiters.length,
  );

  Future<T> acquire() async {
    if (_closed) throw ConnectionException('The connection pool is closed.');
    while (_idle.isNotEmpty) {
      final entry = _idle.removeLast();
      if (await _isHealthy(entry)) return entry.resource;
      _total--;
      await _safeDestroy(entry.resource);
    }
    if (_total < maxSize) {
      _total++;
      try {
        return await create();
      } catch (_) {
        _total--;
        _serveWaiters();
        rethrow;
      }
    }
    final waiter = Completer<T>();
    _waiters.add(waiter);
    return waiter.future.timeout(
      acquireTimeout,
      onTimeout: () {
        _waiters.remove(waiter);
        throw ConnectionException(
          'Timed out after ${acquireTimeout.inSeconds}s waiting for a database '
          'connection (pool size $maxSize). Increase maxPoolSize or shorten queries.',
        );
      },
    );
  }

  Future<bool> _isHealthy(_Idle<T> e) async {
    if (validate == null) return true;
    if (DateTime.now().difference(e.since) < validateAfterIdle) return true;
    try {
      return await validate!(e.resource);
    } catch (_) {
      return false;
    }
  }

  /// Returns [resource] to the pool. Pass [discard] for broken resources.
  void release(T resource, {bool discard = false}) {
    if (_closed || discard) {
      _total--;
      unawaited(_safeDestroy(resource));
      _serveWaiters();
      return;
    }
    while (_waiters.isNotEmpty) {
      final w = _waiters.removeFirst();
      if (!w.isCompleted) {
        w.complete(resource);
        return;
      }
    }
    _idle.add(_Idle(resource));
  }

  /// A discarded resource frees capacity: create a replacement for a waiter.
  void _serveWaiters() {
    while (_waiters.isNotEmpty && _total < maxSize && !_closed) {
      final w = _waiters.removeFirst();
      if (w.isCompleted) continue;
      _total++;
      create().then(
        w.complete,
        onError: (Object e, StackTrace s) {
          _total--;
          w.completeError(e, s);
        },
      );
    }
  }

  void _evictIdle() {
    final now = DateTime.now();
    final stale = _idle
        .where((e) => now.difference(e.since) >= idleTimeout)
        .toList();
    for (final e in stale) {
      _idle.remove(e);
      _total--;
      unawaited(_safeDestroy(e.resource));
    }
  }

  Future<void> _safeDestroy(T r) async {
    try {
      await destroy(r);
    } catch (_) {}
  }

  /// Closes idle resources immediately; in-use resources are destroyed when
  /// released. Pending waiters fail.
  Future<void> close() async {
    _closed = true;
    _reaper?.cancel();
    for (final w in _waiters) {
      if (!w.isCompleted) {
        w.completeError(ConnectionException('The connection pool was closed.'));
      }
    }
    _waiters.clear();
    final idle = _idle.toList();
    _idle.clear();
    _total -= idle.length;
    for (final e in idle) {
      await _safeDestroy(e.resource);
    }
  }
}
