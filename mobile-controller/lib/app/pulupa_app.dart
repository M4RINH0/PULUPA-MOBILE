import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/theme/pulupa_theme.dart';
import '../features/calibration/calibration_page.dart';
import '../features/diagnostics/lab_page.dart';
import '../features/home/home_page.dart';
import '../features/pairing/pairing_page.dart';
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
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _controller = MotionController(widget.source);
    unawaited(_controller.initialize());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _select(int page) => setState(() => _page = page);

  void _openLab() => _select(2);

  void _openPairing() {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (context) => PairingPage(
            controller: _controller,
            openLab: () {
              Navigator.of(context).pop();
              _openLab();
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
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
      2 => LabPage(controller: _controller),
      _ => HomePage(
        controller: _controller,
        connect: _openPairing,
        openLab: _openLab,
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
