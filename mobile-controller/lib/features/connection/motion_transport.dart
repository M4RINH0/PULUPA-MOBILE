import 'motion_packet.dart';

/// Implementations replace any pending sample with the newest on offer.
abstract interface class MotionTransport {
  void offer(MotionPacket packet);
  Future<void> close();
}

class ReconnectPolicy {
  const ReconnectPolicy();

  static const _delays = [
    Duration(milliseconds: 500),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
  ];

  /// Zero represents the first retry, after the original connection attempt.
  Duration? delayFor(int attempt) =>
      attempt >= 0 && attempt < _delays.length ? _delays[attempt] : null;
}
