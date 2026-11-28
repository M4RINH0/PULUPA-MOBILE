import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/motion_controller.dart';
import '../../core/theme/pulupa_theme.dart';
import '../connection/connection_controller.dart';

/// The phone as a game controller: full screen, a big A button where the
/// thumb rests and a smaller B below it.
///
/// Built so a stray touch does nothing harmful. The system bars are hidden
/// (immersive), so leaving takes two swipes from the edge; back only shows a
/// hint; the exit button needs a long press. Each button follows one finger
/// at a time and sits away from the edges, and A acts on release after a
/// hold, so a brush of the screen never throws.
class ControllerPadPage extends StatefulWidget {
  const ControllerPadPage({
    super.key,
    required this.motion,
    required this.connection,
  });

  final MotionController motion;
  final ConnectionController connection;

  @override
  State<ControllerPadPage> createState() => _ControllerPadPageState();
}

class _ControllerPadPageState extends State<ControllerPadPage> {
  static const source = 'screen';

  @override
  void initState() {
    super.initState();
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
  }

  @override
  void dispose() {
    widget.connection.releaseButtons(source: source);
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  void _exitHint() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Segure SAIR para fechar o controle.'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  void _touch(String button, bool pressed) {
    widget.connection.setButton(button, pressed, source: source);
    if (pressed && widget.motion.settings.haptics) {
      unawaited(HapticFeedback.lightImpact());
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _exitHint();
    },
    child: Scaffold(
      backgroundColor: PulupaColors.navy,
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.connection,
          builder: (context, _) => _pad(context),
        ),
      ),
    ),
  );

  Widget _pad(BuildContext context) {
    final connection = widget.connection;
    final player = connection.player;
    final color = player == null ? PulupaColors.blue : Color(player.color);
    final connected = connection.phase == ConnectionPhase.connected;
    final status = connected
        ? 'Conectado'
        : connection.busy
        ? 'Reconectando…'
        : 'Sem conexão';
    return LayoutBuilder(
      builder: (context, box) {
        final size = (box.maxWidth * 0.78)
            .clamp(140.0, box.maxHeight * 0.48)
            .toDouble();
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      player == null ? 'Controle' : 'Jogador ${player.id}',
                      style: const TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          player?.name ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                        Text(
                          status,
                          style: TextStyle(
                            color: connected
                                ? PulupaColors.yellow
                                : PulupaColors.red,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _exitHint,
                    onLongPress: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                      minimumSize: const Size(0, 40),
                    ),
                    child: const Text('SAIR'),
                  ),
                ],
              ),
              const Spacer(),
              HoldButton(
                label: 'A',
                caption: 'Segure, balance e solte',
                semanticsLabel: 'Botão A',
                color: color,
                size: size,
                held: connection.isHeld('a'),
                onChanged: (pressed) => _touch('a', pressed),
              ),
              const SizedBox(height: 28),
              HoldButton(
                label: 'B',
                caption: 'Centralizar',
                semanticsLabel: 'Botão B',
                color: Colors.white,
                size: size * 0.42,
                held: connection.isHeld('b'),
                onChanged: (pressed) => _touch('b', pressed),
              ),
              const Spacer(),
              const Text(
                'Teclas de volume: − é o A, + é o B',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// A round button that reports going down and coming up, following the
/// first finger that touched it; other fingers are ignored until it lifts.
class HoldButton extends StatefulWidget {
  const HoldButton({
    super.key,
    required this.label,
    required this.caption,
    required this.semanticsLabel,
    required this.color,
    required this.size,
    required this.held,
    required this.onChanged,
  });

  final String label;
  final String caption;
  final String semanticsLabel;
  final Color color;
  final double size;

  /// Shown as pressed (also when another source, like a volume key, holds it).
  final bool held;
  final ValueChanged<bool> onChanged;

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton> {
  int? _pointer;

  void _down(PointerDownEvent event) {
    if (_pointer != null) return;
    _pointer = event.pointer;
    widget.onChanged(true);
  }

  void _up(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _pointer = null;
    widget.onChanged(false);
  }

  // No release on dispose: the page lets go of every screen button when it
  // closes, outside the widget tree's teardown.

  @override
  Widget build(BuildContext context) {
    final pressed = widget.held || _pointer != null;
    final dark = widget.color.computeLuminance() > 0.5;
    return Semantics(
      button: true,
      label: widget.semanticsLabel,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: AnimatedScale(
          scale: pressed ? 0.94 : 1,
          duration: const Duration(milliseconds: 80),
          child: Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: pressed
                  ? Color.lerp(widget.color, Colors.black, 0.25)
                  : widget.color,
              border: Border.all(color: Colors.white, width: pressed ? 6 : 3),
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  style: TextStyle(
                    color: dark ? PulupaColors.navy : Colors.white,
                    fontSize: widget.size * 0.36,
                    fontWeight: FontWeight.w900,
                    height: 1,
                  ),
                ),
                Text(
                  widget.caption,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: dark ? PulupaColors.navy : Colors.white,
                    fontSize: (widget.size * 0.07).clamp(12.0, 18.0),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
