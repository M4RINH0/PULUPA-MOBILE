import 'motion_packet.dart';

/// Keeps at most one motion packet awaiting acknowledgement. Callers pick the
/// newest sample only when [offer] can send it, so nothing stale is queued.
abstract interface class MotionTransport {
  /// Sends [packet] and returns true, or returns false while another packet
  /// still awaits its `motion_ack`.
  bool offer(MotionPacket packet);
  Future<void> close();
}

/// Backoff for reconnecting after a dropped connection. Retries continue,
/// with delays capped at [maxDelay], until [window] has elapsed since the
/// drop. The server keeps a dropped slot for 180 s, so the default window ends
/// a little earlier to leave room for the last handshake.
class ReconnectPolicy {
  const ReconnectPolicy({
    this.window = const Duration(seconds: 170),
    this.maxDelay = const Duration(seconds: 5),
  });

  static const _initial = Duration(milliseconds: 500);

  final Duration window;
  final Duration maxDelay;

  /// Delay before retry number [attempt] (zero is the first retry), or null
  /// when that retry would start after [window] measured from the drop.
  Duration? delayFor(int attempt, Duration sinceDrop) {
    if (attempt < 0) return null;
    final grown = _initial * (1 << (attempt > 10 ? 10 : attempt));
    final delay = grown > maxDelay ? maxDelay : grown;
    return sinceDrop + delay > window ? null : delay;
  }
}
