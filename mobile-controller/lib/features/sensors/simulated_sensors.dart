import 'dart:async';
import 'dart:math' as math;

import 'package:clock/clock.dart';

import '../../core/motion_math.dart';
import 'gravity_fusion.dart';
import 'sensor_source.dart';

class SimulatedSensors implements SensorSource {
  static const hardware = SensorCapabilities(
    acceleration: true,
    gyroscope: true,
    systemOrientation: true,
  );

  bool moving = false;

  @override
  Future<SensorCapabilities> capabilities() async => hardware;

  @override
  Stream<SensorReading> readings(int requestedHz) {
    late final StreamController<SensorReading> controller;
    Timer? timer;
    controller = StreamController(
      sync: true,
      onListen: () {
        final stopwatch = clock.stopwatch()..start();
        timer = Timer.periodic(Duration(microseconds: 1000000 ~/ requestedHz), (
          _,
        ) {
          for (final reading in sampleAt(
            stopwatch.elapsedMicroseconds,
            moving: moving,
          )) {
            controller.add(reading);
          }
        });
      },
      onCancel: () => timer?.cancel(),
    );
    return controller.stream;
  }

  static List<SensorReading> sampleAt(int timestampUs, {required bool moving}) {
    const axis = Vec3(0, 1, 0);
    final time = timestampUs / 1000000;
    final angle = moving ? 0.35 + 0.9 * math.sin(time * 2) : 0.35;
    final rotation = Rotation.axisAngle(axis, angle);
    final gyro = axis * (moving ? 1.8 * math.cos(time * 2) : 0);
    final acceleration = rotation.inverseUnit.rotate(Vec3.up) * standardGravity;
    return [
      SensorReading.vector(SensorKind.acceleration, timestampUs, acceleration),
      SensorReading.vector(SensorKind.angularVelocity, timestampUs, gyro),
      SensorReading.orientation(timestampUs, rotation),
    ];
  }
}
