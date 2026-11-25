import '../../core/motion_math.dart';

enum SensorKind { acceleration, angularVelocity, orientation }

enum OrientationSource { systemFusion, gyroscopeGravity, unavailable }

class SensorCapabilities {
  const SensorCapabilities({
    required this.acceleration,
    required this.gyroscope,
    required this.systemOrientation,
  });

  final bool acceleration;
  final bool gyroscope;
  final bool systemOrientation;

  OrientationSource get orientationSource {
    if (systemOrientation) return OrientationSource.systemFusion;
    if (acceleration && gyroscope) return OrientationSource.gyroscopeGravity;
    return OrientationSource.unavailable;
  }

  bool get canCalibrate => acceleration && gyroscope;
}

class SensorReading {
  const SensorReading.vector(this.kind, this.timestampUs, Vec3 value)
    : vector = value,
      rotation = null;

  const SensorReading.orientation(this.timestampUs, Rotation value)
    : kind = SensorKind.orientation,
      rotation = value,
      vector = null;

  final SensorKind kind;
  final int timestampUs;
  final Vec3? vector;
  final Rotation? rotation;

  bool get isValid =>
      timestampUs >= 0 &&
      (kind == SensorKind.orientation
          ? rotation?.isUsable == true
          : vector?.isFinite == true);
}

abstract interface class SensorSource {
  Future<SensorCapabilities> capabilities();
  Stream<SensorReading> readings(int requestedHz);
}

class MotionFrame {
  const MotionFrame({
    required this.timestampUs,
    required this.orientation,
    required this.acceleration,
    required this.angularVelocity,
    this.linearAcceleration,
    this.peakLinearAcceleration,
    this.peakAngularVelocity,
  });

  final int timestampUs;
  final Rotation orientation;
  final Vec3 acceleration;
  final Vec3 angularVelocity;

  /// Specific force minus the gravity estimated from the raw (uncalibrated)
  /// orientation, in device axes. Null when no estimate exists.
  final Vec3? linearAcceleration;

  /// Largest |linear acceleration| observed since the previous frame,
  /// including readings that arrived between orientation samples.
  final double? peakLinearAcceleration;

  /// Largest |angular velocity| observed since the previous frame.
  final double? peakAngularVelocity;
}
