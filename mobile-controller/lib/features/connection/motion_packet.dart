import 'dart:convert';

import '../../core/motion_math.dart';
import '../pairing/pairing_invite.dart';
import '../sensors/sensor_source.dart';

class MotionPacket {
  const MotionPacket._({
    required this.sessionId,
    required this.playerId,
    required this.sequence,
    required this.frame,
    required this.calibrated,
    required this.valid,
  });

  static const maxBytes = 1024;
  static const _maxJsonInteger = 9007199254740991;
  static const _keys = {
    'v',
    'type',
    'session',
    'player',
    'seq',
    't_us',
    'q',
    'accel',
    'gyro',
    'calibrated',
    'valid',
  };

  final String sessionId;
  final int playerId;
  final int sequence;
  final MotionFrame frame;
  final bool calibrated;
  final bool valid;

  factory MotionPacket.fromDevice({
    required String sessionId,
    required int playerId,
    required int sequence,
    required MotionFrame frame,
    required bool calibrated,
  }) {
    _validateHeader(sessionId, playerId, sequence, frame.timestampUs);
    _validateReadings(
      frame.orientation,
      frame.acceleration,
      frame.angularVelocity,
    );
    return MotionPacket._(
      sessionId: sessionId,
      playerId: playerId,
      sequence: sequence,
      frame: MotionFrame(
        timestampUs: frame.timestampUs,
        orientation: rotationInGameAxes(frame.orientation),
        acceleration: vectorInGameAxes(frame.acceleration),
        angularVelocity: vectorInGameAxes(frame.angularVelocity),
      ),
      calibrated: calibrated,
      valid: true,
    );
  }

  /// Placeholder sent while no usable sensor frame exists. The protocol asks
  /// for identity orientation (`q` is `[x, y, z, w]`) and zero vectors so
  /// consumers can ignore it safely.
  factory MotionPacket.invalid({
    required String sessionId,
    required int playerId,
    required int sequence,
    required int timestampUs,
    required bool calibrated,
  }) {
    _validateHeader(sessionId, playerId, sequence, timestampUs);
    return MotionPacket._(
      sessionId: sessionId,
      playerId: playerId,
      sequence: sequence,
      frame: MotionFrame(
        timestampUs: timestampUs,
        orientation: Rotation.identity,
        acceleration: Vec3.zero,
        angularVelocity: Vec3.zero,
      ),
      calibrated: calibrated,
      valid: false,
    );
  }

  /// Builds a packet from values already in game axes, applying the same
  /// checks as [MotionPacket.decode]. The orientation is kept as given.
  factory MotionPacket.fromFields({
    required String sessionId,
    required int playerId,
    required int sequence,
    required int timestampUs,
    required Rotation orientation,
    required Vec3 acceleration,
    required Vec3 angularVelocity,
    required bool calibrated,
    required bool valid,
  }) {
    _validateHeader(sessionId, playerId, sequence, timestampUs);
    _validateReadings(orientation, acceleration, angularVelocity);
    return MotionPacket._(
      sessionId: sessionId,
      playerId: playerId,
      sequence: sequence,
      frame: MotionFrame(
        timestampUs: timestampUs,
        orientation: orientation,
        acceleration: acceleration,
        angularVelocity: angularVelocity,
      ),
      calibrated: calibrated,
      valid: valid,
    );
  }

  static void _validateHeader(
    String sessionId,
    int playerId,
    int sequence,
    int timestampUs,
  ) {
    if (!sessionIdPattern.hasMatch(sessionId) ||
        playerId < 1 ||
        playerId > 4 ||
        sequence < 0 ||
        sequence > _maxJsonInteger ||
        timestampUs < 0 ||
        timestampUs > _maxJsonInteger) {
      throw const FormatException('Identificação da amostra inválida.');
    }
  }

  static void _validateReadings(Rotation q, Vec3 acceleration, Vec3 gyro) {
    if (!q.isUsable ||
        (q.dot(q) - 1).abs() > 0.02 ||
        !acceleration.isFinite ||
        !gyro.isFinite ||
        acceleration.length > 500 ||
        gyro.length > 100) {
      throw const FormatException('Leituras IMU fora dos limites.');
    }
  }

  String encode() {
    final q = frame.orientation;
    final a = frame.acceleration;
    final g = frame.angularVelocity;
    return jsonEncode({
      'v': motionProtocolVersion,
      'type': 'motion',
      'session': sessionId,
      'player': playerId,
      'seq': sequence,
      't_us': frame.timestampUs,
      'q': [q.x, q.y, q.z, q.w],
      'accel': [a.x, a.y, a.z],
      'gyro': [g.x, g.y, g.z],
      'calibrated': calibrated,
      'valid': valid,
    });
  }

  factory MotionPacket.decode(String value) {
    if (value.length > maxBytes || utf8.encode(value).length > maxBytes) {
      throw const FormatException('Pacote de movimento muito grande.');
    }
    final json = jsonDecode(value);
    if (json is! Map<String, dynamic> ||
        json.length != _keys.length ||
        !json.keys.every(_keys.contains) ||
        json['v'] is! int ||
        json['v'] != motionProtocolVersion ||
        json['type'] != 'motion' ||
        json['session'] is! String ||
        json['player'] is! int ||
        json['seq'] is! int ||
        json['t_us'] is! int ||
        json['calibrated'] is! bool ||
        json['valid'] is! bool) {
      throw const FormatException('Formato do pacote de movimento inválido.');
    }
    final sessionId = json['session'] as String;
    final playerId = json['player'] as int;
    final sequence = json['seq'] as int;
    final timestamp = json['t_us'] as int;
    _validateHeader(sessionId, playerId, sequence, timestamp);
    final q = _numbers(json['q'], 4);
    final a = _numbers(json['accel'], 3);
    final g = _numbers(json['gyro'], 3);
    final rotation = Rotation(q[0], q[1], q[2], q[3]);
    final acceleration = Vec3(a[0], a[1], a[2]);
    final gyro = Vec3(g[0], g[1], g[2]);
    _validateReadings(rotation, acceleration, gyro);

    return MotionPacket._(
      sessionId: sessionId,
      playerId: playerId,
      sequence: sequence,
      frame: MotionFrame(
        timestampUs: timestamp,
        orientation: rotation.normalized(),
        acceleration: acceleration,
        angularVelocity: gyro,
      ),
      calibrated: json['calibrated'] as bool,
      valid: json['valid'] as bool,
    );
  }

  static List<double> _numbers(Object? value, int length) {
    if (value is! List ||
        value.length != length ||
        !value.every((n) => n is num && n.isFinite)) {
      throw const FormatException('Vetor inválido no pacote de movimento.');
    }
    return value.map((n) => (n as num).toDouble()).toList(growable: false);
  }
}
