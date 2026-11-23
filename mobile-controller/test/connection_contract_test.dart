import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulupa_controller/core/motion_math.dart';
import 'package:pulupa_controller/features/connection/motion_packet.dart';
import 'package:pulupa_controller/features/connection/motion_transport.dart';
import 'package:pulupa_controller/features/pairing/pairing_invite.dart';
import 'package:pulupa_controller/features/sensors/sensor_source.dart';

const session = 'dev_session_1234567890';
const ticket = 'temporary_ticket_1234567890_test';
const qr =
    'pulupa://pair?v=1&host=192.168.1.20&port=8765&session=$session&ticket=$ticket';
const frame = MotionFrame(
  timestampUs: 2500000,
  orientation: Rotation.identity,
  acceleration: Vec3(1, 2, 3),
  angularVelocity: Vec3(4, 5, 6),
);

MotionPacket packet(int player) => MotionPacket.fromDevice(
  sessionId: session,
  playerId: player,
  sequence: 14,
  frame: frame,
  calibrated: true,
);

void main() {
  test('validates a local QR and builds a socket URI without credentials', () {
    final invite = PairingInvite.fromQr(qr);
    expect(invite.sessionId, session);
    expect(invite.ticket, ticket);
    expect(
      invite.endpoint.webSocketUri.toString(),
      'ws://192.168.1.20:8765/ws/controller',
    );
  });

  test('declines public hosts, duplicate fields, incompatible versions and malformed values', () {
    for (final text in [
      qr.replaceFirst('192.168.1.20', '8.8.8.8'),
      qr.replaceFirst('192.168.1.20', '192.168.1.256'),
      qr.replaceFirst('192.168.1.20', '192.168.1.01'),
      qr.replaceFirst('8765', '65536'),
      qr.replaceFirst('v=1', 'v=2'),
      '$qr&port=8766',
      '$qr#another-page',
      qr.replaceFirst('ticket=$ticket', 'ticket=a'),
      qr.replaceFirst('pair?', 'pair/other?'),
    ]) {
      expect(
        () => PairingInvite.fromQr(text),
        throwsFormatException,
        reason: text,
      );
    }
  });

  test(
    'packet round trip keeps separate player IDs and converts vector axes',
    () {
      final players = [
        for (var player = 1; player <= 4; player++)
          MotionPacket.decode(packet(player).encode()),
      ];
      expect(players.map((player) => player.playerId), [1, 2, 3, 4]);
      final last = players.last;
      expect(last.sessionId, session);
      expect(last.sequence, 14);
      expect(last.frame.timestampUs, frame.timestampUs);
      expect(last.frame.acceleration.toList(), [1, 3, -2]);
      expect(last.frame.angularVelocity.toList(), [4, 6, -5]);
      expect(
        last.frame.orientation.angleTo(Rotation.identity),
        closeTo(0, 1e-7),
      );
      expect(last.calibrated && last.valid, isTrue);
    },
  );

  test('rejects oversized, malformed and out-of-range motion packets', () {
    final original = jsonDecode(packet(1).encode()) as Map<String, dynamic>;
    for (final invalid in [
      {'v': 1.0},
      {'type': 'other'},
      {'player': 5},
      {'player': 1.0},
      {'seq': -1},
      {'t_us': 9007199254740992},
      {
        'q': [0, 0, 0, 0],
      },
      {
        'accel': [0, 0],
      },
      {
        'gyro': [0, 0, 101],
      },
      {'valid': 1},
    ]) {
      expect(
        () => MotionPacket.decode(jsonEncode({...original, ...invalid})),
        throwsFormatException,
      );
    }
    expect(() => MotionPacket.decode(' ' * 1025), throwsFormatException);
    expect(
      () => MotionPacket.decode(
        packet(1).encode().replaceFirst('1.0,3.0,-2.0', '1e999,3.0,-2.0'),
      ),
      throwsFormatException,
    );
    expect(() => packet(0), throwsFormatException);
  });

  test('reconnection policy ends after five progressive delays', () {
    const policy = ReconnectPolicy();
    expect(policy.delayFor(-1), isNull);
    expect(
      [for (var i = 0; i < 5; i++) policy.delayFor(i)!.inMilliseconds],
      [500, 1000, 2000, 4000, 8000],
    );
    expect(policy.delayFor(5), isNull);
  });
}

extension on Vec3 {
  List<double> toList() => [x, y, z];
}
