import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulupa_controller/app/controller_settings.dart';
import 'package:pulupa_controller/app/motion_controller.dart';
import 'package:pulupa_controller/features/calibration/calibration.dart';
import 'package:pulupa_controller/features/sensors/device_bridge.dart';
import 'package:pulupa_controller/features/sensors/simulated_sensors.dart';

class FakeDeviceBridge implements DeviceBridge {
  FakeDeviceBridge({Future<Map<String, Object?>>? stored})
    : stored = stored ?? Future.value(const {'haptics': false});

  final Future<Map<String, Object?>> stored;
  final saved = <Map<String, Object>>[];
  final keepScreenOn = <bool>[];

  @override
  Future<Map<String, Object?>> loadSettings() => stored;

  @override
  Future<void> saveSettings(Map<String, Object> values) async =>
      saved.add(values);

  @override
  Future<bool?> wifiConnected() async => true;

  @override
  Future<String?> deviceLabel() async => 'Telefone de teste';

  @override
  Future<void> setKeepScreenOn(bool enabled) async => keepScreenOn.add(enabled);
}

Future<void> advance(WidgetTester tester, int ticks) async {
  for (var tick = 0; tick < ticks; tick++) {
    await tester.pump(const Duration(milliseconds: 40));
  }
}

/// Stream cancellation completes through a root-zone future, which fake
/// async does not flush; let the real event loop run once.
Future<void> settleCapture(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await tester.pump();
}

void setLifecycle(MotionController controller, AppLifecycleState state) =>
    controller.didChangeAppLifecycleState(state);

Future<MotionController> calibratedController(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  final controller = MotionController(
    SimulatedSensors(),
    device: FakeDeviceBridge(),
  );
  await controller.initialize();
  await advance(tester, 4);
  expect(controller.canCalibrate, isTrue);
  controller.startCalibration();
  await advance(tester, 55);
  expect(controller.calibration!.phase, CalibrationPhase.accepted);
  expect(controller.isCalibrated, isTrue);
  return controller;
}

void main() {
  group('ControllerSettings.fromMap', () {
    test('accepts valid values', () {
      final settings = ControllerSettings.fromMap(const {
        'captureHz': 50,
        'sendHz': 30,
        'smoothingMs': 40,
        'deadZoneDegrees': 1.5,
        'haptics': false,
      });
      expect(settings.toMap(), {
        'captureHz': 50,
        'sendHz': 30,
        'smoothingMs': 40,
        'deadZoneDegrees': 1.5,
        'haptics': false,
      });
    });

    test('clamps ranges and falls back on unsupported values', () {
      final settings = ControllerSettings.fromMap(const {
        'captureHz': 75,
        'sendHz': 1000,
        'smoothingMs': 500,
        'deadZoneDegrees': -4,
        'haptics': 'yes',
      });
      expect(settings.captureHz, 100);
      expect(settings.sendHz, 60);
      expect(settings.smoothingMs, 60);
      expect(settings.deadZoneDegrees, 0);
      expect(settings.haptics, isTrue);
      expect(
        ControllerSettings.fromMap(const {
          'smoothingMs': -3,
          'deadZoneDegrees': 9,
        }),
        isA<ControllerSettings>()
            .having((s) => s.smoothingMs, 'smoothingMs', 0)
            .having((s) => s.deadZoneDegrees, 'deadZoneDegrees', 3),
      );
    });

    test('rejects wrong types and non-finite numbers', () {
      final settings = ControllerSettings.fromMap(const {
        'captureHz': '100',
        'sendHz': 60.0,
        'smoothingMs': 12.5,
        'deadZoneDegrees': double.nan,
        'haptics': null,
      });
      expect(settings.captureHz, 100);
      expect(settings.sendHz, 60);
      expect(settings.smoothingMs, 18);
      expect(settings.deadZoneDegrees, 0.5);
      expect(settings.haptics, isTrue);
      expect(
        ControllerSettings.fromMap(const {'deadZoneDegrees': double.infinity})
            .deadZoneDegrees,
        0.5,
      );
      expect(
        ControllerSettings.fromMap(const {}).toMap(),
        const ControllerSettings().toMap(),
      );
    });
  });

  testWidgets('settings changed while loading are not overwritten', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final stored = Completer<Map<String, Object?>>();
    final controller = MotionController(
      SimulatedSensors(),
      device: FakeDeviceBridge(stored: stored.future),
    );
    final initialized = controller.initialize();
    controller.updateSettings(controller.settings.copyWith(smoothingMs: 40));
    stored.complete(const {'smoothingMs': 5, 'haptics': false});
    await initialized;
    expect(controller.settings.smoothingMs, 40);
    expect(controller.settings.haptics, isTrue);
    controller.dispose();
    await tester.pump();
  });

  testWidgets('stored settings apply when nothing changed during loading', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final device = FakeDeviceBridge(
      stored: Future.value(const {'smoothingMs': 5}),
    );
    final controller = MotionController(SimulatedSensors(), device: device);
    await controller.initialize();
    expect(controller.settings.smoothingMs, 5);
    await controller.saveSettings();
    expect(device.saved.single['smoothingMs'], 5);
    controller.dispose();
    await tester.pump();
  });

  testWidgets('calibration survives pause and resume', (tester) async {
    final controller = await calibratedController(tester);
    final reference = controller.calibration!.reference;

    setLifecycle(controller, AppLifecycleState.inactive);
    setLifecycle(controller, AppLifecycleState.paused);
    await settleCapture(tester);
    await advance(tester, 2);
    expect(controller.latestMotionFrame, isNull);
    // The connection reports this flag to the PC; a pause must not flip it.
    expect(controller.isCalibrated, isTrue);

    await advance(tester, 50);
    setLifecycle(controller, AppLifecycleState.resumed);
    await settleCapture(tester);
    await advance(tester, 4);
    expect(controller.isCalibrated, isTrue);
    expect(controller.calibration!.reference, same(reference));
    expect(controller.latestMotionFrame, isNotNull);

    controller.dispose();
    await tester.pump();
  });

  testWidgets('a pause interrupts a calibration in progress', (tester) async {
    final controller = await calibratedController(tester);
    controller.startCalibration();
    await advance(tester, 5);
    setLifecycle(controller, AppLifecycleState.paused);
    await settleCapture(tester);
    expect(controller.calibration!.phase, CalibrationPhase.rejected);
    expect(controller.isCalibrated, isTrue);
    controller.dispose();
    await tester.pump();
  });

  testWidgets('changing the capture rate or clearing drops the reference', (
    tester,
  ) async {
    final controller = await calibratedController(tester);
    controller.updateSettings(controller.settings.copyWith(captureHz: 50));
    await settleCapture(tester);
    await advance(tester, 4);
    expect(controller.isCalibrated, isFalse);

    controller.startCalibration();
    await advance(tester, 55);
    expect(controller.isCalibrated, isTrue);
    setLifecycle(controller, AppLifecycleState.paused);
    await settleCapture(tester);
    controller.clearCalibration();
    expect(controller.isCalibrated, isFalse);
    controller.dispose();
    await tester.pump();
  });
}
