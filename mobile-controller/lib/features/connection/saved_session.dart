import 'dart:convert';

import '../pairing/pairing_invite.dart';

/// Credentials needed to rejoin the same slot after the app is closed.
///
/// Saved after every `welcome` (the resume token rotates) and cleared when the
/// player disconnects on purpose or the PC ends the session. The server keeps
/// a dropped slot for 180 s, so an older save is useless.
class SavedSession {
  const SavedSession({
    required this.host,
    required this.port,
    required this.sessionId,
    required this.resume,
    required this.playerId,
    required this.playerKey,
    required this.name,
    required this.color,
    required this.deviceLabel,
    required this.savedAt,
  });

  static const maxAge = Duration(seconds: 170);

  final String host;
  final int port;
  final String sessionId;
  final String resume;
  final int playerId;
  final String playerKey;
  final String name;
  final int color;
  final String deviceLabel;
  final DateTime savedAt;

  bool isFresh(DateTime now) {
    final age = now.difference(savedAt);
    return !age.isNegative && age < maxAge;
  }

  LanEndpoint get endpoint => LanEndpoint.parse(host, '$port');

  String encode() => jsonEncode({
    'host': host,
    'port': port,
    'session': sessionId,
    'resume': resume,
    'player': playerId,
    'key': playerKey,
    'name': name,
    'color': color,
    'device': deviceLabel,
    'savedAt': savedAt.millisecondsSinceEpoch,
  });

  /// Returns null for anything malformed; a bad save must never crash startup.
  static SavedSession? decode(String? raw) {
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) return null;
      final session = SavedSession(
        host: data['host'] as String,
        port: data['port'] as int,
        sessionId: data['session'] as String,
        resume: data['resume'] as String,
        playerId: data['player'] as int,
        playerKey: data['key'] as String,
        name: data['name'] as String,
        color: data['color'] as int,
        deviceLabel: data['device'] as String,
        savedAt: DateTime.fromMillisecondsSinceEpoch(data['savedAt'] as int),
      );
      session.endpoint; // Validates host and port.
      return session;
    } on Object {
      return null;
    }
  }
}
