import 'platform_sensors.dart';

/// Native device services used by the motion controller. Tests inject fakes.
abstract interface class DeviceBridge {
  Future<Map<String, Object?>> loadSettings();
  Future<void> saveSettings(Map<String, Object> values);
  Future<bool?> wifiConnected();
  Future<String?> deviceLabel();
  Future<void> setKeepScreenOn(bool enabled);
}

class PlatformDeviceBridge implements DeviceBridge {
  const PlatformDeviceBridge();

  @override
  Future<Map<String, Object?>> loadSettings() => PlatformSensors.loadSettings();

  @override
  Future<void> saveSettings(Map<String, Object> values) =>
      PlatformSensors.saveSettings(values);

  @override
  Future<bool?> wifiConnected() => PlatformSensors.wifiConnected();

  @override
  Future<String?> deviceLabel() => PlatformSensors.deviceLabel();

  @override
  Future<void> setKeepScreenOn(bool enabled) =>
      PlatformSensors.setKeepScreenOn(enabled);
}
