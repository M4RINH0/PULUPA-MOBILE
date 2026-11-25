class ControllerSettings {
  const ControllerSettings({
    this.captureHz = 100,
    this.sendHz = 60,
    this.smoothingMs = 18,
    this.deadZoneDegrees = 0.5,
    this.haptics = true,
  });

  static const captureRates = [25, 50, 100];
  static const sendRates = [30, 60, 100];

  final int captureHz;
  final int sendHz;
  final int smoothingMs;
  final double deadZoneDegrees;
  final bool haptics;

  factory ControllerSettings.fromMap(Map<String, Object?> values) {
    final capture = values['captureHz'];
    final send = values['sendHz'];
    final smoothing = values['smoothingMs'];
    final deadZone = values['deadZoneDegrees'];
    final haptics = values['haptics'];
    return ControllerSettings(
      // `60 == 60.0` in Dart, so check the type before the cast.
      captureHz: capture is int && captureRates.contains(capture)
          ? capture
          : 100,
      sendHz: send is int && sendRates.contains(send) ? send : 60,
      smoothingMs: smoothing is int ? smoothing.clamp(0, 60) : 18,
      deadZoneDegrees: deadZone is num && deadZone.isFinite
          ? deadZone.toDouble().clamp(0.0, 3.0)
          : 0.5,
      haptics: haptics is bool ? haptics : true,
    );
  }

  Map<String, Object> toMap() => {
    'captureHz': captureHz,
    'sendHz': sendHz,
    'smoothingMs': smoothingMs,
    'deadZoneDegrees': deadZoneDegrees,
    'haptics': haptics,
  };

  ControllerSettings copyWith({
    int? captureHz,
    int? sendHz,
    int? smoothingMs,
    double? deadZoneDegrees,
    bool? haptics,
  }) => ControllerSettings(
    captureHz: captureHz ?? this.captureHz,
    sendHz: sendHz ?? this.sendHz,
    smoothingMs: smoothingMs ?? this.smoothingMs,
    deadZoneDegrees: deadZoneDegrees ?? this.deadZoneDegrees,
    haptics: haptics ?? this.haptics,
  );
}
