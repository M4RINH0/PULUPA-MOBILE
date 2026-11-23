import 'package:material_ui/material_ui.dart';

import '../../app/motion_controller.dart';
import '../../core/theme/components.dart';

class PairingPage extends StatelessWidget {
  const PairingPage({
    super.key,
    required this.controller,
    required this.openLab,
  });

  final MotionController controller;
  final VoidCallback openLab;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Conectar ao jogo')),
    body: PageBody(
      children: [
        Text(
          'Pareamento com o PC',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const Panel(
          child: StatusLine(
            icon: Icons.link_off_rounded,
            label: 'Pareamento indisponível nesta versão',
            detail: 'Use o laboratório para testar a leitura dos sensores e a orientação do celular.',
          ),
        ),
        ValueListenableBuilder(
          valueListenable: controller.status,
          builder: (context, _, _) => Panel(
            child: StatusLine(
              icon: Icons.wifi_rounded,
              label: 'Wi-Fi',
              detail: switch (controller.wifi) {
                true => 'Conectado a uma rede Wi-Fi',
                false => 'Sem rede Wi-Fi',
                null => 'Estado da rede indisponível',
              },
            ),
          ),
        ),
        FilledButton(
          onPressed: openLab,
          child: const Text('Abrir laboratório'),
        ),
      ],
    ),
  );
}
