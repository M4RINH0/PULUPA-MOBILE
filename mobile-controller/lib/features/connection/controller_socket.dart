import 'dart:async';
import 'dart:io';

/// Minimal socket surface used by [ConnectionController], so tests can supply
/// an in-memory fake instead of a real `dart:io` WebSocket.
abstract interface class ControllerSocket {
  /// Incoming messages. Completes when the socket closes; [closeCode] is then
  /// the code sent by the peer, if any.
  Stream<dynamic> get stream;

  /// Sends a text message. Throws [StateError] when the socket is not open.
  void add(String data);

  Future<void> close([int? code, String? reason]);

  int? get closeCode;
}

class IoControllerSocket implements ControllerSocket {
  IoControllerSocket(this._socket);

  final WebSocket _socket;

  static Future<ControllerSocket> connect(
    Uri address, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'DIRECT';
    try {
      final socket = await WebSocket.connect(
        address.toString(),
        customClient: client,
      ).timeout(timeout);
      return IoControllerSocket(socket);
    } finally {
      client.close(force: true);
    }
  }

  @override
  Stream<dynamic> get stream => _socket;

  @override
  void add(String data) {
    if (_socket.readyState != WebSocket.open) {
      throw StateError('WebSocket não está aberto.');
    }
    _socket.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) =>
      _socket.close(code, reason);

  @override
  int? get closeCode => _socket.closeCode;
}
