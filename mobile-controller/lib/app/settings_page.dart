import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/theme/components.dart';
import '../features/diagnostics/readouts.dart';
import 'controller_settings.dart';
import 'motion_controller.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});

  final MotionController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Configurações')),
    body: ValueListenableBuilder(
      valueListenable: controller.status,
      builder: (context, _, _) {
        final settings = controller.settings;
        final title = Theme.of(context).textTheme.titleMedium;
        return PageBody(
          children: [
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 8,
                children: [
                  Text('Taxa de captura', style: title),
                  const Text(
                    'A frequência real depende do aparelho. Alterar a taxa reinicia a calibração.',
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final hz in ControllerSettings.captureRates)
                        ChoiceChip(
                          label: Text('$hz Hz'),
                          selected: hz == settings.captureHz,
                          onSelected: (selected) {
                            if (!selected) return;
                            controller.updateSettings(
                              settings.copyWith(captureHz: hz),
                            );
                            unawaited(controller.saveSettings());
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Suavização · ${settings.smoothingMs} ms', style: title),
                  const Text(
                    'Aplique após definir a posição neutra. Valores altos deixam a resposta mais lenta.',
                  ),
                  Slider(
                    value: settings.smoothingMs.toDouble(),
                    max: 60,
                    divisions: 20,
                    label: '${settings.smoothingMs} ms',
                    onChanged: (value) => controller.updateSettings(
                      settings.copyWith(smoothingMs: value.round()),
                    ),
                    onChangeEnd: (_) => unawaited(controller.saveSettings()),
                  ),
                  Text(
                    'Zona morta · ${decimal(settings.deadZoneDegrees, 1)}°',
                    style: title,
                  ),
                  const Text(
                    'Ignore pequenas rotações em torno da posição neutra.',
                  ),
                  Slider(
                    value: settings.deadZoneDegrees,
                    max: 3,
                    divisions: 30,
                    label: '${decimal(settings.deadZoneDegrees, 1)}°',
                    onChanged: (value) => controller.updateSettings(
                      settings.copyWith(deadZoneDegrees: value),
                    ),
                    onChangeEnd: (_) => unawaited(controller.saveSettings()),
                  ),
                ],
              ),
            ),
            Panel(
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Feedback háptico'),
                subtitle: const Text(
                  'Confirma a calibração com um toque breve.',
                ),
                value: settings.haptics,
                onChanged: (value) {
                  controller.updateSettings(settings.copyWith(haptics: value));
                  unawaited(controller.saveSettings());
                },
              ),
            ),
          ],
        );
      },
    ),
  );
}
