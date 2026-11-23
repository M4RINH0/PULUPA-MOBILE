import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../pairing/pairing_invite.dart';
import '../sensors/sensor_source.dart';
import 'motion_packet.dart';
import 'motion_transport.dart';
import 'websocket_motion_transport.dart';

enum ConnectionPhase { idle, connecting, connected, retrying, failed }

class ConnectedPlayer {
  const ConnectedPlayer(
    this.id,
    this.name,
    this.color,
    this.sessionId,
    this.key,
  );

  final int id;
  final String name;
  final int color;
  final String sessionId;
  final String key;
}

typedef ControllerSocketOpener = Future<WebSocket> Function(Uri address);

class ConnectionController extends ChangeNotifier {
  ConnectionController({
    required this.latestFrame,
    required this.isCalibrated,
    required this.onFeedback,
    ControllerSocketOpener? open,
  }) : _open = open ?? _openLanSocket;

  static const _retryPolicy = ReconnectPolicy();
  static const _timeout = Duration(seconds: 4);
  static const _ackTimeoutUs = 1800000;
  static const _pongTimeoutUs = 7000000;
  static final _colorPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{32,128}$');
  static final _playerKeyPattern = RegExp(r'^[A-Za-z0-9_-]{16,32}$');

  final MotionFrame? Function() latestFrame;
  final bool Function() isCalibrated;
  final VoidCallback onFeedback;
  final ControllerSocketOpener _open;
  final _clock = clock.stopwatch()..start();
  final _rtts = Queue<double>();
  final _sendTimes = Queue<int>();

  ConnectionPhase phase = ConnectionPhase.idle;
  ConnectedPlayer? player;
  String? error;
  bool? acknowledgedCalibration;
  double? loss;
  int sentPackets = 0;

  LanEndpoint? _endpoint;
  String? _name;
  String? _deviceLabel;
  Map<String, String>? _invite;
  String? _resume;
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  WebSocketMotionTransport? _transport;
  Timer? _retryTimer;
  Timer? _handshakeTimer;
  Timer? _sendTimer;
  Timer? _pingTimer;
  Timer? _statsTimer;
  int _attempt = 0;
  int _generation = 0;
  int _nextSequence = 0;
  int _lastFrameUs = -1;
  int _lastSentUs = 0;
  int _lastPongUs = 0;
  int? _pingId;
  bool? _sentCalibration;
  bool _disposed = false;
  int _sendHz = 60;

  bool get busy =>
      phase == ConnectionPhase.connecting || phase == ConnectionPhase.retrying;
  double? get rttMean =>
      _rtts.isEmpty ? null : _rtts.reduce((a, b) => a + b) / _rtts.length;
  double? get rttP95 {
    if (_rtts.isEmpty) return null;
    final samples = _rtts.toList()..sort();
    return samples[(samples.length * 0.95).ceil() - 1];
  }

  double? get jitter {
    if (_rtts.length < 2) return null;
    final samples = _rtts.toList();
    var difference = 0.0;
    for (var index = 1; index < samples.length; index++) {
      difference += (samples[index] - samples[index - 1]).abs();
    }
    return difference / (samples.length - 1);
  }

  double get actualHz {
    if (phase != ConnectionPhase.connected || _sendTimes.length < 2) return 0;
    final elapsed = _sendTimes.last - _sendTimes.first;
    return elapsed > 0 ? (_sendTimes.length - 1) * 1000000 / elapsed : 0;
  }

  static Future<WebSocket> _openLanSocket(Uri address) async {
    final client = HttpClient()
      ..connectionTimeout = _timeout
      ..findProxy = (_) => 'DIRECT';
    try {
      return await WebSocket.connect(
        address.toString(),
        customClient: client,
      ).timeout(_timeout);
    } finally {
      client.close(force: true);
    }
  }

  void connectQr(PairingInvite invite, String name, String deviceLabel) {
    _begin(invite.endpoint, name, deviceLabel, {
      'session': invite.sessionId,
      'ticket': invite.ticket,
    });
  }

  void connectManual(
    LanEndpoint endpoint,
    String code,
    String name,
    String deviceLabel,
  ) {
    _begin(endpoint, name, deviceLabel, {'code': code});
  }

  void _begin(
    LanEndpoint endpoint,
    String name,
    String deviceLabel,
    Map<String, String> invite,
  ) {
    _reset(notify: false);
    _endpoint = endpoint;
    _name = name;
    _deviceLabel = deviceLabel;
    _invite = invite;
    phase = ConnectionPhase.connecting;
    notifyListeners();
    unawaited(_connect());
  }

  Future<void> _connect() async {
    final generation = ++_generation;
    final endpoint = _endpoint;
    if (_disposed || endpoint == null) return;
    try {
      final socket = await _open(endpoint.webSocketUri).timeout(
        _timeout,
        onTimeout: () {
          throw TimeoutException('Conexão com o PC expirou');
        },
      );
      if (_disposed || generation != _generation) {
        await socket.close();
        return;
      }
      _socket = socket;
      _subscription = socket.listen(
        (message) => _message(generation, message),
        onError: (Object _) =>
            _lost(generation, 'A conexão com o PC foi interrompida.'),
        onDone: () => _closed(generation, socket.closeCode),
        cancelOnError: true,
      );
      final credentials = player != null && _resume != null
          ? {'session': player!.sessionId, 'resume': _resume!}
          : _invite!;
      final sent = _send('hello', {
        'name': _name,
        'device': _deviceLabel,
        ...credentials,
      });
      if (!sent) {
        _lost(generation, 'A conexão com o PC foi interrompida.');
        return;
      }
      _handshakeTimer = Timer(
        _timeout,
        () => _lost(generation, 'O PC não respondeu ao pareamento.'),
      );
    } on Object {
      _lost(generation, 'Não foi possível acessar o PC.');
    }
  }

  bool _send(String kind, [Map<String, Object?> fields = const {}]) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) return false;
    try {
      socket.add(
        jsonEncode({'v': motionProtocolVersion, 'type': kind, ...fields}),
      );
      return true;
    } on StateError {
      return false;
    }
  }

  void _message(int generation, Object? raw) {
    if (generation != _generation ||
        raw is! String ||
        raw.length > MotionPacket.maxBytes ||
        utf8.encode(raw).length > MotionPacket.maxBytes) {
      return;
    }
    Object? data;
    try {
      data = jsonDecode(raw);
    } on FormatException {
      return;
    }
    if (data is! Map<String, dynamic> ||
        data['v'] is! int ||
        data['v'] != motionProtocolVersion) {
      return;
    }
    final kind = data['type'];
    if (kind == 'error') {
      _serverError(generation, data['code']);
      return;
    }
    if (kind == 'welcome' && phase != ConnectionPhase.connected) {
      _welcome(generation, data);
      return;
    }
    if (phase != ConnectionPhase.connected) return;
    switch (kind) {
      case 'ping' when data['id'] is int:
        _send('pong', {'id': data['id']});
      case 'pong' when data['id'] == _pingId && _pingId != null:
        _lastPongUs = _clock.elapsedMicroseconds;
        _rtts.addLast((_lastPongUs - _pingId!) / 1000);
        if (_rtts.length > 40) _rtts.removeFirst();
        _pingId = null;
      case 'motion_ack' when data['seq'] is int:
        if (_transport?.acknowledge(data['seq'] as int) != true) return;
        final packets = data['packets'];
        final missing = data['missing'];
        if (packets is int && missing is int && packets >= 2 && missing >= 0) {
          loss = missing / (packets + missing);
        }
      case 'calibration_ack' when data['calibrated'] is bool:
        acknowledgedCalibration = data['calibrated'] as bool;
        notifyListeners();
      case 'haptic' when data['event'] == 'confirm':
        onFeedback();
    }
  }

  void _welcome(int generation, Map<String, dynamic> data) {
    final id = data['player'];
    final name = data['name'];
    final color = data['color'];
    final session = data['session'];
    final key = data['player_key'];
    final resume = data['resume'];
    final expectedSession = player?.sessionId ?? _invite?['session'];
    if (id is! int ||
        id < 1 ||
        id > 4 ||
        (player != null && id != player!.id) ||
        name is! String ||
        name.trim().isEmpty ||
        name.runes.length > 32 ||
        color is! String ||
        !_colorPattern.hasMatch(color) ||
        session is! String ||
        !sessionIdPattern.hasMatch(session) ||
        (expectedSession != null && expectedSession != session) ||
        key is! String ||
        !_playerKeyPattern.hasMatch(key) ||
        (player != null && player!.key != key) ||
        resume is! String ||
        !_tokenPattern.hasMatch(resume)) {
      _finish('O PC retornou um pareamento inválido.');
      return;
    }
    _handshakeTimer?.cancel();
    player = ConnectedPlayer(
      id,
      name,
      0xFF000000 | int.parse(color.substring(1), radix: 16),
      session,
      key,
    );
    _resume = resume;
    _invite = null;
    _attempt = 0;
    error = null;
    phase = ConnectionPhase.connected;
    _lastPongUs = _clock.elapsedMicroseconds;
    _transport = WebSocketMotionTransport(_socket!.add);
    _startSending(generation);
    _ping(generation);
    _pingTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _ping(generation),
    );
    _statsTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final oldest = _clock.elapsedMicroseconds - 1000000;
      while (_sendTimes.isNotEmpty && _sendTimes.first < oldest) {
        _sendTimes.removeFirst();
      }
      notifyListeners();
    });
    onFeedback();
    notifyListeners();
  }

  void _ping(int generation) {
    final now = _clock.elapsedMicroseconds;
    if (now - _lastPongUs >= _pongTimeoutUs) {
      _lost(generation, 'O PC parou de responder.');
      return;
    }
    if (_pingId == null) {
      _pingId = now;
      _send('ping', {'id': now});
    }
  }

  void updateSendRate(int hz) {
    if (_sendHz == hz || hz < 1 || hz > 100) return;
    _sendHz = hz;
    if (phase == ConnectionPhase.connected) _startSending(_generation);
  }

  void _startSending(int generation) {
    _sendTimer?.cancel();
    _sendTimer = Timer.periodic(
      Duration(microseconds: (1000000 / _sendHz).round()),
      (_) => _offerFrame(generation),
    );
  }

  void _offerFrame(int generation) {
    final transport = _transport;
    final active = player;
    if (transport == null || active == null) return;
    final calibrated = isCalibrated();
    if (_sentCalibration != calibrated) {
      _sentCalibration = calibrated;
      _send('calibration', {'calibrated': calibrated});
    }
    final now = _clock.elapsedMicroseconds;
    if (!transport.available) {
      if (now - _lastSentUs >= _ackTimeoutUs) {
        _lost(generation, 'O PC parou de confirmar o movimento.');
      }
      return;
    }
    final frame = latestFrame();
    if (frame == null || frame.timestampUs <= _lastFrameUs) return;
    _lastFrameUs = frame.timestampUs;
    try {
      final packet = MotionPacket.fromDevice(
        sessionId: active.sessionId,
        playerId: active.id,
        sequence: _nextSequence,
        frame: frame,
        calibrated: calibrated,
      );
      transport.offer(packet);
      _lastSentUs = now;
      _nextSequence++;
      sentPackets++;
      _sendTimes.addLast(now);
    } on FormatException {
      return;
    } on StateError {
      _lost(generation, 'Não foi possível enviar o movimento.');
    }
  }

  void _closed(int generation, int? closeCode) {
    if (generation != _generation) return;
    if (closeCode == 4002 || closeCode == 4003) {
      _finish(
        closeCode == 4003
            ? 'O anfitrião desconectou este controle.'
            : 'A sessão foi encerrada no PC.',
      );
    } else {
      _lost(generation, 'A conexão com o PC foi perdida.');
    }
  }

  void _serverError(int generation, Object? code) {
    if (code == 'resume_pending') {
      _lost(generation, 'Aguardando o PC liberar a conexão anterior.');
      return;
    }
    if (phase == ConnectionPhase.connected &&
        (code == 'invalid_motion' || code == 'invalid_message')) {
      return;
    }
    _finish(switch (code) {
      'invalid_invite' => 'Convite inválido ou vencido. Verifique o código ou leia o QR novamente.',
      'session_full' => 'A sessão já tem quatro controles.',
      'session_expired' => 'A sessão expirou. Inicie outra sessão no PC.',
      'retry_later' => 'Muitas tentativas de pareamento. Aguarde um minuto.',
      'rate_limit' =>
        'O PC limitou a transmissão. Reduza a taxa de envio e reconecte.',
      _ => 'O PC recusou o pareamento.',
    });
  }

  void _lost(int generation, String reason) {
    if (_disposed || generation != _generation) return;
    _detach();
    final delay = _retryPolicy.delayFor(_attempt++);
    if (delay == null) {
      _finish('$reason Limite de tentativas de reconexão atingido.');
      return;
    }
    phase = ConnectionPhase.retrying;
    final seconds = delay.inMilliseconds < 1000 ? '0,5' : '${delay.inSeconds}';
    error = '$reason Nova tentativa em $seconds s.';
    notifyListeners();
    _retryTimer = Timer(delay, () => unawaited(_connect()));
  }

  void _finish(String detail) {
    _detach();
    _retryTimer?.cancel();
    _invite = null;
    _resume = null;
    error = detail;
    phase = ConnectionPhase.failed;
    notifyListeners();
  }

  void _detach({bool explicit = false}) {
    _generation++;
    _handshakeTimer?.cancel();
    _sendTimer?.cancel();
    _pingTimer?.cancel();
    _statsTimer?.cancel();
    unawaited(_transport?.close());
    _transport = null;
    final socket = _socket;
    _socket = null;
    final subscription = _subscription;
    _subscription = null;
    if (socket != null) {
      unawaited(_closeSocket(socket, subscription, explicit));
    }
    _pingId = null;
    _sentCalibration = null;
    acknowledgedCalibration = null;
    loss = null;
    _sendTimes.clear();
    _rtts.clear();
  }

  static Future<void> _closeSocket(
    WebSocket socket,
    StreamSubscription<dynamic>? subscription,
    bool explicit,
  ) async {
    try {
      if (explicit && socket.readyState == WebSocket.open) {
        socket.add(
          jsonEncode({'v': motionProtocolVersion, 'type': 'disconnect'}),
        );
      }
      await socket.close().timeout(const Duration(seconds: 1));
    } on Object {
      // The transport may already have stopped responding.
    } finally {
      await subscription?.cancel();
    }
  }

  void disconnect() => _reset();

  void _reset({bool notify = true}) {
    _retryTimer?.cancel();
    _detach(explicit: true);
    player = null;
    _endpoint = null;
    _name = null;
    _deviceLabel = null;
    _invite = null;
    _resume = null;
    _attempt = 0;
    _nextSequence = 0;
    _lastFrameUs = -1;
    sentPackets = 0;
    error = null;
    phase = ConnectionPhase.idle;
    if (notify) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reset(notify: false);
    super.dispose();
  }
}
