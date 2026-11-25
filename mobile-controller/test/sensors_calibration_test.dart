import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pulupa_controller/core/motion_math.dart';
import 'package:pulupa_controller/features/calibration/calibration.dart';
import 'package:pulupa_controller/features/sensors/gravity_fusion.dart';
import 'package:pulupa_controller/features/sensors/motion_processor.dart';
import 'package:pulupa_controller/features/sensors/sensor_source.dart';
import 'package:pulupa_controller/features/sensors/simulated_sensors.dart';

void feed(
  MotionProcessor processor,
  int timestamp, {
  bool moving = false,
  bool system = true,
}) {
  final readings = SimulatedSensors.sampleAt(timestamp, moving: moving);
  for (final reading in readings) {
    if (system || reading.kind != SensorKind.orientation) {
      processor.ingest(reading, timestamp);
    }
  }
}

MotionFrame staticFrame(int time, {Rotation rotation = Rotation.identity}) =>
    MotionFrame(
      timestampUs: time,
      orientation: rotation,
      acceleration: Vec3.up * standardGravity,
      angularVelocity: Vec3.zero,
    );

void main() {
  test('simulation measures rate, calibrates, tracks motion, recalibrates and expires stale data', () {
    final processor = MotionProcessor(SimulatedSensors.hardware);
    feed(processor, 0);
    processor.calibration.start();
    for (var t = 10000; t < 1500000; t += 10000) {
      feed(processor, t);
    }
    expect(processor.calibration.phase, CalibrationPhase.collecting);
    for (var t = 1500000; t <= 2010000; t += 10000) {
      feed(processor, t);
    }
    expect(processor.calibration.phase, CalibrationPhase.accepted);
    expect(processor.orientationAt(2010000), Rotation.identity);
    for (final kind in SensorKind.values) {
      expect(processor.rateAt(kind, 2010000), 100);
    }
    for (var t = 2020000; t <= 2400000; t += 10000) {
      feed(processor, t, moving: true);
    }
    expect(
      processor.orientationAt(2400000)!.angleTo(Rotation.identity),
      greaterThan(0.4),
    );
    processor.calibration.start();
    for (var t = 2410000; t <= 4410000; t += 10000) {
      feed(processor, t);
    }
    expect(processor.calibration.phase, CalibrationPhase.accepted);
    expect(processor.frameAt(4410000)!.orientation, Rotation.identity);
    expect(processor.frameAt(4700000), isNull);
    expect(processor.orientationAt(4800000), isNull);
    expect(processor.rateAt(SensorKind.angularVelocity, 4800000), 0);
  });

  test('an isolated gyro spike does not interrupt recalibration', () {
    final processor = MotionProcessor(SimulatedSensors.hardware);
    processor.calibration.start();
    for (var t = 0; t <= 2000000; t += 10000) {
      feed(processor, t);
    }
    final neutral = processor.calibration.reference;
    expect(neutral, isNotNull);
    processor.calibration.start();
    feed(processor, 2010000);
    processor.ingest(
      const SensorReading.vector(
        SensorKind.angularVelocity,
        2015000,
        Vec3(1.2, 0, 0),
      ),
      2015000,
    );
    feed(processor, 2020000);
    expect(processor.calibration.phase, CalibrationPhase.collecting);
    expect(processor.calibration.feedback, isNull);
    for (var t = 2030000; t <= 3600000; t += 10000) {
      feed(processor, t);
    }
    expect(processor.calibration.phase, CalibrationPhase.accepted);
  });

  test('sustained rotation restarts the window and fails only after the timeout', () {
    final calibration = Calibration()..start();
    var t = 0;
    for (; t < 3000000; t += 10000) {
      calibration.addFrame(
        MotionFrame(
          timestampUs: t,
          orientation: Rotation.identity,
          acceleration: Vec3.up * standardGravity,
          angularVelocity: const Vec3(1, 0, 0),
        ),
      );
    }
    expect(calibration.phase, CalibrationPhase.collecting);
    expect(calibration.feedback, Calibration.holdStillFeedback);
    expect(calibration.progress, 0);
    for (; t <= Calibration.attemptTimeoutUs + 10000; t += 10000) {
      calibration.addFrame(
        MotionFrame(
          timestampUs: t,
          orientation: Rotation.identity,
          acceleration: Vec3.up * standardGravity,
          angularVelocity: const Vec3(1, 0, 0),
        ),
      );
    }
    expect(calibration.phase, CalibrationPhase.rejected);
    expect(calibration.reference, isNull);
  });

  test('hand tremor within the tolerance still calibrates', () {
    final calibration = Calibration()..start();
    for (var t = 0; t <= 1600000; t += 10000) {
      final wobble = math.sin(t / 1e6 * 2 * math.pi * 8);
      calibration.addFrame(
        MotionFrame(
          timestampUs: t,
          orientation: Rotation.axisAngle(
            const Vec3(1, 0, 0),
            3 * math.pi / 180 * wobble,
          ),
          acceleration: Vec3.up * standardGravity + Vec3(0.6 * wobble, 0, 0),
          angularVelocity: Vec3(0.35 * wobble, 0.2, 0),
        ),
      );
    }
    expect(calibration.phase, CalibrationPhase.accepted);
  });

  test('orientation drift, acceleration deviations and interrupted calibration are rejected', () {
    final calibration = Calibration()..start();
    calibration.addFrame(staticFrame(0));
    calibration.addFrame(
      staticFrame(
        10000,
        rotation: Rotation.axisAngle(Vec3.up, 12 * math.pi / 180),
      ),
    );
    expect(calibration.phase, CalibrationPhase.collecting);
    expect(calibration.feedback, Calibration.holdStillFeedback);
    calibration.addFrame(
      staticFrame(
        Calibration.attemptTimeoutUs,
        rotation: Rotation.axisAngle(Vec3.up, 30 * math.pi / 180),
      ),
    );
    expect(calibration.phase, CalibrationPhase.rejected);

    calibration.start();
    calibration.observeReading(
      const SensorReading.vector(SensorKind.acceleration, 0, Vec3.zero),
    );
    expect(calibration.phase, CalibrationPhase.collecting);
    expect(calibration.feedback, Calibration.holdStillFeedback);

    calibration.start();
    calibration.addFrame(staticFrame(0));
    calibration.addFrame(staticFrame(210000));
    expect(calibration.phase, CalibrationPhase.rejected);
    expect(calibration.reference, isNull);
  });

  test('a continuous stream with too few samples cannot pass calibration', () {
    final calibration = Calibration()..start();
    for (var t = 0; t <= 2000000; t += 100000) {
      calibration.addFrame(staticFrame(t));
      calibration.addFrame(
        staticFrame(t),
      ); // Duplicate timestamps do not count.
    }
    expect(calibration.phase, CalibrationPhase.rejected);
    expect(calibration.reference, isNull);
  });

  test('fallback starts if a reported native sensor is silent and clears reference on recovery', () {
    final processor = MotionProcessor(SimulatedSensors.hardware);
    feed(processor, 0, system: false);
    expect(processor.orientationAt(0), isNull);
    for (var t = 10000; t <= 400000; t += 10000) {
      feed(processor, t, system: false);
    }
    expect(processor.orientationSource, OrientationSource.gyroscopeGravity);
    final initial = processor.orientationAt(400000)!;
    expect(initial.eulerDegrees.pitch, closeTo(0.35 * 180 / math.pi, 1e-9));

    processor.calibration.start();
    for (var t = 410000; t <= 2410000; t += 10000) {
      feed(processor, t, system: false);
    }
    expect(processor.calibration.reference, isNotNull);
    feed(processor, 2420000);
    expect(processor.orientationSource, OrientationSource.systemFusion);
    expect(processor.calibration.reference, isNull);
    expect(processor.frameAt(2420000), isNull);
    feed(processor, 2430000);
    expect(processor.frameAt(2430000)?.timestampUs, 2430000);
  });

  test(
    'fallback integrates angular velocity around a gravity-aligned yaw axis',
    () {
      final fusion = GravityFusion();
      final gravity = Vec3.up * standardGravity;
      expect(fusion.update(0, Vec3.zero, gravity), isNotNull);
      for (var t = 10000; t < 1000000; t += 10000) {
        fusion.update(t, Vec3.up, gravity);
      }
      expect(
        fusion.update(1000000, Vec3.up, gravity)!.eulerDegrees.yaw,
        closeTo(180 / math.pi, 1e-6),
      );
    },
  );

  test('partial hardware can display native orientation but cannot supply full frames', () {
    final processor = MotionProcessor(
      const SensorCapabilities(
        acceleration: false,
        gyroscope: true,
        systemOrientation: true,
      ),
    );
    processor.ingest(const SensorReading.orientation(0, Rotation.identity), 0);
    expect(processor.orientationAt(0)?.angleTo(Rotation.identity), 0);
    expect(processor.frameAt(0), isNull);
    expect(processor.capabilities.canCalibrate, isFalse);
  });

  test('a saved neutral tilt is restored with the heading of the current pose', () {
    const degree = math.pi / 180;
    // Held sideways, screen toward the player, facing 30° from north.
    final hold =
        Rotation.axisAngle(const Vec3(0, 1, 0), -90 * degree) *
        Rotation.axisAngle(const Vec3(1, 0, 0), 70 * degree);
    final before = Rotation.axisAngle(Vec3.up, 30 * degree) * hold;
    final original = Calibration()
      ..reference = before
      ..referenceSource = OrientationSource.systemFusion;
    final tilt = original.neutralTilt!;

    // After reopening, the sensor's heading origin moved by 110°.
    final now = Rotation.axisAngle(Vec3.up, 140 * degree) * hold;
    final restored = Calibration()
      ..restoreTilt(tilt, OrientationSource.systemFusion);
    expect(restored.reference, isNull);
    expect(
      restored.applyPendingTilt(now, OrientationSource.gyroscopeGravity),
      isFalse,
    );
    expect(restored.applyPendingTilt(now, OrientationSource.systemFusion), isTrue);
    expect(restored.phase, CalibrationPhase.accepted);
    expect(restored.feedback, Calibration.restoredFeedback);
    expect(
      gravityAlignedRelative(restored.reference!, now).angleTo(Rotation.identity),
      lessThan(1e-6),
    );
    // Tilting from there behaves as before the app was closed.
    final steer = Rotation.axisAngle(
          headingOf(now).rotate(const Vec3(0, 1, 0)),
          15 * degree,
        ) *
        now;
    expect(
      gameAnglesDegrees(
        rotationInGameAxes(gravityAlignedRelative(restored.reference!, steer)),
      ).roll,
      closeTo(15, 1e-6),
    );
    // A new calibration discards a pending restore.
    final pending = Calibration()
      ..restoreTilt(tilt, OrientationSource.systemFusion)
      ..start();
    expect(pending.applyPendingTilt(now, OrientationSource.systemFusion), isFalse);
  });
}
