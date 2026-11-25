import 'dart:math' as math;

import '../../core/motion_math.dart';

const standardGravity = 9.80665;

// Gyroscope propagation with slow gravity correction when acceleration is near g.
// Gravity provides no observation of heading.
class GravityFusion {
  /// Longest interval integrated from a single gyroscope sample.
  static const maxIntegrationUs = 200000;

  /// Proportional gain of the gravity correction, in rad/s per unit error.
  static const correctionGain = 1.2;

  /// Gravity is trusted only while |a| stays this close to g.
  static const maxGravityDeviation = 0.9;

  /// Correction fades out between these angular speeds (rad/s).
  static const fullCorrectionGyro = 0.5;
  static const maxCorrectionGyro = 1.0;

  /// Correction is skipped while the acceleration vector departs this much
  /// from its low-pass value (m/s²), as in calibration.
  static const maxAccelerationChange = 0.75;
  static const _lowPassSeconds = 0.15;

  Rotation? _orientation;
  Vec3? _lowPass;
  int? _previousUs;

  /// True when the most recent update followed a gap longer than
  /// [maxIntegrationUs]. Rotation during the gap is unknown; the tilt is
  /// re-aligned with gravity when possible and the heading is kept.
  bool interrupted = false;

  void reset() {
    _orientation = null;
    _lowPass = null;
    _previousUs = null;
    interrupted = false;
  }

  Rotation? update(int timestampUs, Vec3 gyro, Vec3? acceleration) {
    final previousUs = _previousUs;
    interrupted = false;
    if (previousUs != null && timestampUs <= previousUs) return _orientation;
    _previousUs = timestampUs;
    final seconds = previousUs == null
        ? 0.0
        : (timestampUs - previousUs) / 1000000;
    final gap =
        previousUs != null && timestampUs - previousUs > maxIntegrationUs;
    final canUseGravity =
        acceleration != null &&
        (acceleration.length - standardGravity).abs() < maxGravityDeviation;

    final lowPass = _lowPass;
    final steady =
        acceleration != null &&
        lowPass != null &&
        !gap &&
        (acceleration - lowPass).length <= maxAccelerationChange;
    if (acceleration != null) {
      _lowPass = lowPass == null || gap
          ? acceleration
          : lowPass +
                (acceleration - lowPass) *
                    (1 - math.exp(-seconds / _lowPassSeconds));
    }

    var orientation = _orientation;
    if (orientation == null) {
      if (!canUseGravity || gyro.length > 0.35) return null;
      return _orientation = Rotation.between(acceleration, Vec3.up);
    }
    if (previousUs == null || seconds <= 0) return orientation;

    if (gap) {
      interrupted = true;
      if (canUseGravity) {
        // Minimal rotation about a horizontal axis: tilt follows gravity and
        // the heading accumulated before the gap is preserved.
        final expected = orientation.inverseUnit.rotate(Vec3.up);
        orientation = (orientation * Rotation.between(acceleration, expected))
            .normalized();
      }
      return _orientation = orientation;
    }

    var correctedGyro = gyro;
    if (canUseGravity && steady) {
      final weight = _gravityWeight(acceleration, gyro);
      final expected = orientation.inverseUnit.rotate(Vec3.up);
      correctedGyro +=
          acceleration.normalized().cross(expected) * (correctionGain * weight);
    }
    final delta = Rotation.axisAngle(
      correctedGyro,
      correctedGyro.length * seconds,
    );
    orientation = (orientation * delta).normalized();
    return _orientation = orientation;
  }

  static double _gravityWeight(Vec3 acceleration, Vec3 gyro) {
    final norm =
        1 - (acceleration.length - standardGravity).abs() / maxGravityDeviation;
    final speed = gyro.length;
    final rotation = speed <= fullCorrectionGyro
        ? 1.0
        : 1 -
              (speed - fullCorrectionGyro) /
                  (maxCorrectionGyro - fullCorrectionGyro);
    return (norm.clamp(0.0, 1.0) * rotation.clamp(0.0, 1.0)).toDouble();
  }
}
