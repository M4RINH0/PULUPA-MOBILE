import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulupa_controller/core/motion_math.dart';
import 'package:pulupa_controller/features/connection/connection_controller.dart';
import 'package:pulupa_controller/features/pairing/pairing_invite.dart';
import 'package:pulupa_controller/features/sensors/sensor_source.dart';

// These tests run inside testWidgets only for its fake clock: timers and
// `package:clock` advance with `tester.pump`, so minutes of backoff take
// milliseconds.

const _session = 'dev_session_1234567890';
const _firstToken = 'resume_token_1234567890_abcdefghij';
const _nextToken = 'resume_token_1234567890_klmnopqrst';
final _endpoint = LanEndpoint.parse('192.168.1.22', '8765');

class FakeSocket implements ControllerSocket {
  FakeSocket(this.server);

  final FakeServer server;
  final _incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  bool closed = false;

  /// Simulates a peer that never finishes the closing handshake.
  bool slowClose = false;

  @override
  int? closeCode;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  void add(String data) {
    if (closed) throw StateError('closed');
    final message = jsonDecode(data) as Map<String, dynamic>;
    sent.add(message);
    server.handle(this, message);
  }

  @override
  Future<void> close([int? code, String? reason]) {
    if (slowClose) return Completer<void>().future;
    return _closeNow();
  }

  Future<void> _closeNow() async {
    if (closed) return;
    closed = true;
    unawaited(_incoming.close());
  }

  void reply(String type, [Map<String, Object?> fields = const {}]) {
    if (!closed) _incoming.add(jsonEncode({'v': 1, 'type': type, ...fields}));
  }

  void serverClose(int code) {
    if (closed) return;
    closeCode = code;
    closed = true;
    unawaited(_incoming.close());
  }

  Iterable<Map<String, dynamic>> ofType(String type) =>
      sent.where((message) => message['type'] == type);

  Map<String, dynamic> get hello => ofType('hello').single;

  void welcome({String resume = _firstToken}) => reply('welcome', {
    'player': 2,
    'name': 'Ana',
    'color': '#FF55A5',
    'session': _session,
    'player_key': 'player_key_abcdef',
    'resume': resume,
  });
}

class FakeServer {
  final sockets = <FakeSocket>[];
  bool refuse = false;
  bool autoPong = true;
  bool autoAck = true;
  bool autoWelcome = false;
  int opens = 0;

  FakeSocket get last => sockets.last;

  Future<ControllerSocket> open(Uri _) async {
    opens++;
    if (refuse) throw StateError('connection refused');
    final socket = FakeSocket(this);
    sockets.add(socket);
    return socket;
  }

  void handle(FakeSocket socket, Map<String, dynamic> message) {
    switch (message['type']) {
      case 'hello' when autoWelcome:
        socket.welcome(
          resume: message.containsKey('resume') ? _nextToken : _firstToken,
        );
      case 'ping' when autoPong:
        socket.reply('pong', {'id': message['id']});
      case 'motion' when autoAck:
        socket.reply('motion_ack', {
          'seq': message['seq'],
          'accepted': true,
          'packets': 1,
          'missing': 0,
        });
    }
  }

  List<Map<String, dynamic>> get motion => [
    for (final socket in sockets) ...socket.ofType('motion'),
  ];
}

class Harness {
  Harness({this.frames = true}) {
    link = ConnectionController(
      latestFrame: () => frames ? frame(sensorUs += 5000) : null,
      isCalibrated: () => true,
      onFeedback: () {},
      onSessionChanged: saves.add,
      open: server.open,
    );
  }

  final server = FakeServer();
  final saves = <SavedSession?>[];
  late final ConnectionController link;
  bool frames;
  int sensorUs = 1000000;

  static MotionFrame frame(int timestamp) => MotionFrame(
    timestampUs: timestamp,
    orientation: Rotation.identity,
    acceleration: const Vec3(0, 0, 9.8),
    angularVelocity: Vec3.zero,
  );

  void pairManually() =>
      link.connectManual(_endpoint, '123456', 'Ana', 'Teste');

  Future<void> connect(WidgetTester tester) async {
    pairManually();
    await tester.pump();
    server.last.welcome();
    await tester.pump();
    expect(link.phase, ConnectionPhase.connected);
  }

  Future<void> dispose(WidgetTester tester) async {
    link.dispose();
    await tester.pump(const Duration(seconds: 2));
  }
}

Future<void> _elapse(WidgetTester tester, Duration total) async {
  const step = Duration(milliseconds: 100);
  for (var t = Duration.zero; t < total; t += step) {
    await tester.pump(step);
  }
}

void main() {
  testWidgets('handshake timeout retries with the same pairing attempt', (
    tester,
  ) async {
    final h = Harness();
    h.pairManually();
    await tester.pump();
    final first = h.server.last.hello;
    expect(first['code'], '123456');
    expect(first['attempt'], matches(r'^[A-Za-z0-9_-]{16,64}$'));
    await tester.pump(const Duration(seconds: 4));
    expect(h.link.phase, ConnectionPhase.retrying);
    expect(h.link.error, contains('O PC não respondeu ao pareamento.'));
    expect(h.server.sockets.first.closed, isTrue);
    await tester.pump(const Duration(milliseconds: 500));
    expect(h.server.sockets, hasLength(2));
    final second = h.server.last.hello;
    expect(second['attempt'], first['attempt']);
    expect(second['code'], '123456');

    // A new user-initiated pairing gets a new attempt.
    h.link.disconnect();
    h.pairManually();
    await tester.pump();
    expect(h.server.last.hello['attempt'], isNot(first['attempt']));
    await h.dispose(tester);
  });

  testWidgets('first pairing gives up after its 20 s window', (tester) async {
    final h = Harness()..server.refuse = true;
    h.pairManually();
    await _elapse(tester, const Duration(seconds: 15));
    expect(h.link.phase, ConnectionPhase.retrying);
    await _elapse(tester, const Duration(seconds: 6));
    expect(h.link.phase, ConnectionPhase.failed);
    expect(h.link.error, contains('Limite de tentativas'));
    await h.dispose(tester);
  });

  testWidgets('resume keeps retrying for the server reservation window', (
    tester,
  ) async {
    final h = Harness();
    await h.connect(tester);
    h.server.refuse = true;
    h.server.last.serverClose(CloseCodes.peerTimeout);
    await tester.pump();
    expect(h.link.phase, ConnectionPhase.retrying);
    expect(h.link.error, contains('Nova tentativa em 0,5 s.'));
    await _elapse(tester, const Duration(seconds: 165));
    expect(h.link.phase, ConnectionPhase.retrying);
    expect(h.server.opens, greaterThan(30));
    await _elapse(tester, const Duration(seconds: 6));
    expect(h.link.phase, ConnectionPhase.failed);
    expect(h.link.error, contains('Limite de tentativas'));
    await h.dispose(tester);
  });

  testWidgets('a retry after a lost welcome resends the same resume token', (
    tester,
  ) async {
    final h = Harness();
    await h.connect(tester);
    h.server.last.serverClose(CloseCodes.peerTimeout);
    await tester.pump(const Duration(milliseconds: 500));
    expect(h.server.last.hello['resume'], _firstToken);
    // The welcome never arrives: handshake timeout, then retry.
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 1));
    expect(h.server.last.hello['resume'], _firstToken);
    expect(h.server.last.hello['session'], _session);
    expect(h.server.last.hello.containsKey('code'), isFalse);
    h.server.last.welcome(resume: _nextToken);
    await tester.pump();
    expect(h.link.phase, ConnectionPhase.connected);
    await h.dispose(tester);
  });

  testWidgets('resume hello carries no pairing attempt or code', (
    tester,
  ) async {
    final h = Harness();
    await h.connect(tester);
    h.server.last.serverClose(CloseCodes.peerTimeout);
    await tester.pump(const Duration(milliseconds: 500));
    expect(h.server.last.hello.keys.toSet(), {
      'v',
      'type',
      'name',
      'device',
      'session',
      'resume',
    });
    await h.dispose(tester);
  });

  for (final (code, message) in [
    (CloseCodes.normal, 'O PC encerrou a conexão.'),
    (CloseCodes.sessionEnded, 'A sessão foi encerrada no PC.'),
    (CloseCodes.removed, 'O anfitrião desconectou este controle.'),
    (CloseCodes.replaced, ConnectionController.replacedElsewhere),
  ]) {
    testWidgets('close code $code ends the connection', (tester) async {
      final h = Harness();
      await h.connect(tester);
      h.server.last.serverClose(code);
      await tester.pump();
      expect(h.link.phase, ConnectionPhase.failed);
      expect(h.link.error, message);
      await tester.pump(const Duration(seconds: 10));
      expect(h.server.sockets, hasLength(1));
      await h.dispose(tester);
    });
  }

  testWidgets('4001 on a socket already abandoned is ignored', (
    tester,
  ) async {
    final h = Harness();
    await h.connect(tester);
    h.server.last.serverClose(CloseCodes.peerTimeout);
    await tester.pump(const Duration(milliseconds: 500));
    final abandoned = h.server.last..slowClose = true;
    // No welcome: the controller gives up on this socket and retries.
    await tester.pump(const Duration(seconds: 4));
    expect(h.link.phase, ConnectionPhase.retrying);
    // The server replaces the abandoned socket while it is still closing.
    abandoned.serverClose(CloseCodes.replaced);
    await tester.pump();
    expect(h.link.phase, ConnectionPhase.retrying);
    await tester.pump(const Duration(seconds: 1));
    h.server.last.welcome(resume: _nextToken);
    await tester.pump();
    expect(h.link.phase, ConnectionPhase.connected);
    await h.dispose(tester);
  });

  testWidgets('repeated 1008 closes end with a protocol error', (tester) async {
    final h = Harness();
    await h.connect(tester);
    h.server.last.serverClose(CloseCodes.policy);
    await tester.pump();
    expect(h.link.phase, ConnectionPhase.retrying);
    await tester.pump(const Duration(milliseconds: 500));
    h.server.last.welcome(resume: _nextToken);
    await tester.pump();
    h.server.last.serverClose(CloseCodes.policy);
    await tester.pump();
    expect(h.link.phase, ConnectionPhase.failed);
    expect(h.link.error, ConnectionController.protocolFailure);
    await h.dispose(tester);
  });

  testWidgets('invalid_name and invalid_message in hello point to the name', (
    tester,
  ) async {
    for (final code in ['invalid_name', 'invalid_message']) {
      final h = Harness();
      h.pairManually();
      await tester.pump();
      h.server.last.reply('error', {'code': code});
      await tester.pump();
      expect(h.link.phase, ConnectionPhase.failed, reason: code);
      expect(h.link.error, ConnectionController.nameRejected, reason: code);
      await h.dispose(tester);
    }
  });

  testWidgets('invalid_invite on resume asks to pair again', (tester) async {
    final h = Harness();
    await h.connect(tester);
    h.server.last.serverClose(CloseCodes.peerTimeout);
    await tester.pump(const Duration(milliseconds: 500));
    h.server.last.reply('error', {'code': 'invalid_invite'});
    await tester.pump();
    expect(h.link.phase, ConnectionPhase.failed);
    expect(h.link.error, ConnectionController.resumeRejected);
    await h.dispose(tester);
  });

  testWidgets('resume_pending waits without spending the backoff', (
    tester,
  ) async {
    final h = Harness();
    await h.connect(tester);
    h.server.last.serverClose(CloseCodes.peerTimeout);
    await tester.pump(const Duration(milliseconds: 500));
    h.server.last.reply('error', {'code': 'resume_pending'});
    await tester.pump();
    expect(h.link.phase, ConnectionPhase.retrying);
    await tester.pump(const Duration(seconds: 1));
    // Next ordinary failure uses the second step (1 s), not a later one.
    h.server.last.serverClose(CloseCodes.peerTimeout);
    await tester.pump();
    expect(h.link.error, contains('Nova tentativa em 1 s.'));
    await h.dispose(tester);
  });

  testWidgets('a rejected motion_ack still releases the in-flight packet', (
    tester,
  ) async {
    final h = Harness()..server.autoAck = false;
    await h.connect(tester);
    await tester.pump(const Duration(milliseconds: 20));
    final socket = h.server.last;
    expect(socket.ofType('motion'), hasLength(1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(socket.ofType('motion'), hasLength(1));
    socket.reply('motion_ack', {
      'seq': socket.ofType('motion').single['seq'],
      'accepted': false,
      'code': 'invalid_motion',
      'packets': 1,
      'missing': 0,
    });
    await tester.pump();
    expect(socket.ofType('motion'), hasLength(2));
    await h.dispose(tester);
  });

  testWidgets('an ack triggers the next send without waiting for a tick', (
    tester,
  ) async {
    final h = Harness()..server.autoAck = false;
    await h.connect(tester);
    h.link.updateSendRate(10); // 100 ms ticks make the timing obvious.
    await tester.pump(const Duration(milliseconds: 100));
    final socket = h.server.last;
    expect(socket.ofType('motion'), hasLength(1));
    // Slow ack, 150 ms after the send: next packet goes out at once, not at
    // the next tick 50 ms later.
    await tester.pump(const Duration(milliseconds: 150));
    socket.reply('motion_ack', {
      'seq': socket.ofType('motion').last['seq'],
      'accepted': true,
    });
    await tester.pump();
    expect(socket.ofType('motion'), hasLength(2));
    // Fast ack, 10 ms after the send: waits for the 100 ms minimum interval.
    await tester.pump(const Duration(milliseconds: 10));
    socket.reply('motion_ack', {
      'seq': socket.ofType('motion').last['seq'],
      'accepted': true,
    });
    await tester.pump();
    expect(socket.ofType('motion'), hasLength(2));
    await tester.pump(const Duration(milliseconds: 89));
    expect(socket.ofType('motion'), hasLength(2));
    await tester.pump(const Duration(milliseconds: 2));
    expect(socket.ofType('motion'), hasLength(3));
    await h.dispose(tester);
  });

  testWidgets('missing acks end the link after the ack timeout', (
    tester,
  ) async {
    final h = Harness()..server.autoAck = false;
    await h.connect(tester);
    await _elapse(tester, const Duration(milliseconds: 3800));
    expect(h.link.phase, ConnectionPhase.connected);
    await _elapse(tester, const Duration(milliseconds: 400));
    expect(h.link.phase, ConnectionPhase.retrying);
    expect(h.link.error, contains('O PC parou de confirmar o movimento.'));
    await h.dispose(tester);
  });

  testWidgets('backoff restarts only after a stable period', (tester) async {
    final h = Harness();
    await h.connect(tester);
    h.server.last.serverClose(CloseCodes.peerTimeout);
    await tester.pump();
    expect(h.link.error, contains('0,5 s'));
    await tester.pump(const Duration(milliseconds: 500));
    h.server.last.welcome(resume: _nextToken);
    await tester.pump(const Duration(seconds: 1));
    // Dropped again soon after the welcome: the backoff keeps growing.
    h.server.last.serverClose(CloseCodes.peerTimeout);
    await tester.pump();
    expect(h.link.error, contains('Nova tentativa em 1 s.'));
    await tester.pump(const Duration(seconds: 1));
    h.server.last.welcome(resume: _nextToken);
    await _elapse(tester, ConnectionController.stablePeriod);
    expect(h.link.phase, ConnectionPhase.connected);
    h.server.last.serverClose(CloseCodes.peerTimeout);
    await tester.pump();
    expect(h.link.error, contains('Nova tentativa em 0,5 s.'));
    await h.dispose(tester);
  });

  testWidgets('sends valid:false at about 5 Hz without sensor frames', (
    tester,
  ) async {
    final h = Harness(frames: false);
    await h.connect(tester);
    await _elapse(tester, const Duration(seconds: 1));
    final invalid = h.server.motion;
    expect(invalid.length, inInclusiveRange(5, 6));
    expect(h.link.sensorDataMissing, isTrue);
    for (final packet in invalid) {
      expect(packet['valid'], isFalse);
      expect(packet['q'], [0, 0, 0, 1]);
      expect(packet['accel'], [0, 0, 0]);
      expect(packet['gyro'], [0, 0, 0]);
    }

    // Frames return, with timestamps below the invalid packets' t_us.
    h.sensorUs = 0;
    h.frames = true;
    await _elapse(tester, const Duration(milliseconds: 300));
    expect(h.link.sensorDataMissing, isFalse);
    final all = h.server.motion;
    expect(all.last['valid'], isTrue);
    for (var i = 1; i < all.length; i++) {
      expect(all[i]['seq'], all[i - 1]['seq'] + 1);
      expect(all[i]['t_us'], greaterThan(all[i - 1]['t_us'] as int));
    }

    // Frames stall at a fixed timestamp: invalid again after 500 ms.
    h.frames = false;
    final stalled = Harness.frame(h.sensorUs);
    final link = ConnectionController(
      latestFrame: () => stalled,
      isCalibrated: () => true,
      onFeedback: () {},
      open: h.server.open,
    );
    link.connectManual(_endpoint, '123456', 'Ana', 'Teste');
    await tester.pump();
    h.server.last.welcome();
    await tester.pump(const Duration(milliseconds: 100));
    expect(link.sensorDataMissing, isFalse);
    await _elapse(tester, const Duration(milliseconds: 800));
    expect(link.sensorDataMissing, isTrue);
    expect(h.server.last.ofType('motion').last['valid'], isFalse);
    link.dispose();
    await h.dispose(tester);
  });

  group('saved session', () {
    testWidgets('welcome saves the credentials and refreshes them while connected', (
      tester,
    ) async {
      final h = Harness();
      await h.connect(tester);
      final saved = h.saves.last!;
      expect(saved.resume, _firstToken);
      expect(saved.sessionId, _session);
      expect(saved.playerId, 2);
      expect(saved.playerKey, 'player_key_abcdef');
      expect(saved.host, '192.168.1.22');
      expect(SavedSession.decode(saved.encode())!.resume, _firstToken);
      final count = h.saves.length;
      await _elapse(tester, const Duration(seconds: 16));
      expect(h.saves.length, greaterThan(count));
      expect(h.saves.last!.savedAt.isAfter(saved.savedAt), isTrue);
      await h.dispose(tester);
    });

    testWidgets('closing the app keeps the slot; leaving on purpose forgets it', (
      tester,
    ) async {
      final h = Harness();
      await h.connect(tester);
      final socket = h.server.last;
      h.link.dispose();
      await tester.pump(const Duration(seconds: 2));
      expect(socket.ofType('disconnect'), isEmpty);
      expect(h.saves.last, isNotNull);

      final other = Harness();
      await other.connect(tester);
      other.link.disconnect();
      await tester.pump();
      expect(other.server.last.ofType('disconnect'), hasLength(1));
      expect(other.saves.last, isNull);
      await other.dispose(tester);
    });

    testWidgets('a reopened app rejoins the saved slot with its resume token', (
      tester,
    ) async {
      final first = Harness();
      await first.connect(tester);
      final saved = first.saves.last!;
      first.link.dispose();
      await tester.pump(const Duration(seconds: 2));

      final reopened = Harness();
      reopened.server.autoWelcome = true;
      reopened.link.resumeSaved(saved);
      expect(reopened.link.player?.id, 2);
      await tester.pump();
      final hello = reopened.server.last.hello;
      expect(hello['resume'], _firstToken);
      expect(hello['session'], _session);
      expect(hello.containsKey('attempt'), isFalse);
      await tester.pump();
      expect(reopened.link.phase, ConnectionPhase.connected);
      expect(reopened.saves.last!.resume, _nextToken);
      await reopened.dispose(tester);
    });

    testWidgets('a refused resume forgets the saved session', (tester) async {
      final first = Harness();
      await first.connect(tester);
      final saved = first.saves.last!;
      first.link.dispose();
      await tester.pump(const Duration(seconds: 2));

      final reopened = Harness();
      reopened.link.resumeSaved(saved);
      await tester.pump();
      reopened.server.last.reply('error', {'code': 'invalid_invite'});
      await tester.pump();
      expect(reopened.link.phase, ConnectionPhase.failed);
      expect(reopened.link.error, ConnectionController.resumeRejected);
      expect(reopened.saves.last, isNull);
      await reopened.dispose(tester);
    });

    test('old or malformed saves are not used', () {
      final now = DateTime(2026, 11, 25, 12);
      SavedSession at(DateTime time) => SavedSession(
        host: '192.168.1.22',
        port: 8765,
        sessionId: _session,
        resume: _firstToken,
        playerId: 1,
        playerKey: 'player_key_abcdef',
        name: 'Ana',
        color: 0xFF345CFF,
        deviceLabel: 'Teste',
        savedAt: time,
      );
      expect(at(now.subtract(const Duration(seconds: 60))).isFresh(now), isTrue);
      expect(at(now.subtract(const Duration(seconds: 175))).isFresh(now), isFalse);
      expect(at(now.add(const Duration(seconds: 5))).isFresh(now), isFalse);
      expect(SavedSession.decode(null), isNull);
      expect(SavedSession.decode('{"host": 1}'), isNull);
      expect(SavedSession.decode('not json'), isNull);
      final public = at(now).encode().replaceFirst('192.168.1.22', '8.8.8.8');
      expect(SavedSession.decode(public), isNull);
    });
  });
}
