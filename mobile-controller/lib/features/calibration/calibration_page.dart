import 'package:material_ui/material_ui.dart';

import '../../app/motion_controller.dart';
import '../../core/theme/components.dart';
import '../diagnostics/phone_model.dart';
import '../diagnostics/readouts.dart';
import 'calibration.dart';

class CalibrationPage extends StatelessWidget {
  const CalibrationPage({super.key, required this.controller});

  final MotionController controller;

  @override
  Widget build(BuildContext context) => PageBody(
    children: [
      PhoneModel(rotation: controller.preview),
      ValueListenableBuilder(
        valueListenable: controller.telemetry,
        builder: (context, _, _) {
          final calibration = controller.calibration;
          final hardware = controller.capabilities;
          final phase = calibration?.phase ?? CalibrationPhase.idle;
          final collecting = phase == CalibrationPhase.collecting;
          final calibrated = calibration?.reference != null;
          final missing = hardware != null && !hardware.canCalibrate;
          final canCalibrate = controller.canCalibrate;
          final label = switch (phase) {
            CalibrationPhase.collecting => 'Medindo…',
            CalibrationPhase.accepted => 'Posição neutra definida',
            CalibrationPhase.rejected => 'Medição interrompida',
            CalibrationPhase.idle when missing => 'Sensores indisponíveis',
            CalibrationPhase.idle when !canCalibrate => 'Aguardando leituras',
            CalibrationPhase.idle when calibration?.feedback != null =>
              'Recalibre a posição neutra',
            _ => 'Defina sua posição neutra',
          };
          final detail = switch (phase) {
            CalibrationPhase.collecting =>
              calibration?.feedback ??
                  'Mantenha o celular firme na posição de jogo.',
            CalibrationPhase.accepted =>
              'O modelo agora acompanha o movimento a partir dessa posição.',
            CalibrationPhase.rejected =>
              calibrated
                  ? '${calibration?.feedback ?? ''} A referência anterior segue ativa.'
                  : calibration?.feedback ?? 'Tente novamente.',
            CalibrationPhase.idle when missing =>
              'A calibração precisa de acelerômetro e giroscópio.',
            CalibrationPhase.idle when !canCalibrate =>
              controller.error ??
                  'Segure o aparelho e aguarde o sinal dos sensores.',
            _ => calibration?.feedback ?? 'Segure o celular como vai jogar (em pé ou deitado de lado) e mantenha-o firme por um instante.',
          };
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    StatusLine(
                      icon: calibrated
                          ? Icons.check_circle_outline_rounded
                          : Icons.track_changes_rounded,
                      label: label,
                      detail: detail,
                      alert: missing || phase == CalibrationPhase.rejected,
                    ),
                    if (canCalibrate && !collecting)
                      Text(
                        controller.stationary
                            ? 'Leituras estáveis'
                            : 'Movimento detectado',
                      ),
                    if (collecting)
                      LinearProgressIndicator(
                        value: calibration?.progress ?? 0,
                        semanticsLabel: 'Progresso da calibração',
                      ),
                  ],
                ),
              ),
              FilledButton.icon(
                onPressed: canCalibrate && !collecting
                    ? controller.startCalibration
                    : null,
                icon: const Icon(Icons.center_focus_strong_rounded),
                label: Text(
                  calibrated ? 'Recalibrar' : 'Calibrar e centralizar',
                ),
              ),
              if (calibrated && !collecting)
                TextButton(
                  onPressed: controller.clearCalibration,
                  child: const Text('Limpar posição neutra'),
                ),
              OrientationReadout(orientation: controller.gameOrientation),
            ],
          );
        },
      ),
    ],
  );
}
