import 'dart:math' as math;

import '../../core/motion_math.dart';
import '../sensors/gravity_fusion.dart';
import '../sensors/sensor_source.dart';

enum GestureKind { abruptMotion, quickRotation, tilt, swing }

enum GesturePhase { started, ended }

typedef GestureEvent = ({
  GestureKind kind,
  GesturePhase phase,
  int timestampUs,
});
typedef GestureSignal = double Function(MotionFrame frame, bool calibrated);

abstract interface class MotionGestureDetector {
  GestureEvent? update(MotionFrame frame, {required bool calibrated});
  void reset();
}

class GestureThreshold {
  const GestureThreshold({
    required this.on,
    required this.off,
    this.startHoldMs = 25,
    this.endHoldMs = 90,
    this.cooldownMs = 220,
    this.smoothingMs = 25,
  }) : assert(on > off);

  final double on;
  final double off;
  final int startHoldMs;
  final int endHoldMs;
  final int cooldownMs;
  final int smoothingMs;
}

class ThresholdGestureDetector implements MotionGestureDetector {
  ThresholdGestureDetector(this.kind, this.signal, this.threshold);

  final GestureKind kind;
  final GestureSignal signal;
  final GestureThreshold threshold;
  double _level = 0;
  bool _active = false;
  int? _candidateUs;
  int? _lastUs;
  int _cooldownUntilUs = 0;

  @override
  GestureEvent? update(MotionFrame frame, {required bool calibrated}) {
    final now = frame.timestampUs;
    final elapsed = now - (_lastUs ?? now);
    _lastUs = now;
    final value = signal(frame, calibrated);
    final alpha = threshold.smoothingMs == 0 || elapsed <= 0
        ? 1.0
        : 1 - math.exp(-elapsed / (1000 * threshold.smoothingMs));
    _level += (value - _level) * alpha;
    final beyond = _active ? _level < threshold.off : _level > threshold.on;
    if (!beyond || (!_active && now < _cooldownUntilUs)) {
      _candidateUs = null;
      return null;
    }
    final since = _candidateUs ??= now;
    final durationMs = _active ? threshold.endHoldMs : threshold.startHoldMs;
    if (now - since < durationMs * 1000) return null;
    _active = !_active;
    _candidateUs = null;
    if (!_active) _cooldownUntilUs = now + threshold.cooldownMs * 1000;
    return (
      kind: kind,
      phase: _active ? GesturePhase.started : GesturePhase.ended,
      timestampUs: now,
    );
  }

  @override
  void reset() {
    _level = 0;
    _active = false;
    _candidateUs = null;
    _lastUs = null;
    _cooldownUntilUs = 0;
  }
}

class MotionGestures {
  MotionGestures({List<MotionGestureDetector>? detectors})
    : _detectors =
          detectors ??
          [
            ThresholdGestureDetector(
              GestureKind.abruptMotion,
              (frame, _) => (frame.acceleration.length - standardGravity).abs(),
              const GestureThreshold(
                on: 2.5,
                off: 1.1,
                startHoldMs: 10,
                smoothingMs: 12,
              ),
            ),
            ThresholdGestureDetector(
              GestureKind.quickRotation,
              (frame, _) => frame.angularVelocity.length,
              const GestureThreshold(on: 4, off: 2),
            ),
            ThresholdGestureDetector(
              GestureKind.tilt,
              (frame, calibrated) => calibrated
                  ? math.acos(
                      frame.orientation.rotate(Vec3.up).z.clamp(-1.0, 1.0),
                    )
                  : 0,
              const GestureThreshold(on: 0.45, off: 0.27, startHoldMs: 75),
            ),
            ThresholdGestureDetector(
              GestureKind.swing,
              (frame, _) => frame.angularVelocity.length,
              const GestureThreshold(
                on: 1.45,
                off: 0.65,
                startHoldMs: 115,
                smoothingMs: 35,
              ),
            ),
          ];

  final List<MotionGestureDetector> _detectors;
  final active = <GestureKind>{};
  int? _lastUs;

  void update(MotionFrame frame, {required bool calibrated}) {
    final previous = _lastUs;
    if (previous != null && frame.timestampUs - previous > 200000) reset();
    _lastUs = frame.timestampUs;
    for (final detector in _detectors) {
      final event = detector.update(frame, calibrated: calibrated);
      if (event == null) continue;
      switch (event.phase) {
        case GesturePhase.started:
          active.add(event.kind);
        case GesturePhase.ended:
          active.remove(event.kind);
      }
    }
  }

  void reset() {
    _lastUs = null;
    active.clear();
    for (final detector in _detectors) {
      detector.reset();
    }
  }
}
