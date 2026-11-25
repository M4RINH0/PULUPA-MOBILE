import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pulupa_controller/core/motion_math.dart';
import 'package:pulupa_controller/features/calibration/calibration.dart';
import 'package:pulupa_controller/features/gestures/motion_gestures.dart';
import 'package:pulupa_controller/features/sensors/gravity_fusion.dart';
import 'package:pulupa_controller/features/sensors/motion_processor.dart';
import 'package:pulupa_controller/features/sensors/sensor_source.dart';
import 'package:pulupa_controller/features/sensors/simulated_sensors.dart';

const degrees = math.pi / 180;
const xAxis = Vec3(1, 0, 0);
const yAxis = Vec3(0, 1, 0);

/// Specific force measured by a still device in [pose] (device to world).
Vec3 gravityIn(Rotation pose) =>
    pose.inverseUnit.rotate(Vec3.up) * standardGravity;

/// Tilt between the device's estimated and true up directions.
double tiltError(Rotation estimate, Rotation truth) {
  final a = estimate.inverseUnit.rotate(Vec3.up);
  final b = truth.inverseUnit.rotate(Vec3.up);
  return math.acos(a.dot(b).clamp(-1.0, 1.0));
}

void feedPose(
  MotionProcessor processor,
  int timestamp,
  Rotation pose, {
  Vec3 gyro = Vec3.zero,
  Vec3 extra = Vec3.zero,
}) {
  processor
    ..ingest(
      SensorReading.vector(
        SensorKind.acceleration,
        timestamp,
        gravityIn(pose) + extra,
      ),
      timestamp,
    )
    ..ingest(
      SensorReading.vector(SensorKind.angularVelocity, timestamp, gyro),
      timestamp,
    )
    ..ingest(SensorReading.orientation(timestamp, pose), timestamp);
}

int calibrateAt(MotionProcessor processor, Rotation pose, {int start = 0}) {
  processor.calibration.start();
  var t = start;
  for (; t <= start + 2000000; t += 10000) {
    feedPose(processor, t, pose);
  }
  expect(processor.calibration.phase, CalibrationPhase.accepted);
  return t;
}

void expectVector(Vec3 actual, Vec3 expected, {double tolerance = 1e-6}) {
  expect(actual.x, closeTo(expected.x, tolerance));
  expect(actual.y, closeTo(expected.y, tolerance));
  expect(actual.z, closeTo(expected.z, tolerance));
}

void main() {
  group('gravity fusion', () {
    test('gravity correction removes a 20° tilt error within 3 s', () {
      final fusion = GravityFusion();
      final wrong = Rotation.axisAngle(xAxis, 20 * degrees);
      // Initialise from a gravity sample that implies a 20° tilt.
      expect(fusion.update(0, Vec3.zero, gravityIn(wrong)), isNotNull);
      final truth = Rotation.identity;
      expect(
        tiltError(fusion.update(10000, Vec3.zero, gravityIn(wrong))!, truth),
        closeTo(20 * degrees, 1e-6),
      );
      Rotation? estimate;
      for (var t = 20000; t <= 3010000; t += 10000) {
        estimate = fusion.update(t, Vec3.zero, gravityIn(truth));
      }
      expect(tiltError(estimate!, truth), lessThan(1 * degrees));
    });

    test('correction is suspended during fast rotation', () {
      final fusion = GravityFusion();
      final wrong = Rotation.axisAngle(xAxis, 20 * degrees);
      fusion.update(0, Vec3.zero, gravityIn(wrong));
      fusion.update(10000, Vec3.zero, gravityIn(wrong));
      // Spin about the estimated vertical: the yaw does not change the tilt,
      // so any tilt change could only come from the gravity correction.
      final spin = wrong.inverseUnit.rotate(Vec3.up) * 1.5;
      Rotation? estimate;
      for (var t = 20000; t <= 1010000; t += 10000) {
        estimate = fusion.update(t, spin, gravityIn(Rotation.identity));
      }
      expect(
        tiltError(estimate!, Rotation.identity),
        closeTo(20 * degrees, 0.01 * degrees),
      );
    });

    test('a sudden change of the acceleration vector is not trusted', () {
      final fusion = GravityFusion();
      fusion.update(0, Vec3.zero, gravityIn(Rotation.identity));
      fusion.update(10000, Vec3.zero, gravityIn(Rotation.identity));
      // Same magnitude as g but pointing 30° away: a linear jolt, not tilt.
      final jolt = gravityIn(Rotation.axisAngle(yAxis, 30 * degrees));
      final estimate = fusion.update(20000, Vec3.zero, jolt)!;
      expect(tiltError(estimate, Rotation.identity), lessThan(1e-6));
    });

    test('a gap over 200 ms re-aligns tilt with gravity, keeps heading and '
        'signals the interruption', () {
      final fusion = GravityFusion();
      fusion.update(0, Vec3.zero, gravityIn(Rotation.identity));
      // Yaw by 1 rad while level.
      for (var t = 10000; t <= 1000000; t += 10000) {
        fusion.update(t, Vec3.up, gravityIn(Rotation.identity));
      }
      expect(fusion.interrupted, isFalse);
      final heading = Rotation.axisAngle(Vec3.up, 1);
      final tilted = heading * Rotation.axisAngle(xAxis, 25 * degrees);
      final estimate = fusion.update(1500000, Vec3.zero, gravityIn(tilted))!;
      expect(fusion.interrupted, isTrue);
      expect(tiltError(estimate, tilted), lessThan(1e-6));
      expect(estimate.angleTo(tilted), lessThan(1e-3));
      fusion.update(1510000, Vec3.zero, gravityIn(tilted));
      expect(fusion.interrupted, isFalse);
    });

    test('a fallback gap interrupts an ongoing calibration', () {
      final processor = MotionProcessor(SimulatedSensors.hardware);
      void feedFallback(int t) {
        for (final reading in SimulatedSensors.sampleAt(t, moving: false)) {
          if (reading.kind != SensorKind.orientation) {
            processor.ingest(reading, t);
          }
        }
      }

      for (var t = 0; t <= 400000; t += 10000) {
        feedFallback(t);
      }
      processor.calibration.start();
      for (var t = 410000; t <= 1000000; t += 10000) {
        feedFallback(t);
      }
      expect(processor.calibration.phase, CalibrationPhase.collecting);
      feedFallback(1400000);
      expect(processor.calibration.phase, CalibrationPhase.rejected);
    });
  });

  group('gravity-aligned neutral pose', () {
    // World: +Z up, +Y is the direction the player faces.
    // Portrait, screen facing the player: device top up, screen toward -Y.
    final upright = Rotation.axisAngle(xAxis, math.pi / 2);
    const gameUp = Vec3(0, 1, 0);
    const gameForward = Vec3(0, 0, -1);
    const gameRight = Vec3(1, 0, 0);

    for (final headingDegrees in [0.0, 70.0, -150.0]) {
      final heading = Rotation.axisAngle(Vec3.up, headingDegrees * degrees);
      Rotation worldAboutRight(double angle) =>
          Rotation.axisAngle(heading.rotate(xAxis), angle);
      Rotation worldAboutForward(double angle) =>
          Rotation.axisAngle(heading.rotate(yAxis), angle);

      test('upright calibration maps tilts to game axes '
          '(heading $headingDegrees°)', () {
        final neutral = heading * upright;
        final processor = MotionProcessor(SimulatedSensors.hardware)
          ..smoothingMs = 0
          ..deadZoneDegrees = 0;
        var t = calibrateAt(processor, neutral);
        expect(
          rotationInGameAxes(processor.orientationAt(t)!)
              .angleTo(Rotation.identity),
          lessThan(1e-6),
        );

        // Top of the phone tips away from the player by 30°.
        final forward = worldAboutRight(-30 * degrees) * neutral;
        feedPose(processor, t += 10000, forward);
        final pitched = rotationInGameAxes(processor.frameAt(t)!.orientation);
        expectVector(
          pitched.rotate(gameUp),
          gameUp * math.cos(30 * degrees) +
              gameForward * math.sin(30 * degrees),
        );
        expectVector(pitched.rotate(gameRight), gameRight);

        // Top of the phone leans to the player's right by 30°.
        final sideways = worldAboutForward(30 * degrees) * neutral;
        feedPose(processor, t += 10000, sideways);
        final rolled = rotationInGameAxes(processor.frameAt(t)!.orientation);
        expectVector(
          rolled.rotate(gameUp),
          gameUp * math.cos(30 * degrees) + gameRight * math.sin(30 * degrees),
        );
        expectVector(rolled.rotate(gameForward), gameForward);

        // Turning left about the vertical is a pure game yaw, not a tilt.
        final turned = Rotation.axisAngle(Vec3.up, 40 * degrees) * neutral;
        feedPose(processor, t += 10000, turned);
        final yawed = rotationInGameAxes(processor.frameAt(t)!.orientation);
        expectVector(yawed.rotate(gameUp), gameUp);
        expectVector(
          yawed.rotate(gameForward),
          gameForward * math.cos(40 * degrees) +
              gameRight * -math.sin(40 * degrees),
        );
      });
    }

    test('flat calibration keeps the previous relative orientation', () {
      final neutral =
          Rotation.axisAngle(Vec3.up, 1.1) *
          Rotation.axisAngle(xAxis, 3 * degrees);
      final current = neutral * Rotation.axisAngle(const Vec3(1, 2, 0.5), 0.6);
      final flat = Rotation.axisAngle(Vec3.up, 1.1);
      final flatCurrent = flat * Rotation.axisAngle(const Vec3(1, 2, 0.5), 0.6);
      expect(
        gravityAlignedRelative(
          flat,
          flatCurrent,
        ).angleTo((flat.inverseUnit * flatCurrent).normalized()),
        lessThan(1e-6),
      );
      // Small tilts in the neutral pose change the result only slightly.
      expect(
        gravityAlignedRelative(
          neutral,
          current,
        ).angleTo((neutral.inverseUnit * current).normalized()),
        lessThan(6 * degrees),
      );
    });

    test('tilt gesture ignores yaw after an upright calibration', () {
      final neutral = upright;
      final processor = MotionProcessor(SimulatedSensors.hardware)
        ..smoothingMs = 0
        ..deadZoneDegrees = 0;
      var t = calibrateAt(processor, neutral);
      final gestures = MotionGestures();
      final turned = Rotation.axisAngle(Vec3.up, 60 * degrees) * neutral;
      for (var i = 0; i < 30; i++) {
        feedPose(processor, t += 10000, turned);
        gestures.update(processor.frameAt(t)!, calibrated: true);
      }
      expect(gestures.active, isNot(contains(GestureKind.tilt)));
      final tipped = Rotation.axisAngle(xAxis, -40 * degrees) * neutral;
      for (var i = 0; i < 30; i++) {
        feedPose(processor, t += 10000, tipped);
        gestures.update(processor.frameAt(t)!, calibrated: true);
      }
      expect(gestures.active, contains(GestureKind.tilt));
    });
  });

  group('processor', () {
    test('a source switch explains why the reference was cleared', () {
      final processor = MotionProcessor(SimulatedSensors.hardware);
      var t = calibrateAt(processor, Rotation.identity);
      for (final reading in SimulatedSensors.sampleAt(
        t += 400000,
        moving: false,
      )) {
        if (reading.kind != SensorKind.orientation) {
          processor.ingest(reading, t);
        }
      }
      // Native orientation went silent: fallback takes over.
      for (var i = 0; i < 3; i++) {
        t += 10000;
        for (final reading in SimulatedSensors.sampleAt(t, moving: false)) {
          if (reading.kind != SensorKind.orientation) {
            processor.ingest(reading, t);
          }
        }
      }
      expect(processor.orientationSource, OrientationSource.gyroscopeGravity);
      expect(processor.calibration.reference, isNull);
      expect(
        processor.calibration.feedback,
        MotionProcessor.sourceChangedFeedback,
      );
    });

    test('a shared calibration survives a new processor for the same source '
        'and is dropped for a different one', () {
      final calibration = Calibration();
      final first = MotionProcessor(
        SimulatedSensors.hardware,
        calibration: calibration,
      );
      calibrateAt(first, Rotation.identity);
      final reference = calibration.reference;
      expect(calibration.referenceSource, OrientationSource.systemFusion);

      final resumed = MotionProcessor(
        SimulatedSensors.hardware,
        calibration: calibration,
      )..deadZoneDegrees = 0;
      final tipped = Rotation.axisAngle(xAxis, 0.3);
      feedPose(resumed, 9000000, tipped);
      expect(calibration.reference, same(reference));
      expect(
        resumed.frameAt(9000000)!.orientation.angleTo(tipped),
        lessThan(1e-6),
      );

      final fallbackOnly = MotionProcessor(
        const SensorCapabilities(
          acceleration: true,
          gyroscope: true,
          systemOrientation: false,
        ),
        calibration: calibration,
      );
      for (var t = 0; t <= 20000; t += 10000) {
        fallbackOnly
          ..ingest(
            SensorReading.vector(
              SensorKind.acceleration,
              t,
              gravityIn(Rotation.identity),
            ),
            t,
          )
          ..ingest(
            SensorReading.vector(SensorKind.angularVelocity, t, Vec3.zero),
            t,
          );
      }
      expect(calibration.reference, isNull);
      expect(calibration.feedback, MotionProcessor.sourceChangedFeedback);
    });

    test('frames carry linear acceleration and the peak between frames', () {
      final processor = MotionProcessor(SimulatedSensors.hardware);
      final pose = Rotation.axisAngle(yAxis, 0.4);
      feedPose(processor, 0, pose);
      // A 4 m/s² sideways spike lands between two orientation samples.
      processor
        ..ingest(
          SensorReading.vector(
            SensorKind.acceleration,
            4000,
            gravityIn(pose) + const Vec3(4, 0, 0),
          ),
          4000,
        )
        ..ingest(
          const SensorReading.vector(
            SensorKind.angularVelocity,
            5000,
            Vec3(0, 6, 0),
          ),
          5000,
        );
      feedPose(processor, 10000, pose);
      final frame = processor.frameAt(10000)!;
      expect(frame.linearAcceleration!.length, closeTo(0, 1e-9));
      expect(frame.peakLinearAcceleration, closeTo(4, 1e-9));
      expect(frame.peakAngularVelocity, closeTo(6, 1e-9));
      feedPose(processor, 20000, pose);
      expect(
        processor.frameAt(20000)!.peakLinearAcceleration,
        closeTo(0, 1e-9),
      );
      expect(processor.frameAt(20000)!.peakAngularVelocity, 0);
    });
  });

  group('dead zone', () {
    test('rotations inside the dead zone map to identity', () {
      final filter = OrientationFilter();
      final small = Rotation.axisAngle(xAxis, 0.9 * degrees);
      expect(
        filter.update(small, 0, smoothingMs: 0, deadZoneDegrees: 1),
        Rotation.identity,
      );
    });

    test('output is continuous at the dead-zone edge and offset beyond it', () {
      final filter = OrientationFilter();
      final edge = filter.update(
        Rotation.axisAngle(xAxis, 1.0001 * degrees),
        0,
        smoothingMs: 0,
        deadZoneDegrees: 1,
      );
      expect(edge.angleTo(Rotation.identity), lessThan(0.001 * degrees));
      final beyond = filter.update(
        Rotation.axisAngle(xAxis, 10 * degrees),
        10000,
        smoothingMs: 0,
        deadZoneDegrees: 1,
      );
      expect(beyond.angleTo(Rotation.identity), closeTo(9 * degrees, 1e-6));
      expect(
        beyond.angleTo(Rotation.axisAngle(xAxis, 9 * degrees)),
        lessThan(1e-6),
      );
    });

    test('zero dead zone passes rotations through', () {
      final filter = OrientationFilter();
      final small = Rotation.axisAngle(yAxis, 0.2 * degrees);
      expect(
        filter
            .update(small, 0, smoothingMs: 0, deadZoneDegrees: 0)
            .angleTo(small),
        lessThan(1e-9),
      );
    });
  });
}
