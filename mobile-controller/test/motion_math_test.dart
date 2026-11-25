import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pulupa_controller/core/motion_math.dart';
import 'package:pulupa_controller/features/calibration/calibration.dart';

const x = Vec3(1, 0, 0);
const y = Vec3(0, 1, 0);

void expectVector(Vec3 actual, Vec3 expected) {
  expect(actual.x, closeTo(expected.x, 1e-9));
  expect(actual.y, closeTo(expected.y, 1e-9));
  expect(actual.z, closeTo(expected.z, 1e-9));
}

void main() {
  test('Hamilton composition applies the right operand first', () {
    final a = Rotation.axisAngle(x, math.pi / 2);
    final b = Rotation.axisAngle(y, math.pi / 2);
    expectVector((a * b).rotate(Vec3.up), a.rotate(b.rotate(Vec3.up)));
    expectVector((a * b).rotate(Vec3.up), x);
    expectVector((b * a).rotate(Vec3.up), y * -1);
  });

  test(
    'relative rotation is resolved in the neutral pose for noncommuting axes',
    () {
      final reference = Rotation.axisAngle(x, math.pi / 2);
      final localDelta = Rotation.axisAngle(y, math.pi / 4);
      final current = reference * localDelta;
      final relative = (reference.inverseUnit * current).normalized();
      expect(relative.angleTo(localDelta), closeTo(0, 1e-7));
      expect(relative.eulerDegrees.pitch, closeTo(45, 1e-9));
      expect(relative.eulerDegrees.roll, closeTo(0, 1e-9));
      expect(relative.eulerDegrees.yaw, closeTo(0, 1e-9));
    },
  );

  test('coordinate conversion agrees for vectors and rotations', () {
    expectVector(vectorInGameAxes(x), x);
    expectVector(vectorInGameAxes(y), Vec3.up * -1);
    expectVector(vectorInGameAxes(Vec3.up), y);
    final q = Rotation.axisAngle(Vec3(1, 2, 3), 1.1);
    final v = const Vec3(4, -2, 8);
    expectVector(
      rotationInGameAxes(q).rotate(vectorInGameAxes(v)),
      vectorInGameAxes(q.rotate(v)),
    );
  });

  test('opposite quaternion signs represent the same pose', () {
    final q = Rotation.axisAngle(y, 1);
    final negative = Rotation(-q.x, -q.y, -q.z, -q.w);
    expect(q.slerp(negative, 0.5).angleTo(q), closeTo(0, 1e-7));
    expectVector(
      Rotation.between(Vec3.up * -1, Vec3.up).rotate(Vec3.up * -1),
      Vec3.up,
    );
  });

  test(
    'dead zone suppresses small rotations and smoothing follows sample time',
    () {
      final filter = OrientationFilter();
      final halfDegree = Rotation.axisAngle(x, math.pi / 360);
      final big = Rotation.axisAngle(x, math.pi / 2);
      expect(
        filter.update(halfDegree, 0, smoothingMs: 20, deadZoneDegrees: 1),
        Rotation.identity,
      );
      final smoothed = filter.update(
        big,
        20000,
        smoothingMs: 20,
        deadZoneDegrees: 0,
      );
      expect(
        smoothed.eulerDegrees.roll,
        closeTo(0.5 + (90 - 0.5) * (1 - math.exp(-1)), 1e-8),
      );
      final bypass = filter.update(
        big,
        30000,
        smoothingMs: 0,
        deadZoneDegrees: 0,
      );
      expect(bypass.eulerDegrees.roll, closeTo(90, 1e-8));
    },
  );

  group('holding postures (portrait upright and sideways landscape)', () {
    const degree = math.pi / 180;
    const z = Vec3(0, 0, 1);
    // Device X right, Y top, Z screen; world X east, Y north, Z up.
    // Portrait upright, screen toward a player who faces north.
    final portrait = Rotation.axisAngle(x, 90 * degree);
    // Same, turned sideways: device top to the player's left.
    final landscape = Rotation.axisAngle(y, -90 * degree) * portrait;

    for (final facing in [0.0, 37.0, -120.0]) {
      final world = Rotation.axisAngle(z, facing * degree);
      for (final (name, hold) in [('portrait', portrait), ('landscape', landscape)]) {
        final reference = world * hold;
        final forwardAxis = world.rotate(y);
        final rightAxis = world.rotate(x);
        ({double forward, double roll, double yaw}) anglesAfter(Rotation move) =>
            gameAnglesDegrees(
              rotationInGameAxes(
                gravityAlignedRelative(reference, move * reference),
              ),
            );

        test('$name facing $facing°: heading follows the back of the phone', () {
          expect(headingOf(reference).angleTo(world), lessThan(1e-6));
        });

        test('$name facing $facing°: turn, steer and tilt land on their own axes', () {
          final turn = anglesAfter(Rotation.axisAngle(z, -20 * degree));
          expect(turn.yaw, closeTo(20, 1e-6));
          expect(turn.roll, closeTo(0, 1e-6));
          expect(turn.forward, closeTo(0, 1e-6));

          final steer = anglesAfter(Rotation.axisAngle(forwardAxis, 15 * degree));
          expect(steer.roll, closeTo(15, 1e-6));
          expect(steer.yaw, closeTo(0, 1e-6));
          expect(steer.forward, closeTo(0, 1e-6));

          final tilt = anglesAfter(Rotation.axisAngle(rightAxis, -15 * degree));
          expect(tilt.forward, closeTo(15, 1e-6));
          expect(tilt.roll, closeTo(0, 1e-6));
          expect(tilt.yaw, closeTo(0, 1e-6));
        });
      }
    }

    test('preview pose shows how the phone is held', () {
      expect(
        poseInGameAxes(portrait, headingOf(portrait)).angleTo(Rotation.identity),
        lessThan(1e-6),
      );
      // Top to the left: a quarter turn about the axis toward the player.
      expect(
        poseInGameAxes(landscape, headingOf(landscape))
            .angleTo(Rotation.axisAngle(z, 90 * degree)),
        lessThan(1e-6),
      );
    });
  });
}
