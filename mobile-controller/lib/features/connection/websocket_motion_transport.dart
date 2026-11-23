import 'motion_packet.dart';
import 'motion_transport.dart';

typedef MotionSender = void Function(String);

class WebSocketMotionTransport implements MotionTransport {
  WebSocketMotionTransport(this._send);

  final MotionSender _send;
  int? _awaitingSequence;
  MotionPacket? _pending;
  bool _closed = false;

  bool get available => !_closed && _awaitingSequence == null;

  @override
  void offer(MotionPacket packet) {
    if (_closed) return;
    _pending = packet;
    _flush();
  }

  bool acknowledge(int sequence) {
    if (_awaitingSequence != sequence) return false;
    _awaitingSequence = null;
    _flush();
    return true;
  }

  void _flush() {
    final packet = _pending;
    if (packet == null || !available) return;
    _pending = null;
    _awaitingSequence = packet.sequence;
    _send(packet.encode());
  }

  @override
  Future<void> close() async {
    _closed = true;
    _pending = null;
    _awaitingSequence = null;
  }
}
