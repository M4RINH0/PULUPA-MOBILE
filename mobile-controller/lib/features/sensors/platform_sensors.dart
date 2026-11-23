import 'package:flutter/services.dart';

import '../../core/motion_math.dart';
import 'sensor_source.dart';

class PlatformSensors implements SensorSource {
  static const _device = MethodChannel('pulupa/device');
  static const _imu = EventChannel('pulupa/imu');

  @override
  Future<SensorCapabilities> capabilities() async {
    final values = await _device.invokeMapMethod<String, bool>('sensors');
    return SensorCapabilities(
      acceleration: values?['accelerometer'] == true,
      gyroscope: values?['gyroscope'] == true,
      systemOrientation: values?['gameRotation'] == true,
    );
  }

  @override
  Stream<SensorReading> readings(int requestedHz) async* {
    await for (final event in _imu.receiveBroadcastStream(requestedHz)) {
      if (event is! List || event.length < 5) continue;
      final kind = event[0];
      final timestamp = event[1];
      if (timestamp is! int) continue;
      final values = event.skip(2);
      if (!values.every((value) => value is num)) continue;
      final x = (event[2] as num).toDouble();
      final y = (event[3] as num).toDouble();
      final z = (event[4] as num).toDouble();
      switch (kind) {
        case 0:
          yield SensorReading.vector(
            SensorKind.acceleration,
            timestamp,
            Vec3(x, y, z),
          );
        case 1:
          yield SensorReading.vector(
            SensorKind.angularVelocity,
            timestamp,
            Vec3(x, y, z),
          );
        case 2 when event.length == 6:
          yield SensorReading.orientation(
            timestamp,
            Rotation(x, y, z, (event[5] as num).toDouble()),
          );
      }
    }
  }

  static Future<bool?> wifiConnected() => _device.invokeMethod<bool>('wifi');

  static Future<String?> deviceLabel() =>
      _device.invokeMethod<String>('deviceLabel');

  static Future<Map<String, Object?>> loadSettings() async =>
      await _device.invokeMapMethod<String, Object?>('loadSettings') ?? {};

  static Future<void> saveSettings(Map<String, Object> values) =>
      _device.invokeMethod<void>('saveSettings', values);
}
