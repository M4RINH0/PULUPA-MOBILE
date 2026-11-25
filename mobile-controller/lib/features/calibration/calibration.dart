import 'dart:math' as math;

import '../../core/motion_math.dart';
import '../sensors/gravity_fusion.dart';
import '../sensors/sensor_source.dart';

enum CalibrationPhase { idle, collecting, accepted, rejected }

class Calibration {
  static const windowUs = 2000000;
  static const maxGapUs = 200000;
  static const minimumFrames = 31;
  static const maxAngularVelocity = 0.18;
  static const maxGravityDeviation = 0.65;
  static const maxAccelerationChange = 0.75;
  static const maxOrientationDeviation = 4 * math.pi / 180;

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
  int _count = 0;

  void start() {
    phase = CalibrationPhase.collecting;
    progress = 0;
    feedback = null;
    _anchor = null;
    _anchorAcceleration = null;
    _average = null;
    _startUs = null;
    _previousUs = null;
    _count = 0;
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

  static bool isStationary(Vec3 acceleration, Vec3 gyro) =>
      (acceleration.length - standardGravity).abs() <= maxGravityDeviation &&
      gyro.length <= maxAngularVelocity;

  bool _accelerationChanged(Vec3 acceleration) {
    final anchor = _anchorAcceleration;
    return anchor != null &&
        (acceleration - anchor).length > maxAccelerationChange;
  }

  void observeReading(SensorReading reading) {
    if (phase != CalibrationPhase.collecting) return;
    final value = reading.vector;
    if (value == null) return;
    final exceedsLimit = switch (reading.kind) {
      SensorKind.acceleration =>
        (value.length - standardGravity).abs() > maxGravityDeviation ||
            _accelerationChanged(value),
      SensorKind.angularVelocity => value.length > maxAngularVelocity,
      SensorKind.orientation => false,
    };
    if (exceedsLimit) {
      _reject(
        'Movimento detectado. Apoie ou firme o celular e tente novamente.',
      );
    }
  }

  void addFrame(MotionFrame frame) {
    if (phase != CalibrationPhase.collecting) return;
    if (!isStationary(frame.acceleration, frame.angularVelocity) ||
        _accelerationChanged(frame.acceleration)) {
      _reject(
        'Movimento detectado. Mantenha o celular imóvel e tente novamente.',
      );
      return;
    }
    final startUs = _startUs ??= frame.timestampUs;
    final anchor = _anchor ??= frame.orientation;
    _anchorAcceleration ??= frame.acceleration;
    final previousUs = _previousUs;
    if (previousUs != null) {
      if (frame.timestampUs <= previousUs) return;
      if (frame.timestampUs - previousUs > maxGapUs) {
        interrupt();
        return;
      }
    }
    _previousUs = frame.timestampUs;
    if (anchor.angleTo(frame.orientation) > maxOrientationDeviation) {
      _reject('A orientação mudou durante a medição. Tente novamente.');
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
    phase = CalibrationPhase.accepted;
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
