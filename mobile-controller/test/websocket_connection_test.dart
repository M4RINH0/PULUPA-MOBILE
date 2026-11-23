import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulupa_controller/core/motion_math.dart';
import 'package:pulupa_controller/features/connection/connection_controller.dart';
import 'package:pulupa_controller/features/connection/motion_packet.dart';
import 'package:pulupa_controller/features/connection/websocket_motion_transport.dart';
import 'package:pulupa_controller/features/pairing/pairing_invite.dart';
import 'package:pulupa_controller/features/sensors/motion_processor.dart';
import 'package:pulupa_controller/features/sensors/sensor_source.dart';
import 'package:pulupa_controller/features/sensors/simulated_sensors.dart';

const _session = 'dev_session_1234567890';
const _initialToken = 'temporary_ticket_1234567890_test';
const _newToken = 'temporary_ticket_1234567890_next';

MotionFrame _frame(int timestamp) => MotionFrame(
  timestampUs: timestamp,
  orientation: Rotation.identity,
  acceleration: const Vec3(0, 0, 9.8),
  angularVelocity: Vec3.zero,
);

void _reply(
  WebSocket socket,
  String type, [
  Map<String, Object> data = const {},
]) {
  if (socket.readyState != WebSocket.open) return;
  try {
    socket.add(jsonEncode({'v': motionProtocolVersion, 'type': type, ...data}));
  } on StateError {
    // The fixture may have closed the socket to exercise reconnection.
  }
}

void main() {
  test(
    'transport keeps only the freshest sample while waiting for an ack',
    () async {
      final writes = <MotionPacket>[];
      final transport = WebSocketMotionTransport(
        (text) => writes.add(MotionPacket.decode(text)),
      );
      for (var sequence = 0; sequence < 3; sequence++) {
        transport.offer(
          MotionPacket.fromDevice(
            sessionId: _session,
            playerId: 2,
            sequence: sequence,
            frame: _frame(sequence),
            calibrated: true,
          ),
        );
      }
      expect(writes.map((packet) => packet.sequence), [0]);
      expect(transport.acknowledge(1), isFalse);
      expect(transport.acknowledge(0), isTrue);
      expect(writes.map((packet) => packet.sequence), [0, 2]);
      await transport.close();
      expect(transport.available, isFalse);
    },
  );

  test('real loopback sockets pair, stream, resume the same player and close explicitly', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <WebSocket>[];
    final welcomeMessages = <Map<String, dynamic>>[];
    final motionPackets = <MotionPacket>[];
    final resumed = Completer<void>();
    final disconnected = Completer<void>();
    final haptics = <int>[];
    final states = <ConnectionPhase>[];
    final processor = MotionProcessor(SimulatedSensors.hardware)
      ..calibration.start();
    void sample(int timestamp, {required bool moving}) {
      for (final reading in SimulatedSensors.sampleAt(
        timestamp,
        moving: moving,
      )) {
        processor.ingest(reading, timestamp);
      }
    }

    for (var timestamp = 0; timestamp <= 2000000; timestamp += 10000) {
      sample(timestamp, moving: false);
    }
    expect(processor.calibration.reference, isNotNull);
    int timestamp = 2000000;
    final link = ConnectionController(
      latestFrame: () {
        sample(timestamp += 10000, moving: true);
        return processor.frameAt(timestamp);
      },
      isCalibrated: () => processor.calibration.reference != null,
      onFeedback: () => haptics.add(1),
      open: (_) =>
          WebSocket.connect('ws://127.0.0.1:${server.port}/ws/controller'),
    );
    link.addListener(() => states.add(link.phase));
    addTearDown(() async {
      link.dispose();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });

    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      final index = sockets.length;
      socket.listen((raw) {
        final data = jsonDecode(raw as String) as Map<String, dynamic>;
        switch (data['type']) {
          case 'hello':
            welcomeMessages.add(data);
            _reply(socket, 'welcome', {
              'name': 'Jogador teste',
              'player': 3,
              'color': '#FFD928',
              'session': _session,
              'player_key': 'uid_abcd01234567',
              'resume': index == 1 ? _initialToken : _newToken,
            });
          case 'ping':
            _reply(socket, 'pong', {'id': data['id'] as int});
          case 'calibration':
            _reply(socket, 'calibration_ack', {
              'calibrated': data['calibrated'] as bool,
            });
          case 'motion':
            final packet = MotionPacket.decode(raw);
            motionPackets.add(packet);
            _reply(socket, 'motion_ack', {
              'seq': packet.sequence,
              'packets': motionPackets.length,
              'missing': 0,
            });
            if (motionPackets.length == 2) {
              unawaited(socket.close(4000));
            }
            if (index == 2 && !resumed.isCompleted) {
              _reply(socket, 'haptic', {'event': 'confirm'});
              resumed.complete();
            }
          case 'disconnect':
            if (!disconnected.isCompleted) disconnected.complete();
        }
      });
    });

    link.connectManual(
      LanEndpoint.parse('192.168.1.22', '8765'),
      '123456',
      'Jogador teste',
      'Teste',
    );
    await resumed.future.timeout(const Duration(seconds: 6));
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(welcomeMessages.first['code'], '123456');
    expect(welcomeMessages.last['resume'], _initialToken);
    expect(welcomeMessages.last['session'], _session);
    expect(welcomeMessages.last.containsKey('code'), isFalse);
    expect(
      states,
      containsAllInOrder([
        ConnectionPhase.connected,
        ConnectionPhase.retrying,
        ConnectionPhase.connected,
      ]),
    );
    expect(link.player?.id, 3);
    expect(link.acknowledgedCalibration, isTrue);
    expect(
      motionPackets.every(
        (packet) => packet.playerId == 3 && packet.calibrated,
      ),
      isTrue,
    );
    expect(
      motionPackets.first.frame.orientation.angleTo(Rotation.identity),
      greaterThan(0.2),
    );
    expect(
      motionPackets.map((packet) => packet.sequence),
      orderedEquals(List.generate(motionPackets.length, (i) => i)),
    );
    expect(link.loss, 0);
    expect(haptics, hasLength(3));

    link.disconnect();
    await disconnected.future.timeout(const Duration(seconds: 3));
    expect(link.phase, ConnectionPhase.idle);
    expect(link.player, isNull);
  });
}
