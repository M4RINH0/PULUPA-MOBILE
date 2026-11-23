import '../../core/motion_math.dart';

const standardGravity = 9.80665;

// Gyroscope propagation with slow gravity correction when acceleration is near g.
// Gravity provides no observation of heading.
class GravityFusion {
  Rotation? _orientation;
  int? _previousUs;

  void reset() {
    _orientation = null;
    _previousUs = null;
  }

  Rotation? update(int timestampUs, Vec3 gyro, Vec3? acceleration) {
    final previousUs = _previousUs;
    _previousUs = timestampUs;
    final canUseGravity =
        acceleration != null &&
        (acceleration.length - standardGravity).abs() < 0.9;
    var orientation = _orientation;
    if (orientation == null) {
      if (!canUseGravity || gyro.length > 0.35) return null;
      return _orientation = Rotation.between(acceleration, Vec3.up);
    }
    if (previousUs == null) return orientation;
    final seconds = (timestampUs - previousUs) / 1000000;
    if (seconds <= 0 || seconds > 0.2) return orientation;

    var correctedGyro = gyro;
    if (canUseGravity) {
      final expected = orientation.inverseUnit.rotate(Vec3.up);
      correctedGyro += acceleration.normalized().cross(expected) * 0.7;
    }
    final delta = Rotation.axisAngle(
      correctedGyro,
      correctedGyro.length * seconds,
    );
    orientation = (orientation * delta).normalized();
    return _orientation = orientation;
  }
}
