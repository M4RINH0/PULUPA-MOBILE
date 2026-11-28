import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/motion_math.dart';
import '../core/theme/pulupa_theme.dart';
import '../features/calibration/calibration_page.dart';
import '../features/connection/connected_page.dart';
import '../features/connection/connection_controller.dart';
import '../features/controls/controller_pad_page.dart';
import '../features/diagnostics/lab_page.dart';
import '../features/home/home_page.dart';
import '../features/pairing/pairing_page.dart';
import '../features/sensors/platform_sensors.dart';
import '../features/sensors/sensor_source.dart';
import 'motion_controller.dart';
import 'settings_page.dart';

class PulupaApp extends StatelessWidget {
  const PulupaApp({super.key, required this.source});

  final SensorSource source;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PULUPA Controller',
    debugShowCheckedModeBanner: false,
    theme: pulupaTheme(),
    locale: const Locale('pt', 'BR'),
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    supportedLocales: const [Locale('pt', 'BR')],
    home: _ControllerShell(source: source),
  );
}

class _ControllerShell extends StatefulWidget {
  const _ControllerShell({required this.source});
  final SensorSource source;

  @override
  State<_ControllerShell> createState() => _ControllerShellState();
}

class _ControllerShellState extends State<_ControllerShell> {
  late final MotionController _controller;
  late final ConnectionController _connection;
  int _page = 0;
  bool? _live;
  StreamSubscription<({String button, bool pressed})>? _volumeKeys;

  @override
  void initState() {
    super.initState();
    _controller = MotionController(widget.source);
    _connection = ConnectionController(
      latestFrame: () => _controller.latestMotionFrame,
      isCalibrated: () => _controller.isCalibrated,
      onFeedback: _controller.feedback,
      onSessionChanged: _persistSession,
    );
    _controller.status.addListener(_applySendRate);
    _controller.status.addListener(_saveCalibrationChange);
    _connection.addListener(_applyLiveSession);
    unawaited(_controller.initialize());
    unawaited(_restoreSession());
  }

  Rotation? _savedReference;

  /// The neutral tilt travels with the session so a reopened app comes back
  /// calibrated.
  void _persistSession(SavedSession? session) {
    final pose = _controller.neutralPose;
    final value = session?.withNeutral(pose?.tilt, pose?.source.name);
    _savedReference = _controller.calibration?.reference;
    unawaited(_native(() => PlatformSensors.saveSession(value?.encode())));
  }

  void _saveCalibrationChange() {
    final reference = _controller.calibration?.reference;
    if (identical(reference, _savedReference)) return;
    _savedReference = reference;
    _connection.saveNow();
  }

  /// A game is live, or being recovered, with a known player slot.
  bool get _hasLiveGame =>
      _connection.player != null &&
      (_connection.phase == ConnectionPhase.connected ||
          _connection.phase == ConnectionPhase.connecting ||
          _connection.phase == ConnectionPhase.retrying);

  /// While a game is live: the screen stays on, and the foreground service
  /// plus background capture keep sending motion if the player locks the
  /// screen (to avoid accidental touches) or leaves the app.
  void _applyLiveSession() {
    final enabled = _hasLiveGame;
    if (_live == enabled) return;
    _live = enabled;
    _controller.keepCaptureInBackground = enabled;
    unawaited(_native(() => PlatformSensors.setKeepScreenOn(enabled)));
    unawaited(_native(() => PlatformSensors.setBackgroundSession(enabled)));
    _listenVolumeKeys(enabled);
    if (mounted) setState(() {});
  }

  /// While a game is live the volume keys are the game's buttons (− is A,
  /// + is B) and stop changing the volume.
  void _listenVolumeKeys(bool enabled) {
    if (!enabled) {
      unawaited(_volumeKeys?.cancel());
      _volumeKeys = null;
      _connection.releaseButtons(source: 'volume');
      return;
    }
    _volumeKeys ??= PlatformSensors.volumeButtons().listen(
      (key) => _connection.setButton(key.button, key.pressed, source: 'volume'),
      // No native channel (tests, other platforms): the screen buttons remain.
      onError: (Object _) {},
    );
  }

  void _openPad() => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) =>
          ControllerPadPage(motion: _controller, connection: _connection),
    ),
  );

  /// Rejoins the slot if the app was closed mid-game within the server's
  /// reservation window.
  Future<void> _restoreSession() async {
    String? raw;
    try {
      raw = await PlatformSensors.loadSession();
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
    final saved = SavedSession.decode(raw);
    if (!mounted || saved == null) return;
    if (!saved.isFresh(DateTime.now())) {
      unawaited(_native(() => PlatformSensors.saveSession(null)));
      return;
    }
    if (_connection.phase != ConnectionPhase.idle) return;
    _connection.resumeSaved(saved);
    final tilt = saved.neutralTilt;
    final source = OrientationSource.values
        .where((value) => value.name == saved.neutralSource)
        .firstOrNull;
    if (tilt != null && source != null) {
      _controller.restoreNeutral(tilt, source);
    }
  }

  /// Native calls are conveniences; they never break the session, and tests
  /// run without the channel.
  static Future<void> _native(Future<void> Function() call) async {
    try {
      await call();
    } on MissingPluginException {
      // Tests and platforms without the native channel.
    } on PlatformException {
      // Ignored on purpose.
    }
  }

  void _applySendRate() =>
      _connection.updateSendRate(_controller.settings.sendHz);

  @override
  void dispose() {
    _controller.status.removeListener(_applySendRate);
    _controller.status.removeListener(_saveCalibrationChange);
    _connection.removeListener(_applyLiveSession);
    unawaited(_volumeKeys?.cancel());
    if (_live == true) {
      unawaited(_native(() => PlatformSensors.setKeepScreenOn(false)));
      unawaited(_native(() => PlatformSensors.setBackgroundSession(false)));
    }
    _connection.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _select(int page) => setState(() => _page = page);

  void _openLab() => _select(2);

  Future<void> _openPairing() async {
    final paired = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            PairingPage(motion: _controller, connection: _connection),
      ),
    );
    if (!mounted) return;
    if (paired == true) {
      _select(0);
    } else if (_connection.player == null) {
      // Leaving the pairing page cancels a pairing still in progress, but
      // never a connection that already succeeded (the page may be popped
      // by the back button just as the welcome arrives).
      _connection.disconnect();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    // Back with a live game minimizes instead of closing, so a stray press
    // does not drop the player.
    canPop: !_hasLiveGame,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) {
        unawaited(_native(() async => PlatformSensors.moveToBackground()));
      }
    },
    child: _shell(context),
  );

  Widget _shell(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(switch (_page) {
        1 => 'Calibração',
        2 => 'Laboratório',
        _ => 'Controle de movimento',
      }),
      actions: [
        IconButton(
          tooltip: 'Configurações',
          icon: const Icon(Icons.tune_rounded),
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => SettingsPage(controller: _controller),
            ),
          ),
        ),
        const SizedBox(width: 8),
      ],
    ),
    body: switch (_page) {
      1 => CalibrationPage(controller: _controller),
      2 => LabPage(controller: _controller, connection: _connection),
      _ => ListenableBuilder(
        listenable: _connection,
        builder: (context, _) => _connection.player == null
            ? HomePage(
                controller: _controller,
                connect: _openPairing,
                openLab: _openLab,
              )
            : ConnectedPage(
                motion: _controller,
                connection: _connection,
                calibrate: () => _select(1),
                openPad: _openPad,
              ),
      ),
    },
    bottomNavigationBar: NavigationBar(
      selectedIndex: _page,
      onDestinationSelected: _select,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          selectedIcon: Icon(Icons.home_rounded),
          label: 'Início',
        ),
        NavigationDestination(
          icon: Icon(Icons.center_focus_weak_rounded),
          selectedIcon: Icon(Icons.center_focus_strong_rounded),
          label: 'Calibrar',
        ),
        NavigationDestination(
          icon: Icon(Icons.science_outlined),
          selectedIcon: Icon(Icons.science_rounded),
          label: 'Laboratório',
        ),
      ],
    ),
  );
}
