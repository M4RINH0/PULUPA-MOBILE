import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../core/motion_math.dart';
import '../features/calibration/calibration.dart';
import '../features/sensors/motion_processor.dart';
import '../features/sensors/platform_sensors.dart';
import '../features/sensors/sensor_source.dart';
import '../features/sensors/simulated_sensors.dart';
import 'controller_settings.dart';

class MotionController with WidgetsBindingObserver {
  MotionController(this.source);

  final SensorSource source;
  final status = ValueNotifier<int>(0);
  final telemetry = ValueNotifier<int>(0);
  final preview = ValueNotifier<Rotation>(Rotation.identity);
  final _clock = clock.stopwatch()..start();
  final _wifiClock = clock.stopwatch()..start();

  ControllerSettings settings = const ControllerSettings();
  SensorCapabilities? capabilities;
  String? error;
  bool? wifi;
  MotionProcessor? _processor;
  StreamSubscription<SensorReading>? _subscription;
  Timer? _renderTimer;
  Future<void> _transition = Future.value();
  int _generation = 0;
  int _ticks = 0;
  bool _disposed = false;
  bool _ready = false;
  bool _foreground = true;
  bool _checkingWifi = false;

  SimulatedSensors? get simulator => switch (source) {
    final SimulatedSensors simulator => simulator,
    _ => null,
  };
  Calibration? get calibration => _processor?.calibration;
  OrientationSource get orientationSource =>
      _processor?.orientationSource ?? OrientationSource.unavailable;
  Rotation? get orientation =>
      _processor?.orientationAt(_clock.elapsedMicroseconds);
  Vec3? get acceleration =>
      _processor?.accelerationAt(_clock.elapsedMicroseconds);
  Vec3? get angularVelocity =>
      _processor?.angularVelocityAt(_clock.elapsedMicroseconds);
  double rate(SensorKind kind) =>
      _processor?.rateAt(kind, _clock.elapsedMicroseconds) ?? 0;
  bool get canCalibrate =>
      capabilities?.canCalibrate == true &&
      _processor?.frameAt(_clock.elapsedMicroseconds) != null;
  bool get stationary {
    final a = acceleration;
    final g = angularVelocity;
    return a != null && g != null && Calibration.isStationary(a, g);
  }

  Future<void> initialize() async {
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    _foreground = switch (binding.lifecycleState) {
      AppLifecycleState.paused ||
      AppLifecycleState.hidden ||
      AppLifecycleState.detached => false,
      _ => true,
    };
    try {
      settings = ControllerSettings.fromMap(
        await PlatformSensors.loadSettings(),
      );
    } on PlatformException catch (exception) {
      debugPrint('PULUPA! preferências: ${exception.code}');
    } on MissingPluginException {
      // Simulation can also run without a native bridge.
    }
    if (_disposed) return;
    _ready = true;
    _updateCapture();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = switch (state) {
      AppLifecycleState.resumed => true,
      AppLifecycleState.paused ||
      AppLifecycleState.hidden ||
      AppLifecycleState.detached => false,
      AppLifecycleState.inactive => _foreground,
    };
    if (foreground == _foreground) return;
    _foreground = foreground;
    if (_ready) _updateCapture();
  }

  void _updateCapture() {
    final generation = ++_generation;
    _renderTimer?.cancel();
    _processor = null;
    preview.value = Rotation.identity;
    status.value++;
    telemetry.value++;
    _transition = _transition.then((_) async {
      await _subscription?.cancel();
      _subscription = null;
      if (!_isCurrent(generation) || !_foreground) return;
      error = null;
      try {
        final hardware = await source.capabilities();
        if (!_isCurrent(generation)) return;
        capabilities = hardware;
        final processor = MotionProcessor(hardware)
          ..smoothingMs = settings.smoothingMs
          ..deadZoneDegrees = settings.deadZoneDegrees;
        _processor = processor;
        _subscription = source
            .readings(settings.captureHz)
            .listen(
              (reading) {
                if (!_isCurrent(generation)) return;
                final before = processor.calibration.phase;
                final now = _clock.elapsedMicroseconds;
                if (before == CalibrationPhase.collecting &&
                    processor.frameAt(now) == null) {
                  processor.calibration.interrupt();
                }
                processor.ingest(reading, now);
                if (before == CalibrationPhase.collecting &&
                    processor.calibration.phase == CalibrationPhase.accepted &&
                    settings.haptics) {
                  unawaited(HapticFeedback.lightImpact());
                }
              },
              onError: (Object failure) => _captureFailed(generation, failure),
              onDone: () => _captureFailed(generation, 'stream closed'),
              cancelOnError: true,
            );
      } on Object catch (failure) {
        _captureFailed(generation, failure);
      }
      if (!_isCurrent(generation)) return;
      _ticks = 0;
      _renderTimer = Timer.periodic(
        const Duration(milliseconds: 33),
        (_) => _render(),
      );
      status.value++;
      unawaited(_refreshWifi());
    });
  }

  bool _isCurrent(int generation) => !_disposed && _generation == generation;

  void _captureFailed(int generation, Object failure) {
    if (!_isCurrent(generation)) return;
    debugPrint('PULUPA! sensores: $failure');
    error = 'Não foi possível iniciar ou manter a captura dos sensores.';
    _processor = null;
    preview.value = Rotation.identity;
    status.value++;
    telemetry.value++;
  }

  void _render() {
    final processor = _processor;
    final time = _clock.elapsedMicroseconds;
    if (processor != null) {
      if (processor.frameAt(time) == null) processor.calibration.interrupt();
      preview.value = processor.orientationAt(time) ?? Rotation.identity;
    }
    if (++_ticks % 3 == 0) telemetry.value++;
    if (_wifiClock.elapsed >= const Duration(seconds: 4)) {
      unawaited(_refreshWifi());
    }
  }

  Future<void> _refreshWifi() async {
    if (_checkingWifi) return;
    _checkingWifi = true;
    _wifiClock.reset();
    bool? result;
    try {
      result = await PlatformSensors.wifiConnected();
    } on PlatformException {
      // The UI represents an unknown Wi-Fi state explicitly.
    } on MissingPluginException {
      // The simulator is platform-independent.
    } finally {
      _checkingWifi = false;
    }
    if (!_disposed && result != wifi) {
      wifi = result;
      status.value++;
    }
  }

  void startCalibration() {
    if (!canCalibrate) return;
    calibration!.start();
    telemetry.value++;
  }

  void clearCalibration() {
    _processor?.clearCalibration();
    telemetry.value++;
  }

  void setSimulationMotion(bool moving) {
    simulator?.moving = moving;
    telemetry.value++;
  }

  void retryCapture() {
    if (_ready && _foreground) _updateCapture();
  }

  void updateSettings(ControllerSettings value) {
    final captureChanged = settings.captureHz != value.captureHz;
    settings = value;
    _processor
      ?..smoothingMs = value.smoothingMs
      ..deadZoneDegrees = value.deadZoneDegrees;
    if (captureChanged && _ready) _updateCapture();
    status.value++;
  }

  Future<void> saveSettings() async {
    try {
      await PlatformSensors.saveSettings(settings.toMap());
    } on PlatformException catch (exception) {
      debugPrint('PULUPA! preferências: ${exception.code}');
    } on MissingPluginException {
      // Settings still apply in memory.
    }
  }

  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _renderTimer?.cancel();
    unawaited(_subscription?.cancel());
    status.dispose();
    telemetry.dispose();
    preview.dispose();
  }
}
