import 'package:material_ui/material_ui.dart';

import '../../app/motion_controller.dart';
import '../../core/theme/components.dart';
import '../../core/theme/pulupa_theme.dart';
import '../diagnostics/readouts.dart';
import 'connection_controller.dart';

class ConnectedPage extends StatelessWidget {
  const ConnectedPage({
    super.key,
    required this.motion,
    required this.connection,
    required this.calibrate,
    required this.openPad,
  });

  final MotionController motion;
  final ConnectionController connection;
  final VoidCallback calibrate;

  /// Opens the full-screen controller with the A and B buttons.
  final VoidCallback openPad;

  @override
  Widget build(BuildContext context) {
    final player = connection.player!;
    final connected = connection.phase == ConnectionPhase.connected;
    return PageBody(
      children: [
        Panel(
          color: PulupaColors.navy,
          child: Column(
            spacing: 10,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Color(player.color),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'Jogador ${player.id}',
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                player.name,
                style: Theme.of(context).textTheme.headlineMedium
                    ?.copyWith(color: Colors.white),
              ),
              Text(
                connected
                    ? 'Conectado ao PC'
                    : connection.phase == ConnectionPhase.retrying
                    ? 'Reconectando…'
                    : 'Conexão encerrada',
                style: const TextStyle(
                  color: PulupaColors.yellow,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        if (connected)
          FilledButton.icon(
            onPressed: openPad,
            icon: const Icon(Icons.sports_esports_rounded),
            label: const Text('Abrir controle'),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 64)),
          ),
        if (connection.error case final error?)
          Panel(
            child: StatusLine(
              icon: Icons.link_off,
              label: 'Conexão',
              detail: error,
              alert: true,
            ),
          ),
        if (connected && connection.sensorDataMissing)
          const Panel(
            child: StatusLine(
              icon: Icons.sensors_off_rounded,
              label: 'Sem dados dos sensores',
              detail: 'O PC está ignorando o movimento até os sensores voltarem.',
              alert: true,
            ),
          ),
        if (connected)
          const Panel(
            child: StatusLine(
              icon: Icons.smart_button_rounded,
              label: 'Botões A e B',
              detail:
                  'Use o controle em tela cheia ou as teclas de volume: − é o A, + é o B. Com a tela bloqueada o movimento continua indo para o PC, mas os botões não. Se fechar o app sem querer, abra de novo em até 3 minutos para voltar à mesma vaga.',
            ),
          ),
        ValueListenableBuilder(
          valueListenable: motion.telemetry,
          builder: (context, _, _) {
            final moving = motion.angularVelocity?.length ?? 0;
            final calibrated = motion.isCalibrated;
            return Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 12,
                children: [
                  StatusLine(
                    icon: calibrated
                        ? Icons.check_circle_outline
                        : Icons.center_focus_strong,
                    label: calibrated
                        ? 'Posição neutra definida'
                        : 'Calibração pendente',
                    detail: calibrated
                        ? connection.acknowledgedCalibration == true
                              ? 'Confirmada pelo PC'
                              : 'Aguardando confirmação'
                        : 'Segure o celular como vai jogar e calibre.',
                  ),
                  Text(
                    'Movimento',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  LinearProgressIndicator(
                    value: (moving / 5).clamp(0.0, 1.0),
                    color: PulupaColors.purple,
                    semanticsLabel: 'Intensidade da rotação',
                  ),
                  Readouts(
                    values: {
                      'RTT médio': '${decimal(connection.rttMean, 1)} ms',
                    },
                  ),
                ],
              ),
            );
          },
        ),
        FilledButton.icon(
          onPressed: calibrate,
          icon: const Icon(Icons.center_focus_strong),
          label: Text(motion.isCalibrated ? 'Recalibrar' : 'Calibrar'),
        ),
        OutlinedButton(
          onPressed: connection.disconnect,
          child: Text(
            connected || connection.busy ? 'Desconectar' : 'Voltar ao início',
          ),
        ),
      ],
    );
  }
}
