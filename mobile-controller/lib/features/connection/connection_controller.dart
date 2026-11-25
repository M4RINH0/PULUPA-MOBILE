import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../pairing/pairing_invite.dart';
import '../sensors/sensor_source.dart';
import 'controller_socket.dart';
import 'motion_packet.dart';
import 'motion_transport.dart';
import 'saved_session.dart';
import 'websocket_motion_transport.dart';

export 'controller_socket.dart';
export 'saved_session.dart';

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

typedef ControllerSocketOpener =
    Future<ControllerSocket> Function(Uri address);

/// Close codes defined by the motion protocol.
abstract final class CloseCodes {
  static const normal = 1000;
  static const policy = 1008;
  static const peerTimeout = 4000;
  static const replaced = 4001;
  static const sessionEnded = 4002;
  static const removed = 4003;
}

class ConnectionController extends ChangeNotifier {
  ConnectionController({
    required this.latestFrame,
    required this.isCalibrated,
    required this.onFeedback,
    this.onSessionChanged,
    ControllerSocketOpener? open,
  }) : _open = open ?? _openLanSocket;

  /// While connected the save is refreshed this often, so its age tells how
  /// long ago the link was last alive.
  static const _savePeriod = Duration(seconds: 15);

  /// Resuming players retry for most of the server's 180 s reservation.
  static const _resumePolicy = ReconnectPolicy();

  /// A first pairing gives up sooner; the user is watching the screen.
  static const _pairingPolicy = ReconnectPolicy(
    window: Duration(seconds: 20),
  );
  static const _timeout = Duration(seconds: 4);

  /// Connected this long without a drop, the backoff starts over.
  static const stablePeriod = Duration(seconds: 10);

  /// Missing motion acks for this long means the PC stopped consuming. Kept
  /// below the pong timeout but well above a Wi-Fi hiccup.
  static const _ackTimeoutUs = 4000000;
  static const _pongTimeoutUs = 7000000;

  /// A sensor timestamp that has not changed for this long is stale.
  static const _staleFrameUs = 500000;

  /// `valid: false` packets go out at 5 Hz while there is no usable frame.
  static const _invalidPeriodUs = 200000;

  /// Consecutive 1008 closes, without a stable period between them, before
  /// the controller stops retrying.
  static const _maxPolicyCloses = 2;

  static const nameRejected =
      'O PC recusou o nome do jogador. Use de 1 a 32 caracteres visíveis.';
  static const resumeRejected = 'Reconexão recusada pelo PC; pareie novamente.';
  static const replacedElsewhere =
      'Este controle foi conectado em outra conexão.';
  static const protocolFailure = 'Erro de protocolo com o PC.';
  static const _attemptAlphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
  static final _colorPattern = RegExp(r'^#[0-9A-Fa-f]{6}$');
  static final _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{32,128}$');
  static final _playerKeyPattern = RegExp(r'^[A-Za-z0-9_-]{16,32}$');

  final MotionFrame? Function() latestFrame;
  final bool Function() isCalibrated;
  final VoidCallback onFeedback;

  /// Receives the credentials to persist after each welcome (and
  /// periodically while connected), or null when they must be forgotten.
  final void Function(SavedSession? session)? onSessionChanged;
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

  /// True while the controller sends `valid: false` because no usable sensor
  /// frame exists.
  bool sensorDataMissing = false;

  LanEndpoint? _endpoint;
  String? _name;
  String? _deviceLabel;
  Map<String, String>? _invite;
  String? _resume;
  bool _resuming = false;
  ControllerSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  WebSocketMotionTransport? _transport;
  Timer? _retryTimer;
  Timer? _handshakeTimer;
  Timer? _sendTimer;
  Timer? _pingTimer;
  Timer? _statsTimer;
  Timer? _stableTimer;
  Timer? _deferTimer;
  Timer? _saveTimer;
  int _attempt = 0;
  int? _dropStartedUs;
  int _policyCloses = 0;
  int _generation = 0;
  int _nextSequence = 0;
  // Sensor timestamp of the last real frame turned into a packet.
  int? _lastFrameUs;
  // Last sensor timestamp observed and the clock time when it changed.
  int? _lastSeenFrameUs;
  int? _lastFreshUs;
  // `t_us` of the last packet sent, valid or not, and the shift applied to
  // sensor timestamps so `t_us` keeps increasing (see [_pump]).
  int _lastSentTUs = -1;
  int _timestampShiftUs = 0;
  // Clock time of the last packet sent on the current socket.
  int? _lastSentUs;
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

  static Future<ControllerSocket> _openLanSocket(Uri address) =>
      IoControllerSocket.connect(address, timeout: _timeout);

  /// Idempotency key for one user-initiated pairing. Retries of the same
  /// pairing reuse it, so the server hands back the same slot.
  static String _newAttempt() {
    final random = Random.secure();
    return String.fromCharCodes([
      for (var i = 0; i < 32; i++)
        _attemptAlphabet.codeUnitAt(random.nextInt(_attemptAlphabet.length)),
    ]);
  }

  /// [name] must already be normalized with `normalizePlayerName`.
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

  /// Pairing credentials reused by retries until a welcome arrives.
  @visibleForTesting
  Map<String, String>? get pendingInvite => _invite;

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
    _invite = {...invite, 'attempt': _newAttempt()};
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
      _subscription = socket.stream.listen(
        (message) => _message(generation, message),
        onError: (Object _) =>
            _lost(generation, 'A conexão com o PC foi interrompida.'),
        onDone: () => _closed(generation, socket.closeCode),
        cancelOnError: true,
      );
      // Retrying after a lost welcome is safe: the server keeps accepting the
      // previous resume token until the new socket proves itself, and a
      // repeated pairing `attempt` returns the same slot.
      _resuming = player != null && _resume != null;
      final credentials = _resuming
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
    if (socket == null) return false;
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
        // Released whether `accepted` is true or false: a rejected sample
        // must not block the next one.
        if (_transport?.acknowledge(data['seq'] as int) != true) return;
        final packets = data['packets'];
        final missing = data['missing'];
        if (packets is int && missing is int && packets >= 2 && missing >= 0) {
          loss = missing / (packets + missing);
        }
        _pump(generation);
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
    error = null;
    phase = ConnectionPhase.connected;
    _saveSession();
    _saveTimer = Timer.periodic(_savePeriod, (_) => _saveSession());
    _lastPongUs = _clock.elapsedMicroseconds;
    _lastSentUs = null;
    _transport = WebSocketMotionTransport(_socket!.add);
    // Backoff and the drop window restart only once the link proved stable,
    // so a server that welcomes and then drops cannot cause endless retries.
    _stableTimer = Timer(stablePeriod, () {
      if (generation != _generation) return;
      _attempt = 0;
      _dropStartedUs = null;
      _policyCloses = 0;
    });
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
      (_) => _pump(generation),
    );
  }

  /// Sends the newest sample when the transport is free. Runs on every send
  /// tick and right after each `motion_ack`, so a slow round trip does not
  /// halve the rate. Never sends more often than once per 1/sendHz.
  void _pump(int generation) {
    final transport = _transport;
    final active = player;
    if (generation != _generation ||
        phase != ConnectionPhase.connected ||
        transport == null ||
        active == null) {
      return;
    }
    final calibrated = isCalibrated();
    if (_sentCalibration != calibrated) {
      _sentCalibration = calibrated;
      _send('calibration', {'calibrated': calibrated});
    }
    final now = _clock.elapsedMicroseconds;
    final lastSent = _lastSentUs;
    if (!transport.available) {
      if (lastSent != null && now - lastSent >= _ackTimeoutUs) {
        _lost(generation, 'O PC parou de confirmar o movimento.');
      }
      return;
    }
    final periodUs = (1000000 / _sendHz).round();
    if (lastSent != null && now - lastSent < periodUs) {
      _deferTimer ??= Timer(
        Duration(microseconds: periodUs - (now - lastSent)),
        () {
          _deferTimer = null;
          _pump(generation);
        },
      );
      return;
    }

    final frame = latestFrame();
    if (frame != null && frame.timestampUs != _lastSeenFrameUs) {
      _lastSeenFrameUs = frame.timestampUs;
      _lastFreshUs = now;
    }
    final fresh =
        frame != null &&
        _lastFreshUs != null &&
        now - _lastFreshUs! <= _staleFrameUs;
    MotionPacket? packet;
    if (fresh) {
      // Same sample as last time: wait for a new one.
      if (frame.timestampUs == _lastFrameUs) return;
      _lastFrameUs = frame.timestampUs;
      // `t_us` must grow strictly across every packet, valid or not.
      // Invalid packets use the last sent `t_us` + 1 µs, which barely moves
      // it, so real frames normally keep their own sensor timestamps. If a
      // sensor timestamp still falls behind (a sensor restart or clock
      // reset), this and later frames are shifted forward by the minimum
      // amount instead of being dropped, keeping the spacing between real
      // samples intact.
      var timestamp = frame.timestampUs + _timestampShiftUs;
      if (timestamp <= _lastSentTUs) {
        _timestampShiftUs += _lastSentTUs + 1 - timestamp;
        timestamp = _lastSentTUs + 1;
      }
      try {
        packet = MotionPacket.fromDevice(
          sessionId: active.sessionId,
          playerId: active.id,
          sequence: _nextSequence,
          frame: MotionFrame(
            timestampUs: timestamp,
            orientation: frame.orientation,
            acceleration: frame.acceleration,
            angularVelocity: frame.angularVelocity,
          ),
          calibrated: calibrated,
        );
      } on FormatException {
        packet = null;
      }
    }
    if (packet == null) {
      if (lastSent != null && now - lastSent < _invalidPeriodUs) return;
      try {
        packet = MotionPacket.invalid(
          sessionId: active.sessionId,
          playerId: active.id,
          sequence: _nextSequence,
          timestampUs: _lastSentTUs + 1,
          calibrated: calibrated,
        );
      } on FormatException {
        return;
      }
    }
    try {
      if (!transport.offer(packet)) return;
    } on StateError {
      _lost(generation, 'Não foi possível enviar o movimento.');
      return;
    }
    _lastSentUs = now;
    _lastSentTUs = packet.frame.timestampUs;
    _nextSequence++;
    sentPackets++;
    _sendTimes.addLast(now);
    if (sensorDataMissing == packet.valid) {
      sensorDataMissing = !packet.valid;
      notifyListeners();
    }
  }

  void _closed(int generation, int? closeCode) {
    if (generation != _generation) return;
    switch (closeCode) {
      case CloseCodes.normal:
        // The server closed on purpose; reconnecting would only be refused.
        _finish('O PC encerrou a conexão.');
      case CloseCodes.sessionEnded:
        _finish('A sessão foi encerrada no PC.');
      case CloseCodes.removed:
        _finish('O anfitrião desconectou este controle.');
      case CloseCodes.replaced:
        // Only the current socket gets here; stale generations, such as a
        // socket this controller already replaced, were filtered above.
        _finish(replacedElsewhere);
      case CloseCodes.policy when ++_policyCloses >= _maxPolicyCloses:
        _finish(protocolFailure);
      default:
        _lost(generation, 'A conexão com o PC foi perdida.');
    }
  }

  void _serverError(int generation, Object? code) {
    if (code == 'resume_pending') {
      // Older servers only: wait without spending the backoff budget.
      _lost(
        generation,
        'Aguardando o PC liberar a conexão anterior.',
        countAttempt: false,
      );
      return;
    }
    if (phase == ConnectionPhase.connected &&
        (code == 'invalid_motion' || code == 'invalid_message')) {
      return;
    }
    _finish(switch (code) {
      'invalid_invite' when _resuming => resumeRejected,
      'invalid_invite' =>
        'Convite inválido ou vencido. Verifique o código ou leia o QR novamente.',
      // During the handshake the only free-form field is the name.
      'invalid_name' || 'invalid_message' => nameRejected,
      'session_full' => 'A sessão já tem quatro controles.',
      'session_expired' => 'A sessão expirou. Inicie outra sessão no PC.',
      'retry_later' => 'Muitas tentativas de pareamento. Aguarde um minuto.',
      'rate_limit' =>
        'O PC limitou a transmissão. Reduza a taxa de envio e reconecte.',
      _ => 'O PC recusou o pareamento.',
    });
  }

  void _lost(int generation, String reason, {bool countAttempt = true}) {
    if (_disposed || generation != _generation) return;
    _detach();
    final now = _clock.elapsedMicroseconds;
    final sinceDrop = Duration(microseconds: now - (_dropStartedUs ??= now));
    final policy = player != null ? _resumePolicy : _pairingPolicy;
    final delay = policy.delayFor(countAttempt ? _attempt : 1, sinceDrop);
    if (delay == null) {
      _finish('$reason Limite de tentativas de reconexão atingido.');
      return;
    }
    if (countAttempt) _attempt++;
    phase = ConnectionPhase.retrying;
    final seconds = delay.inMilliseconds < 1000 ? '0,5' : '${delay.inSeconds}';
    error = '$reason Nova tentativa em $seconds s.';
    notifyListeners();
    _retryTimer = Timer(delay, () => unawaited(_connect()));
  }

  void _finish(String detail) {
    onSessionChanged?.call(null);
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
    _stableTimer?.cancel();
    _deferTimer?.cancel();
    _deferTimer = null;
    _saveTimer?.cancel();
    _saveTimer = null;
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
    sensorDataMissing = false;
    _lastSentUs = null;
    _sendTimes.clear();
    _rtts.clear();
  }

  static Future<void> _closeSocket(
    ControllerSocket socket,
    StreamSubscription<dynamic>? subscription,
    bool explicit,
  ) async {
    try {
      if (explicit) {
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

  /// Leaves the game on purpose: tells the PC and forgets the saved session.
  void disconnect() {
    onSessionChanged?.call(null);
    _reset();
  }

  /// Rejoins the slot of a session saved before the app was closed.
  void resumeSaved(SavedSession saved) {
    _reset(notify: false);
    final LanEndpoint endpoint;
    try {
      endpoint = saved.endpoint;
    } on FormatException {
      onSessionChanged?.call(null);
      return;
    }
    _endpoint = endpoint;
    _name = saved.name;
    _deviceLabel = saved.deviceLabel;
    player = ConnectedPlayer(
      saved.playerId,
      saved.name,
      saved.color,
      saved.sessionId,
      saved.playerKey,
    );
    _resume = saved.resume;
    // The retry window counts from the moment the link was last known alive,
    // matching the server's reservation.
    final age = clock.now().difference(saved.savedAt);
    _dropStartedUs =
        _clock.elapsedMicroseconds - (age.isNegative ? 0 : age.inMicroseconds);
    phase = ConnectionPhase.connecting;
    notifyListeners();
    unawaited(_connect());
  }

  /// Saves now instead of waiting for the periodic refresh (for example
  /// right after a calibration).
  void saveNow() {
    if (phase == ConnectionPhase.connected) _saveSession();
  }

  void _saveSession() {
    final current = player;
    final endpoint = _endpoint;
    final resume = _resume;
    final name = _name;
    if (current == null || endpoint == null || resume == null || name == null) {
      return;
    }
    onSessionChanged?.call(
      SavedSession(
        host: endpoint.host,
        port: endpoint.port,
        sessionId: current.sessionId,
        resume: resume,
        playerId: current.id,
        playerKey: current.key,
        name: current.name,
        color: current.color,
        deviceLabel: _deviceLabel ?? '',
        savedAt: clock.now(),
      ),
    );
  }

  void _reset({bool notify = true}) {
    _retryTimer?.cancel();
    _detach(explicit: true);
    player = null;
    _endpoint = null;
    _name = null;
    _deviceLabel = null;
    _invite = null;
    _resume = null;
    _resuming = false;
    _attempt = 0;
    _dropStartedUs = null;
    _policyCloses = 0;
    _nextSequence = 0;
    _lastFrameUs = null;
    _lastSeenFrameUs = null;
    _lastFreshUs = null;
    _lastSentTUs = -1;
    _timestampShiftUs = 0;
    sentPackets = 0;
    error = null;
    phase = ConnectionPhase.idle;
    if (notify) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    // Closing the app is not leaving the game: no `disconnect` message, and
    // the saved session stays so a reopened app can rejoin the slot.
    _detach();
    super.dispose();
  }
}
