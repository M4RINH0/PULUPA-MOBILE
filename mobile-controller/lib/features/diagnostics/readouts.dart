import 'package:material_ui/material_ui.dart';

import '../../core/motion_math.dart';
import '../../core/theme/components.dart';
import '../../core/theme/pulupa_theme.dart';
import '../sensors/sensor_source.dart';

String orientationSourceLabel(OrientationSource source) => switch (source) {
  OrientationSource.systemFusion => 'Fusão nativa do sistema',
  OrientationSource.gyroscopeGravity => 'Giroscópio + gravidade',
  OrientationSource.unavailable => 'Sem fonte de orientação',
};

String decimal(double? value, [int digits = 2]) =>
    value?.toStringAsFixed(digits).replaceAll('.', ',') ?? '—';

class Readouts extends StatelessWidget {
  const Readouts({super.key, required this.values});

  final Map<String, String> values;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final entry in values.entries)
        DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xFFEEF1FF),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: '${entry.key} ',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  TextSpan(
                    text: entry.value,
                    style: const TextStyle(color: PulupaColors.navy),
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

class OrientationReadout extends StatelessWidget {
  const OrientationReadout({
    super.key,
    required this.orientation,
    this.quaternion = false,
  });

  final Rotation? orientation;
  final bool quaternion;

  @override
  Widget build(BuildContext context) {
    final value = orientation;
    final angles = value == null ? null : gameAnglesDegrees(value);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Text('Orientação', style: Theme.of(context).textTheme.titleMedium),
          Readouts(
            values: {
              'Frente/trás': '${decimal(angles?.forward, 1)}°',
              'Balanço': '${decimal(angles?.roll, 1)}°',
              'Giro': '${decimal(angles?.yaw, 1)}°',
            },
          ),
          Text(
            'Frente, lado direito para baixo e giro para a direita são positivos.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (quaternion) ...[
            const Text('Quaternion'),
            Readouts(
              values: {
                'X': decimal(orientation?.x, 3),
                'Y': decimal(orientation?.y, 3),
                'Z': decimal(orientation?.z, 3),
                'W': decimal(orientation?.w, 3),
              },
            ),
          ],
        ],
      ),
    );
  }
}
