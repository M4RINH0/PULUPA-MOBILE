import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app/pulupa_app.dart';
import 'features/sensors/platform_sensors.dart';
import 'features/sensors/simulated_sensors.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // O celular é inclinado durante o jogo; a interface não deve girar junto.
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  const simulated = bool.fromEnvironment('PULUPA_SIMULATE');
  runApp(PulupaApp(source: simulated ? SimulatedSensors() : PlatformSensors()));
}
