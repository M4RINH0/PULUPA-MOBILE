import 'package:material_ui/material_ui.dart';

import 'app/pulupa_app.dart';
import 'features/sensors/platform_sensors.dart';
import 'features/sensors/simulated_sensors.dart';

void main() {
  const simulated = bool.fromEnvironment('PULUPA_SIMULATE');
  runApp(PulupaApp(source: simulated ? SimulatedSensors() : PlatformSensors()));
}
