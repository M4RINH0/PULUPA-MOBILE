import 'motion_packet.dart';
import 'motion_transport.dart';

typedef MotionSender = void Function(String);

class WebSocketMotionTransport implements MotionTransport {
  WebSocketMotionTransport(this._send);

  final MotionSender _send;
  int? _awaitingSequence;
  bool _closed = false;

  bool get available => !_closed && _awaitingSequence == null;

  @override
  bool offer(MotionPacket packet) {
    if (!available) return false;
    _awaitingSequence = packet.sequence;
    _send(packet.encode());
    return true;
  }

  /// Releases the in-flight packet for any `motion_ack` with its sequence,
  /// whether the server accepted the sample or not.
  bool acknowledge(int sequence) {
    if (_closed || _awaitingSequence != sequence) return false;
    _awaitingSequence = null;
    return true;
  }

  @override
  Future<void> close() async {
    _closed = true;
    _awaitingSequence = null;
  }
}
