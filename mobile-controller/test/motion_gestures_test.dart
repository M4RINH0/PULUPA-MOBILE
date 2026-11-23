import 'package:flutter_test/flutter_test.dart';
import 'package:pulupa_controller/core/motion_math.dart';
import 'package:pulupa_controller/features/gestures/motion_gestures.dart';
import 'package:pulupa_controller/features/sensors/sensor_source.dart';

MotionFrame frame(
  int timestamp, {
  Vec3 acceleration = const Vec3(0, 0, 9.8),
  Vec3 gyro = Vec3.zero,
  Rotation rotation = Rotation.identity,
}) => MotionFrame(
  timestampUs: timestamp,
  acceleration: acceleration,
  angularVelocity: gyro,
  orientation: rotation,
);

void main() {
  test(
    'threshold emits approximate start and end with hysteresis and cooldown',
    () {
      final detector = ThresholdGestureDetector(
        GestureKind.quickRotation,
        (frame, _) => frame.angularVelocity.length,
        const GestureThreshold(
          on: 3,
          off: 1,
          startHoldMs: 20,
          endHoldMs: 20,
          cooldownMs: 100,
          smoothingMs: 0,
        ),
      );
      GestureEvent? sample(int timeMs, double speed) => detector.update(
        frame(timeMs * 1000, gyro: Vec3(speed, 0, 0)),
        calibrated: true,
      );
      expect(sample(0, 4), isNull);
      expect(sample(20, 4)?.phase, GesturePhase.started);
      expect(sample(40, 2), isNull);
      expect(sample(60, 0), isNull);
      expect(sample(80, 0)?.phase, GesturePhase.ended);
      expect(sample(100, 5), isNull);
      expect(sample(179, 5), isNull);
      expect(sample(180, 5), isNull);
      expect(sample(200, 5)?.phase, GesturePhase.started);
    },
  );

  test(
    'sustained movement activates detectors and tilt uses the neutral pose',
    () {
      final gestures = MotionGestures();
      final tilted = Rotation.axisAngle(const Vec3(1, 0, 0), 1);
      for (var t = 0; t <= 200000; t += 10000) {
        gestures.update(
          frame(
            t,
            acceleration: const Vec3(0, 0, 14),
            gyro: const Vec3(5, 0, 0),
            rotation: tilted,
          ),
          calibrated: false,
        );
      }
      expect(gestures.active, {
        GestureKind.abruptMotion,
        GestureKind.quickRotation,
        GestureKind.swing,
      });
      for (var t = 210000; t <= 430000; t += 10000) {
        gestures.update(frame(t, rotation: tilted), calibrated: true);
      }
      expect(gestures.active, {GestureKind.tilt});
      gestures.update(frame(900000), calibrated: true);
      expect(gestures.active, isEmpty);
    },
  );
}
