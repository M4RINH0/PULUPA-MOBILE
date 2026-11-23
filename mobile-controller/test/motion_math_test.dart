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
}
