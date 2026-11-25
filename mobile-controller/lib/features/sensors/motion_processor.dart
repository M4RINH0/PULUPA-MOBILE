import 'dart:math' as math;

import '../../core/motion_math.dart';
import '../calibration/calibration.dart';
import 'gravity_fusion.dart';
import 'sensor_source.dart';

class MotionProcessor {
  /// [calibration] may be shared across processors so the neutral pose
  /// survives a capture restart (for example after the app is paused).
  MotionProcessor(this.capabilities, {Calibration? calibration})
    : calibration = calibration ?? Calibration();

  static const maxSensorSkewUs = 120000;
  static const staleAfterUs = 350000;
  static const sourceChangedFeedback =
      'A fonte de orientação mudou; recalibre.';

  final SensorCapabilities capabilities;
  final Calibration calibration;
  final _fusion = GravityFusion();
  final _filter = OrientationFilter();
  final _rates = {for (final kind in SensorKind.values) kind: _Rate()};
  final _lastUs = <SensorKind, int>{};
  final _receivedUs = <SensorKind, int>{};

  Vec3? _acceleration;
  Vec3? _angularVelocity;
  Rotation? _rawOrientation;
  Rotation? _orientation;
  MotionFrame? _latestFrame;
  int? _frameReceiptUs;
  int? _firstGyroUs;
  int _lastSystemUs = -1;
  int _lastFrameUs = -1;
  bool _usingSystem = false;
  bool _checkedReferenceSource = false;
  double _peakLinear = 0;
  double _peakGyro = 0;

  int smoothingMs = 18;
  double deadZoneDegrees = 0.5;

  bool _isLive(SensorKind kind, int nowUs) {
    final last = _receivedUs[kind];
    return last != null && nowUs - last <= staleAfterUs;
  }

  Vec3? accelerationAt(int nowUs) =>
      _isLive(SensorKind.acceleration, nowUs) ? _acceleration : null;

  Vec3? angularVelocityAt(int nowUs) =>
      _isLive(SensorKind.angularVelocity, nowUs) ? _angularVelocity : null;

  Rotation? orientationAt(int nowUs) =>
      _isLive(SensorKind.orientation, nowUs) ? _orientation : null;

  double rateAt(SensorKind kind, int nowUs) =>
      _isLive(kind, nowUs) ? _rates[kind]!.hz : 0;

  OrientationSource get orientationSource {
    if (_usingSystem) return OrientationSource.systemFusion;
    if (_rawOrientation != null) return OrientationSource.gyroscopeGravity;
    return capabilities.orientationSource;
  }

  MotionFrame? frameAt(int nowUs) {
    final receiptUs = _frameReceiptUs;
    if (receiptUs == null || nowUs - receiptUs > Calibration.maxGapUs) {
      return null;
    }
    return _latestFrame;
  }

  /// Wall-clock age of the latest complete frame, or null if there is none.
  int? frameAgeUs(int nowUs) {
    final receiptUs = _frameReceiptUs;
    return receiptUs == null ? null : nowUs - receiptUs;
  }

  void clearCalibration() {
    calibration.clear();
    _filter.reset();
    _orientation = _rawOrientation;
    _latestFrame = null;
    _frameReceiptUs = null;
  }

  MotionFrame? ingest(SensorReading reading, int receivedUs) {
    if (!reading.isValid) return null;
    final kind = reading.kind;
    final timestamp = reading.timestampUs;
    if (kind == SensorKind.orientation) {
      if (timestamp <= _lastSystemUs) return null;
      _lastSystemUs = timestamp;
      return _orient(
        reading.rotation!.normalized(),
        timestamp,
        receivedUs,
        system: true,
      );
    }
    if (timestamp <= (_lastUs[kind] ?? -1)) return null;
    _record(kind, timestamp, receivedUs);
    calibration.observeReading(reading);
    if (kind == SensorKind.acceleration) {
      _acceleration = reading.vector;
      _peakLinear = math.max(_peakLinear, _linearMagnitude(reading.vector!));
      return null;
    }
    _angularVelocity = reading.vector;
    _peakGyro = math.max(_peakGyro, reading.vector!.length);
    final firstGyroUs = _firstGyroUs ??= timestamp;
    final awaitingSystem =
        capabilities.systemOrientation &&
        _rawOrientation == null &&
        timestamp - firstGyroUs < staleAfterUs;
    final systemFresh =
        _usingSystem &&
        _isLive(SensorKind.orientation, receivedUs) &&
        timestamp - _lastUs[SensorKind.orientation]! <= staleAfterUs;
    if (awaitingSystem || systemFresh || !capabilities.canCalibrate) {
      return null;
    }
    final orientation = _fusion.update(
      timestamp,
      _angularVelocity!,
      _near(SensorKind.acceleration, timestamp) ? _acceleration : null,
    );
    if (orientation == null) return null;
    if (_fusion.interrupted) {
      // The rotation during the gap is unknown: no sample from it may enter
      // a calibration window or be blended by the smoothing filter.
      calibration.interrupt();
      _filter.reset();
    }
    return _orient(orientation, timestamp, receivedUs, system: false);
  }

  Vec3? _gravity() {
    final raw = _rawOrientation;
    if (raw == null) return null;
    return raw.inverseUnit.rotate(Vec3.up) * standardGravity;
  }

  double _linearMagnitude(Vec3 acceleration) {
    final gravity = _gravity();
    return gravity == null
        ? (acceleration.length - standardGravity).abs()
        : (acceleration - gravity).length;
  }

  bool _near(SensorKind kind, int timestamp) {
    final prior = _lastUs[kind];
    return prior != null && (timestamp - prior).abs() <= maxSensorSkewUs;
  }

  void _record(SensorKind kind, int timestamp, int receivedUs) {
    _lastUs[kind] = timestamp;
    _receivedUs[kind] = receivedUs;
    _rates[kind]!.add(timestamp);
  }

  MotionFrame? _orient(
    Rotation raw,
    int timestamp,
    int receivedUs, {
    required bool system,
  }) {
    final switched = _rawOrientation != null && _usingSystem != system;
    final previousUs = _lastUs[SensorKind.orientation] ?? -1;
    if (timestamp <= previousUs &&
        !(switched && system && previousUs - timestamp <= maxSensorSkewUs)) {
      return null;
    }
    final source = system
        ? OrientationSource.systemFusion
        : OrientationSource.gyroscopeGravity;
    final staleReference =
        !_checkedReferenceSource &&
        calibration.reference != null &&
        calibration.referenceSource != null &&
        calibration.referenceSource != source;
    _checkedReferenceSource = true;
    if (staleReference) {
      calibration.clear(reason: sourceChangedFeedback);
      _filter.reset();
    }
    if (switched) {
      calibration.interrupt(sourceChangedFeedback);
      if (calibration.reference != null) {
        calibration.clear(reason: sourceChangedFeedback);
      }
      _filter.reset();
      _rates[SensorKind.orientation] = _Rate();
      _latestFrame = null;
      _frameReceiptUs = null;
    }
    if (system) _fusion.reset();
    _usingSystem = system;
    _rawOrientation = raw;
    _record(SensorKind.orientation, timestamp, receivedUs);

    final synchronized =
        _near(SensorKind.acceleration, timestamp) &&
        _near(SensorKind.angularVelocity, timestamp) &&
        _isLive(SensorKind.acceleration, receivedUs) &&
        _isLive(SensorKind.angularVelocity, receivedUs);
    if (synchronized) {
      final oldReference = calibration.reference;
      calibration.addFrame(
        MotionFrame(
          timestampUs: timestamp,
          orientation: raw,
          acceleration: _acceleration!,
          angularVelocity: _angularVelocity!,
        ),
      );
      if (calibration.reference != oldReference) {
        calibration.referenceSource = source;
        _filter.reset();
      }
    }

    final reference = calibration.reference;
    _orientation = reference == null
        ? raw
        : _filter.update(
            gravityAlignedRelative(reference, raw),
            timestamp,
            smoothingMs: smoothingMs,
            deadZoneDegrees: deadZoneDegrees,
          );
    if (!synchronized || timestamp <= _lastFrameUs) return null;
    _lastFrameUs = timestamp;
    _frameReceiptUs = receivedUs;
    final acceleration = _acceleration!;
    final angularVelocity = _angularVelocity!;
    final linear = acceleration - _gravity()!;
    final frame = _latestFrame = MotionFrame(
      timestampUs: timestamp,
      orientation: _orientation!,
      acceleration: acceleration,
      angularVelocity: angularVelocity,
      linearAcceleration: linear,
      peakLinearAcceleration: math.max(_peakLinear, linear.length),
      peakAngularVelocity: math.max(_peakGyro, angularVelocity.length),
    );
    _peakLinear = 0;
    _peakGyro = 0;
    return frame;
  }
}

class _Rate {
  int? _windowStart;
  int _intervals = 0;
  double hz = 0;

  void add(int timestamp) {
    final start = _windowStart ??= timestamp;
    final elapsed = timestamp - start;
    if (elapsed == 0) return;
    _intervals++;
    if (elapsed >= 500000) {
      hz = _intervals * 1000000 / elapsed;
      _windowStart = timestamp;
      _intervals = 0;
    }
  }
}
