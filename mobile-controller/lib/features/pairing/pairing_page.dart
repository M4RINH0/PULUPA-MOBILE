import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../app/motion_controller.dart';
import '../../core/theme/components.dart';
import '../../core/theme/pulupa_theme.dart';
import '../connection/connection_controller.dart';
import 'pairing_invite.dart';
import 'player_name.dart';

class PairingPage extends StatefulWidget {
  const PairingPage({
    super.key,
    required this.motion,
    required this.connection,
  });

  final MotionController motion;
  final ConnectionController connection;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _name = TextEditingController(text: 'Jogador');
  final _host = TextEditingController();
  final _port = TextEditingController(text: '8765');
  final _code = TextEditingController();
  bool _completed = false;
  String? _formError;

  ConnectionController get _connection => widget.connection;

  @override
  void initState() {
    super.initState();
    _connection.addListener(_onConnectionChange);
  }

  void _onConnectionChange() {
    if (_completed ||
        _connection.phase != ConnectionPhase.connected ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _completed = true;
    Navigator.of(context).pop(true);
  }

  String? _playerName() {
    final name = normalizePlayerName(_name.text);
    if (name == null) {
      setState(
        () => _formError =
            'Informe um nome de jogador com 1 a 32 caracteres visíveis.',
      );
      return null;
    }
    setState(() => _formError = null);
    FocusScope.of(context).unfocus();
    return name;
  }

  Future<void> _scan() async {
    final name = _playerName();
    if (name == null) return;
    final invite = await Navigator.of(
      context,
    ).push<PairingInvite>(MaterialPageRoute(builder: (_) => const _QrPage()));
    if (!mounted || invite == null) return;
    _connection.connectQr(invite, name, widget.motion.deviceLabel);
  }

  void _manual() {
    final name = _playerName();
    if (name == null) return;
    try {
      final endpoint = LanEndpoint.parse(_host.text.trim(), _port.text.trim());
      final code = _code.text.trim();
      if (!RegExp(r'^[0-9]{6}$').hasMatch(code)) {
        throw const FormatException(
          'Informe o código de seis dígitos mostrado no PC.',
        );
      }
      _connection.connectManual(
        endpoint,
        code,
        name,
        widget.motion.deviceLabel,
      );
    } on FormatException catch (error) {
      setState(() => _formError = error.message);
    }
  }

  @override
  void dispose() {
    _connection.removeListener(_onConnectionChange);
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Conectar ao jogo')),
    body: ListenableBuilder(
      listenable: Listenable.merge([_connection, widget.motion.status]),
      builder: (context, _) {
        final busy = _connection.busy;
        final error = _formError ?? _connection.error;
        return PageBody(
          children: [
            Text(
              'Pareamento com o PC',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const Text(
              'Conecte o celular à mesma rede do PC e abra o painel do PULUPA.',
            ),
            StatusLine(
              icon: Icons.smartphone_rounded,
              label: widget.motion.deviceLabel,
              detail: widget.motion.wifi == false
                  ? 'Sem rede Wi-Fi'
                  : 'Dispositivo deste jogador',
              alert: widget.motion.wifi == false,
            ),
            TextField(
              enabled: !busy,
              controller: _name,
              textCapitalization: TextCapitalization.words,
              inputFormatters: [LengthLimitingTextInputFormatter(32)],
              decoration: const InputDecoration(
                labelText: 'Nome do jogador',
                border: OutlineInputBorder(),
              ),
            ),
            if (error != null || busy)
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 10,
                  children: [
                    StatusLine(
                      icon: busy ? Icons.sync_rounded : Icons.link_off_rounded,
                      label: busy
                          ? 'Conectando ao PC'
                          : 'Não foi possível parear',
                      detail: error ?? 'Aguardando resposta do servidor…',
                      alert: !busy,
                    ),
                    if (busy) const LinearProgressIndicator(),
                    if (busy)
                      TextButton(
                        onPressed: _connection.disconnect,
                        child: const Text('Cancelar'),
                      ),
                  ],
                ),
              ),
            FilledButton.icon(
              onPressed: busy ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Ler QR Code'),
            ),
            Panel(
              child: Column(
                spacing: 12,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Conexão manual',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  TextField(
                    enabled: !busy,
                    controller: _host,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Endereço IP do PC',
                      hintText: '192.168.1.20',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  TextField(
                    enabled: !busy,
                    controller: _port,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(5),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Porta',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  TextField(
                    enabled: !busy,
                    controller: _code,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    decoration: const InputDecoration(
                      labelText: 'Código mostrado no PC',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : _manual,
                    child: const Text('Conectar por IP'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
}

class _QrPage extends StatefulWidget {
  const _QrPage();

  @override
  State<_QrPage> createState() => _QrPageState();
}

class _QrPageState extends State<_QrPage> {
  bool _finished = false;
  bool _invalid = false;

  void _detect(BarcodeCapture capture) {
    if (!mounted || _finished) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (barcode.format != BarcodeFormat.qrCode || value == null) continue;
      try {
        final invite = PairingInvite.fromQr(value);
        _finished = true;
        Navigator.of(context).pop(invite);
        return;
      } on FormatException {
        if (!_invalid) setState(() => _invalid = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Ler QR Code')),
    body: SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              _invalid
                  ? 'QR inválido. Aponte para o convite mostrado no painel do PULUPA.'
                  : 'A câmera lê o convite no painel do PC. Aponte para o QR Code.',
            ),
          ),
          Expanded(
            child: MobileScanner(
              onDetect: _detect,
              errorBuilder: (context, error) => ColoredBox(
                color: PulupaColors.navy,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      error.errorCode == MobileScannerErrorCode.permissionDenied
                          ? 'Permita o uso da câmera nas configurações do Android ou volte para conectar por IP.'
                          : 'Câmera indisponível. Volte e use a conexão manual.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
