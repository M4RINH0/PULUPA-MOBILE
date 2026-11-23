import 'package:material_ui/material_ui.dart';

import '../../app/motion_controller.dart';
import '../../core/motion_math.dart';
import '../../core/theme/components.dart';
import '../sensors/sensor_source.dart';
import 'phone_model.dart';
import 'readouts.dart';

class LabPage extends StatelessWidget {
  const LabPage({super.key, required this.controller});

  final MotionController controller;

  @override
  Widget build(BuildContext context) => PageBody(
    children: [
      PhoneModel(rotation: controller.preview, height: 210),
      ValueListenableBuilder(
        valueListenable: controller.telemetry,
        builder: (context, _, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 12,
          children: [
            if (controller.simulator case final simulator?)
              Panel(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Simular movimento'),
                  subtitle: const Text(
                    'Desative para testar a calibração estática.',
                  ),
                  value: simulator.moving,
                  onChanged: controller.setSimulationMotion,
                ),
              ),
            _AxisPanel(
              title: 'Acelerômetro · m/s²',
              value: controller.acceleration,
              hz: controller.rate(SensorKind.acceleration),
            ),
            _AxisPanel(
              title: 'Giroscópio · rad/s',
              value: controller.angularVelocity,
              hz: controller.rate(SensorKind.angularVelocity),
            ),
            OrientationReadout(
              orientation: controller.orientation,
              quaternion: true,
            ),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Text(
                    'Fonte e frequência',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    controller.error ??
                        orientationSourceLabel(controller.orientationSource),
                  ),
                  Readouts(
                    values: {
                      'Orientação':
                          '${decimal(controller.rate(SensorKind.orientation), 1)} Hz',
                      'Solicitada': '${controller.settings.captureHz} Hz',
                    },
                  ),
                ],
              ),
            ),
            const Panel(
              child: StatusLine(
                icon: Icons.link_off_rounded,
                label: 'Transmissão para o PC',
                detail: 'Frequência de envio, pacotes, latência, jitter e perda ficam disponíveis após o pareamento.',
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _AxisPanel extends StatelessWidget {
  const _AxisPanel({
    required this.title,
    required this.value,
    required this.hz,
  });

  final String title;
  final Vec3? value;
  final double hz;

  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 8,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        Readouts(
          values: {
            'X': decimal(value?.x),
            'Y': decimal(value?.y),
            'Z': decimal(value?.z),
            'Hz': decimal(hz, 1),
          },
        ),
      ],
    ),
  );
}
