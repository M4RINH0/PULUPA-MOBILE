import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulupa_controller/core/motion_math.dart';
import 'package:pulupa_controller/features/connection/motion_packet.dart';
import 'package:pulupa_controller/features/connection/motion_transport.dart';
import 'package:pulupa_controller/features/pairing/pairing_invite.dart';
import 'package:pulupa_controller/features/pairing/player_name.dart';
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

  test('reconnection backs off up to 5 s and stops at the drop window', () {
    const policy = ReconnectPolicy();
    expect(policy.delayFor(-1, Duration.zero), isNull);
    expect(
      [
        for (var i = 0; i < 7; i++)
          policy.delayFor(i, Duration.zero)!.inMilliseconds,
      ],
      [500, 1000, 2000, 4000, 5000, 5000, 5000],
    );
    expect(policy.delayFor(40, Duration.zero), const Duration(seconds: 5));
    expect(
      policy.delayFor(3, const Duration(seconds: 51)),
      const Duration(seconds: 4),
    );
    expect(policy.delayFor(3, const Duration(seconds: 52)), isNull);
    // Sum of the delays until the window closes: the client keeps trying for
    // most of the server's 60 s reservation instead of five attempts.
    var elapsed = Duration.zero;
    var attempts = 0;
    for (
      var delay = policy.delayFor(0, elapsed);
      delay != null;
      delay = policy.delayFor(attempts, elapsed)
    ) {
      elapsed += delay;
      attempts++;
    }
    expect(attempts, greaterThan(10));
    expect(elapsed, lessThanOrEqualTo(const Duration(seconds: 55)));
    expect(elapsed, greaterThan(const Duration(seconds: 50)));
  });

  test('invalid packets carry identity orientation and zero vectors', () {
    final invalid = MotionPacket.invalid(
      sessionId: session,
      playerId: 2,
      sequence: 3,
      timestampUs: 7,
      calibrated: false,
    );
    expect(jsonDecode(invalid.encode()), {
      'v': 1,
      'type': 'motion',
      'session': session,
      'player': 2,
      'seq': 3,
      't_us': 7,
      'q': [0, 0, 0, 1],
      'accel': [0, 0, 0],
      'gyro': [0, 0, 0],
      'calibrated': false,
      'valid': false,
    });
    expect(MotionPacket.decode(invalid.encode()).valid, isFalse);
  });

  test('player names follow the shared rule', () {
    expect(normalizePlayerName('  Ana\u00A0Bia\u3000'), 'Ana Bia');
    expect(normalizePlayerName('Ana\u200DBia'), 'Ana\u200DBia');
    expect(normalizePlayerName('\u{1F469}\u200D\u{1F4BB}'), isNotNull);
    expect(normalizePlayerName('A' * 32), 'A' * 32);
    for (final name in [
      '',
      '\u2003',
      'A' * 33,
      'Ana\nBia',
      'Ana\u0085',
      'Ana\u2028',
      'Ana\u202E',
      'Ana\u2067',
      'Ana\uE000',
      'Ana\u{F0000}',
      'Ana\u{10FFFD}',
      'Ana\uD800',
    ]) {
      expect(normalizePlayerName(name), isNull, reason: name);
    }
  });

  group('shared protocol fixtures', () {
    // Run from mobile-controller/, as `flutter test` does.
    final motionFile = File('../protocol/fixtures/motion.json');
    final namesFile = File('../protocol/fixtures/names.json');

    test('motion encoder and validator agree with the server', () {
      final fixture =
          jsonDecode(motionFile.readAsStringSync()) as Map<String, dynamic>;
      final fixtureSession = fixture['session'] as String;
      final fixturePlayer = fixture['player'] as int;
      final valid = fixture['valid'] as List;
      expect(valid, isNotEmpty);
      for (final raw in valid.cast<Map<String, dynamic>>()) {
        List<double> numbers(String key) => [
          for (final n in raw[key] as List) (n as num).toDouble(),
        ];
        final q = numbers('q');
        final a = numbers('accel');
        final g = numbers('gyro');
        final built = MotionPacket.fromFields(
          sessionId: raw['session'] as String,
          playerId: raw['player'] as int,
          sequence: raw['seq'] as int,
          timestampUs: raw['t_us'] as int,
          orientation: Rotation(q[0], q[1], q[2], q[3]),
          acceleration: Vec3(a[0], a[1], a[2]),
          angularVelocity: Vec3(g[0], g[1], g[2]),
          calibrated: raw['calibrated'] as bool,
          valid: raw['valid'] as bool,
        );
        // Numbers compare by value, so 1 and 1.0 are equal here.
        expect(jsonDecode(built.encode()), raw, reason: '${raw['seq']}');
        final decoded = MotionPacket.decode(jsonEncode(raw));
        expect(decoded.sessionId, fixtureSession);
        expect(decoded.playerId, fixturePlayer);
      }
      final invalid = fixture['invalid'] as List;
      expect(invalid, isNotEmpty);
      for (final entry in invalid.cast<Map<String, dynamic>>()) {
        final reason = entry['reason'] as String;
        final text = jsonEncode(entry['packet']);
        // Session and player mismatches depend on the authenticated
        // connection, which the client checks as context, not syntax.
        bool rejected;
        try {
          final packet = MotionPacket.decode(text);
          rejected =
              packet.sessionId != fixtureSession ||
              packet.playerId != fixturePlayer;
        } on FormatException {
          rejected = true;
        }
        expect(rejected, isTrue, reason: reason);
      }
    });

    test('name rule agrees with the server', () {
      final fixture =
          jsonDecode(namesFile.readAsStringSync()) as Map<String, dynamic>;
      for (final name in (fixture['valid'] as List).cast<String>()) {
        expect(normalizePlayerName(name), name, reason: name);
      }
      for (final pair in (fixture['normalized'] as List).cast<List<dynamic>>()) {
        expect(normalizePlayerName(pair[0] as String), pair[1], reason: '$pair');
      }
      for (final name in (fixture['invalid'] as List).cast<String>()) {
        expect(normalizePlayerName(name), isNull, reason: name);
      }
    });
  });
}

extension on Vec3 {
  List<double> toList() => [x, y, z];
}
