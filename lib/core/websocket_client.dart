import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// =========================================================================
/// WebSocketClient
/// -------------------------------------------------------------------------
/// Persistent, self-healing duplex socket used for:
///   • Live driver telemetry → backend
///   • Live ride state broadcasts → rider & driver
///   • Dispatch offer pushes → driver
///
/// Guarantees:
///   1. Auto-reconnect with exponential backoff + jitter (never hot-loops).
///   2. Heartbeat/ping so idle NATs don't silently drop the socket.
///   3. Outbound queue — messages sent while offline are flushed on reconnect.
///   4. Typed event stream — consumers filter by `WsEvent.type`.
///   5. Thread-safe teardown — `dispose()` cancels timers, closes socket,
///      closes the stream controllers.
/// =========================================================================
class WebSocketClient {
  WebSocketClient({
    required this.url,
    this.headers = const {},
    this.pingInterval = const Duration(seconds: 20),
    this.pongTimeout = const Duration(seconds: 10),
    this.reconnectBase = const Duration(milliseconds: 500),
    this.reconnectMax = const Duration(seconds: 20),
    this.maxQueueSize = 200,
    this.debugLogging = kDebugMode,
  });

  /// Full ws(s):// URL, e.g. `wss://api.example.com/ws`.
  final String url;
  final Map<String, dynamic> headers;
  final Duration pingInterval;
  final Duration pongTimeout;
  final Duration reconnectBase;
  final Duration reconnectMax;
  final int maxQueueSize;
  final bool debugLogging;

  // -- Public streams -------------------------------------------------------
  final StreamController<WsEvent> _events =
      StreamController<WsEvent>.broadcast();
  final StreamController<WsStatus> _status =
      StreamController<WsStatus>.broadcast();

  /// Inbound events (JSON messages + system events).
  Stream<WsEvent> get events => _events.stream;

  /// Connection status changes (useful for a "reconnecting…" banner).
  Stream<WsStatus> get status => _status.stream;

  // -- Internal state -------------------------------------------------------
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  Timer? _pingTimer;
  Timer? _pongTimer;
  Timer? _reconnectTimer;

  WsStatus _currentStatus = WsStatus.disconnected;
  int _attempt = 0;
  bool _manuallyClosed = false;
  bool _isConnecting = false;
  DateTime? _lastPongAt;

  final List<String> _outbox = <String>[];

  WsStatus get currentStatus => _currentStatus;
  bool get isConnected => _currentStatus == WsStatus.connected;

  // =========================================================================
  // LIFECYCLE
  // =========================================================================

  /// Open the connection. Idempotent — safe to call repeatedly.
  Future<void> connect() async {
    if (_manuallyClosed) _manuallyClosed = false;
    if (_isConnecting || isConnected) return;
    _isConnecting = true;
    _setStatus(_attempt == 0 ? WsStatus.connecting : WsStatus.reconnecting);

    try {
      final uri = Uri.parse(url);
      final channel = IOWebSocketChannel.connect(
        uri,
        headers: headers.map((k, v) => MapEntry(k, v.toString())),
        pingInterval: null, // we manage our own heartbeat
        connectTimeout: const Duration(seconds: 10),
      );
      await channel.ready;
      _channel = channel;
      _attempt = 0;
      _lastPongAt = DateTime.now();

      _log('connected to $url');
      _setStatus(WsStatus.connected);

      _sub = channel.stream.listen(
        _onMessage,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );

      _startHeartbeat();
      _flushOutbox();
    } on SocketException catch (e) {
      _log('socket error: $e');
      _scheduleReconnect();
    } on WebSocketChannelException catch (e) {
      _log('channel error: $e');
      _scheduleReconnect();
    } catch (e) {
      _log('unexpected connect error: $e');
      _scheduleReconnect();
    } finally {
      _isConnecting = false;
    }
  }

  /// Close deliberately — no reconnect will follow.
  Future<void> dispose() async {
    _manuallyClosed = true;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _pongTimer?.cancel();
    await _sub?.cancel();
    _sub = null;
    try {
      await _channel?.sink.close(1000, 'client disposed');
    } catch (_) {}
    _channel = null;
    _setStatus(WsStatus.disconnected);
    await _events.close();
    await _status.close();
  }

  /// Send a JSON-serialisable payload. Queued if not currently connected.
  void send(Map<String, dynamic> payload) {
    final encoded = jsonEncode(payload);
    if (isConnected && _channel != null) {
      try {
        _channel!.sink.add(encoded);
        return;
      } catch (e) {
        _log('send failed, queueing: $e');
      }
    }
    _enqueue(encoded);
  }

  /// Send a raw string (advanced use).
  void sendRaw(String raw) {
    if (isConnected && _channel != null) {
      try {
        _channel!.sink.add(raw);
        return;
      } catch (e) {
        _log('sendRaw failed, queueing: $e');
      }
    }
    _enqueue(raw);
  }

  // =========================================================================
  // INTERNALS
  // =========================================================================

  void _onMessage(dynamic raw) {
    if (raw is! String) return;
    // Filter heartbeat acknowledgements.
    if (raw == 'pong' || raw == '"pong"') {
      _lastPongAt = DateTime.now();
      _pongTimer?.cancel();
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final type = decoded['type']?.toString() ?? 'message';
        _events.add(WsEvent(type: type, payload: decoded, receivedAt: DateTime.now()));
      } else if (decoded is Map) {
        final map = decoded.map((k, v) => MapEntry(k.toString(), v));
        _events.add(WsEvent(
          type: map['type']?.toString() ?? 'message',
          payload: map,
          receivedAt: DateTime.now(),
        ));
      } else {
        _events.add(WsEvent(
          type: 'raw',
          payload: {'data': decoded},
          receivedAt: DateTime.now(),
        ));
      }
    } catch (e) {
      _log('malformed payload: $e');
      _events.add(WsEvent(
        type: 'error',
        payload: {'message': 'Malformed message', 'raw': raw},
        receivedAt: DateTime.now(),
      ));
    }
  }

  void _onError(Object error, [StackTrace? stack]) {
    _log('stream error: $error');
    _events.add(WsEvent(
      type: 'error',
      payload: {'message': error.toString()},
      receivedAt: DateTime.now(),
    ));
    _scheduleReconnect();
  }

  void _onDone() {
    _log('socket closed by peer');
    _scheduleReconnect();
  }

  void _startHeartbeat() {
    _pingTimer?.cancel();
    _pongTimer?.cancel();

    _pingTimer = Timer.periodic(pingInterval, (_) {
      if (!isConnected) return;
      try {
        _channel?.sink.add(jsonEncode({
          'type': 'ping',
          'ts': DateTime.now().millisecondsSinceEpoch,
        }));
      } catch (e) {
        _log('ping failed: $e');
        _scheduleReconnect();
        return;
      }

      // If we don't hear anything back within pongTimeout, assume dead.
      _pongTimer?.cancel();
      _pongTimer = Timer(pongTimeout, () {
        final since = _lastPongAt == null
            ? Duration(days: 1)
            : DateTime.now().difference(_lastPongAt!);
        if (since >= pongTimeout) {
          _log('pong timeout — recycling socket');
          _scheduleReconnect();
        }
      });
    });
  }

  void _scheduleReconnect() {
    if (_manuallyClosed) return;
    _reconnectTimer?.cancel();

    // Tear down current socket first.
    _pingTimer?.cancel();
    _pongTimer?.cancel();
    _sub?.cancel();
    _sub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;

    _setStatus(WsStatus.reconnecting);

    _attempt++;
    final base = reconnectBase.inMilliseconds *
        math.pow(2, math.min(_attempt, 6)).toInt();
    final jitter = math.Random().nextInt(400);
    final wait = Duration(
      milliseconds: math.min(base + jitter, reconnectMax.inMilliseconds),
    );

    _log('reconnecting in ${wait.inMilliseconds}ms (attempt $_attempt)');
    _reconnectTimer = Timer(wait, connect);
  }

  void _enqueue(String encoded) {
    if (_outbox.length >= maxQueueSize) {
      // Drop oldest — prevents unbounded memory growth on long outages.
      _outbox.removeAt(0);
    }
    _outbox.add(encoded);
  }

  void _flushOutbox() {
    if (_outbox.isEmpty) return;
    _log('flushing ${_outbox.length} queued messages');
    final pending = List<String>.from(_outbox);
    _outbox.clear();
    for (final msg in pending) {
      try {
        _channel?.sink.add(msg);
      } catch (e) {
        _log('flush failed: $e');
        _enqueue(msg);
      }
    }
  }

  void _setStatus(WsStatus status) {
    if (_currentStatus == status) return;
    _currentStatus = status;
    if (!_status.isClosed) _status.add(status);
  }

  void _log(String msg) {
    if (debugLogging) {
      // ignore: avoid_print
      print('[WS] $msg');
    }
  }
}

/// =========================================================================
/// Support types
/// =========================================================================

enum WsStatus { disconnected, connecting, connected, reconnecting }

@immutable
class WsEvent {
  const WsEvent({
    required this.type,
    required this.payload,
    required this.receivedAt,
  });

  final String type;
  final Map<String, dynamic> payload;
  final DateTime receivedAt;

  /// Safe typed getter for common fields.
  double? get lat => (payload['lat'] as num?)?.toDouble();
  double? get lng => (payload['lng'] as num?)?.toDouble();
  String? get rideId => payload['ride_id']?.toString();
  String? get driverId => payload['driver_id']?.toString();

  @override
  String toString() => 'WsEvent($type @ $receivedAt)';
}