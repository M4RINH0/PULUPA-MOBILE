import 'package:flutter/services.dart';

import '../../core/motion_math.dart';
import 'sensor_source.dart';

class PlatformSensors implements SensorSource {
  static const _device = MethodChannel('pulupa/device');
  static const _imu = EventChannel('pulupa/imu');
  static const _buttons = EventChannel('pulupa/buttons');

  /// The volume keys as the game's buttons while listened to: volume − is
  /// `a`, volume + is `b`. While listening the keys no longer change the
  /// volume. Android only; elsewhere the stream fails with
  /// MissingPluginException.
  static Stream<({String button, bool pressed})> volumeButtons() => _buttons
      .receiveBroadcastStream()
      .where(
        (event) =>
            event is List &&
            event.length == 2 &&
            (event[0] == 'a' || event[0] == 'b') &&
            event[1] is bool,
      )
      .map((event) {
        final values = event as List;
        return (button: values[0] as String, pressed: values[1] as bool);
      });

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

  /// Starts or stops the native foreground service that keeps sensors and
  /// Wi-Fi running while the screen is locked mid-game.
  static Future<void> setBackgroundSession(bool enabled) =>
      _device.invokeMethod<void>('setBackgroundSession', enabled);

  /// Sends the app to the background without closing it (back button while
  /// a game is connected).
  static Future<bool> moveToBackground() async =>
      await _device.invokeMethod<bool>('moveToBackground') ?? false;

  static Future<String?> loadSession() =>
      _device.invokeMethod<String>('loadSession');

  static Future<void> saveSession(String? encoded) =>
      _device.invokeMethod<void>('saveSession', encoded);

  static Future<void> setKeepScreenOn(bool enabled) =>
      _device.invokeMethod<void>('setKeepScreenOn', enabled);
}
