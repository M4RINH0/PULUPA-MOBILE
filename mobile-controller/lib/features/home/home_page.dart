import 'package:material_ui/material_ui.dart';

import '../../app/motion_controller.dart';
import '../../core/motion_math.dart';
import '../../core/theme/components.dart';
import '../../core/theme/pulupa_theme.dart';
import '../diagnostics/phone_model.dart';

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.controller,
    required this.connect,
    required this.openLab,
  });

  final MotionController controller;
  final VoidCallback connect;
  final VoidCallback openLab;

  @override
  Widget build(BuildContext context) => PageBody(
    children: [
      const _Hero(),
      FilledButton.icon(
        onPressed: connect,
        icon: const Icon(Icons.sports_esports_rounded),
        label: const Text('Conectar ao jogo'),
      ),
      ValueListenableBuilder(
        valueListenable: controller.status,
        builder: (context, _, _) {
          final sensors = controller.capabilities;
          final missing = [
            if (sensors?.acceleration == false) 'acelerômetro',
            if (sensors?.gyroscope == false) 'giroscópio',
          ];
          return Panel(
            child: Column(
              spacing: 14,
              children: [
                StatusLine(
                  icon: Icons.sensors_rounded,
                  label: 'Sensores',
                  detail:
                      controller.error ??
                      (sensors == null
                          ? 'Verificando o aparelho…'
                          : missing.isNotEmpty
                          ? 'Indisponível: ${missing.join(' e ')}.'
                          : controller.simulator == null
                          ? 'Acelerômetro e giroscópio disponíveis'
                          : 'Modo de simulação'),
                  alert: controller.error != null || missing.isNotEmpty,
                ),
                if (controller.error != null)
                  OutlinedButton(
                    onPressed: controller.retryCapture,
                    child: const Text('Tentar captura novamente'),
                  ),
                const Divider(height: 1, color: PulupaColors.line),
                StatusLine(
                  icon: controller.wifi == false
                      ? Icons.wifi_off_rounded
                      : Icons.wifi_rounded,
                  label: 'Wi-Fi',
                  detail: switch (controller.wifi) {
                    true => 'Conectado a uma rede Wi-Fi',
                    false => 'Sem rede Wi-Fi',
                    null => 'Estado da rede indisponível',
                  },
                ),
              ],
            ),
          );
        },
      ),
      OutlinedButton.icon(
        onPressed: openLab,
        icon: const Icon(Icons.science_outlined),
        label: const Text('Testar movimento'),
      ),
    ],
  );
}

class _Hero extends StatelessWidget {
  const _Hero();

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(30),
    child: ColoredBox(
      color: PulupaColors.blue,
      child: Stack(
        children: [
          const Positioned.fill(child: CustomPaint(painter: _HeroMotion())),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 35, 16, 35),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'PULUPA!',
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    color: Colors.white,
                    fontSize: 43,
                    height: 1,
                    letterSpacing: -2,
                    fontStyle: FontStyle.italic,
                    fontWeight: FontWeight.w900,
                    shadows: const [
                      Shadow(color: PulupaColors.navy, offset: Offset(2, 3)),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Motion Controller',
                  style: TextStyle(
                    color: PulupaColors.yellow,
                    fontWeight: FontWeight.w800,
                    fontSize: 17,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

final _heroPose =
    Rotation.axisAngle(Vec3.up, -0.36) *
    Rotation.axisAngle(const Vec3(0, 1, 0), 0.47);

class _HeroMotion extends CustomPainter {
  const _HeroMotion();

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width - 49, size.height * 0.51);
    final rings = Paint()
      ..color = const Color(0xFF7290FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final radius in [49.0, 64.0, 81.0]) {
      canvas.drawCircle(center, radius, rings);
    }
    if (size.width >= 285) {
      paintPhone(canvas, center, 41, _heroPose);
      final dots = Paint()..color = PulupaColors.pink;
      canvas.drawCircle(center + const Offset(-43, 26), 4, dots);
      canvas.drawCircle(
        center + const Offset(29, -51),
        3,
        dots..color = PulupaColors.yellow,
      );
    }
  }

  @override
  bool shouldRepaint(_HeroMotion oldDelegate) => false;
}
