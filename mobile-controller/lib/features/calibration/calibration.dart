import 'dart:math' as math;

import '../../core/motion_math.dart';
import '../sensors/gravity_fusion.dart';
import '../sensors/sensor_source.dart';

enum CalibrationPhase { idle, collecting, accepted, rejected }

/// Neutral-pose measurement tuned for a phone held in the hands.
///
/// Gyro and accelerometer are low-passed (~150 ms) before the limits are
/// checked, so hand tremor and isolated spikes are ignored. A movement that
/// still exceeds the limits restarts the window instead of failing; the
/// attempt only fails after [attemptTimeoutUs] without a steady window.
class Calibration {
  static const windowUs = 1500000;
  static const maxGapUs = 200000;
  static const minimumFrames = 23;
  static const smoothingUs = 150000;
  static const attemptTimeoutUs = 10000000;
  // About 30°/s of smoothed rotation: tremor passes, a deliberate turn does not.
  static const maxAngularVelocity = 0.5;
  static const maxGravityDeviation = 1.5;
  static const maxAccelerationChange = 1.5;
  static const maxOrientationDeviation = 10 * math.pi / 180;
  static const holdStillFeedback = 'Segure firme: recomeçando a medição.';

  Rotation? reference;

  /// Orientation source active when [reference] was accepted. A reference is
  /// only meaningful for the source whose world frame produced it.
  OrientationSource? referenceSource;
  CalibrationPhase phase = CalibrationPhase.idle;
  double progress = 0;
  String? feedback;
  Rotation? _anchor;
  Vec3? _anchorAcceleration;
  Rotation? _average;
  int? _startUs;
  int? _previousUs;
  int? _attemptStartUs;
  int _count = 0;
  double? _gyro;
  int? _gyroUs;
  Vec3? _acceleration;
  int? _accelerationUs;

  void start() {
    phase = CalibrationPhase.collecting;
    feedback = null;
    _attemptStartUs = null;
    _gyro = null;
    _gyroUs = null;
    _acceleration = null;
    _accelerationUs = null;
    _previousUs = null;
    _resetWindow();
  }

  /// Drops the reference. [reason] is kept as [feedback] so the UI can say
  /// why the neutral pose was lost.
  void clear({String? reason}) {
    reference = null;
    referenceSource = null;
    phase = CalibrationPhase.idle;
    progress = 0;
    feedback = reason;
  }

  void interrupt([
    String reason = 'O sinal dos sensores foi interrompido. Tente novamente.',
  ]) {
    if (phase == CalibrationPhase.collecting) _reject(reason);
  }

  /// Instantaneous check used by the UI indicator ("parado"/"em movimento").
  static bool isStationary(Vec3 acceleration, Vec3 gyro) =>
      (acceleration.length - standardGravity).abs() <= maxGravityDeviation &&
      gyro.length <= maxAngularVelocity;

  static double _alpha(int? lastUs, int nowUs) {
    if (lastUs == null) return 1;
    final elapsed = nowUs - lastUs;
    if (elapsed <= 0) return 0;
    return 1 - math.exp(-elapsed / smoothingUs);
  }

  void _smoothGyro(Vec3 value, int timestampUs) {
    if (_gyroUs != null && timestampUs <= _gyroUs!) return;
    final alpha = _alpha(_gyroUs, timestampUs);
    final last = _gyro;
    _gyro = last == null ? value.length : last + (value.length - last) * alpha;
    _gyroUs = timestampUs;
  }

  void _smoothAcceleration(Vec3 value, int timestampUs) {
    if (_accelerationUs != null && timestampUs <= _accelerationUs!) return;
    final alpha = _alpha(_accelerationUs, timestampUs);
    final last = _acceleration;
    _acceleration = last == null ? value : last + (value - last) * alpha;
    _accelerationUs = timestampUs;
  }

  String? _movement() {
    final gyro = _gyro;
    final acceleration = _acceleration;
    if (gyro != null && gyro > maxAngularVelocity) {
      return 'Movimento detectado. Firme o celular e tente novamente.';
    }
    if (acceleration != null) {
      final anchor = _anchorAcceleration;
      if ((acceleration.length - standardGravity).abs() > maxGravityDeviation ||
          (anchor != null &&
              (acceleration - anchor).length > maxAccelerationChange)) {
        return 'Movimento detectado. Mantenha o celular parado e tente novamente.';
      }
    }
    return null;
  }

  void observeReading(SensorReading reading) {
    if (phase != CalibrationPhase.collecting) return;
    final value = reading.vector;
    if (value == null) return;
    switch (reading.kind) {
      case SensorKind.acceleration:
        _smoothAcceleration(value, reading.timestampUs);
      case SensorKind.angularVelocity:
        _smoothGyro(value, reading.timestampUs);
      case SensorKind.orientation:
        return;
    }
    final movement = _movement();
    if (movement != null) _restartOrReject(reading.timestampUs, movement);
  }

  void addFrame(MotionFrame frame) {
    if (phase != CalibrationPhase.collecting) return;
    final previousUs = _previousUs;
    if (previousUs != null) {
      if (frame.timestampUs <= previousUs) return;
      if (frame.timestampUs - previousUs > maxGapUs) {
        interrupt();
        return;
      }
    }
    _previousUs = frame.timestampUs;
    _attemptStartUs ??= frame.timestampUs;
    // Frames repeat the latest readings; feed them in case the readings were
    // not observed (the smoothing ignores timestamps it has already seen).
    _smoothAcceleration(frame.acceleration, frame.timestampUs);
    _smoothGyro(frame.angularVelocity, frame.timestampUs);
    final movement = _movement();
    if (movement != null) {
      _restartOrReject(frame.timestampUs, movement);
      return;
    }
    final startUs = _startUs ??= frame.timestampUs;
    final anchor = _anchor ??= frame.orientation;
    _anchorAcceleration ??= _acceleration;
    if (anchor.angleTo(frame.orientation) > maxOrientationDeviation) {
      _restartOrReject(
        frame.timestampUs,
        'A orientação mudou durante a medição. Tente novamente.',
      );
      return;
    }
    _count++;
    _average =
        _average?.slerp(frame.orientation, 1 / _count) ?? frame.orientation;
    final elapsed = frame.timestampUs - startUs;
    progress = (elapsed / windowUs).clamp(0.0, 1.0);
    if (elapsed < windowUs) return;
    if (_count < minimumFrames) {
      _reject(
        'Poucas amostras de orientação. Aumente a taxa de captura e tente novamente.',
      );
      return;
    }
    reference = _average;
    feedback = null;
    phase = CalibrationPhase.accepted;
  }

  /// A movement restarts the steady window while the attempt is young, so a
  /// wobble costs a few seconds instead of a manual retry.
  void _restartOrReject(int timestampUs, String reason) {
    final attemptStartUs = _attemptStartUs ??= timestampUs;
    if (timestampUs - attemptStartUs >= attemptTimeoutUs) {
      _reject(reason);
      return;
    }
    _resetWindow();
    feedback = holdStillFeedback;
  }

  void _resetWindow() {
    progress = 0;
    _anchor = null;
    _anchorAcceleration = null;
    _average = null;
    _startUs = null;
    _count = 0;
  }

  void _reject(String reason) {
    phase = CalibrationPhase.rejected;
    feedback = reason;
    progress = 0;
  }
}

class OrientationFilter {
  Rotation? _filtered;
  int? _timestampUs;

  void reset() {
    _filtered = null;
    _timestampUs = null;
  }

  Rotation update(
    Rotation relative,
    int timestampUs, {
    required int smoothingMs,
    required double deadZoneDegrees,
  }) {
    final last = _filtered;
    final lastUs = _timestampUs;
    _timestampUs = timestampUs;
    final elapsedUs = lastUs == null ? 0 : timestampUs - lastUs;
    final alpha = smoothingMs == 0
        ? 1.0
        : 1 - math.exp(-elapsedUs / (1000 * smoothingMs));
    final filtered = last == null || elapsedUs <= 0 || elapsedUs > 200000
        ? relative
        : last.slerp(relative, alpha);
    _filtered = filtered;

    final deadZone = deadZoneDegrees * math.pi / 180;
    if (deadZone == 0) return filtered;
    final angle = Rotation.identity.angleTo(filtered);
    if (angle <= deadZone) return Rotation.identity;
    return Rotation.identity.slerp(filtered, 1 - deadZone / angle);
  }
}
