const motionProtocolVersion = 1;

final _decimal = RegExp(r'^(0|[1-9][0-9]*)$');
final _ticket = RegExp(r'^[A-Za-z0-9_-]{32,128}$');
final sessionIdPattern = RegExp(r'^[A-Za-z0-9_-]{22,64}$');

class LanEndpoint {
  const LanEndpoint._(this.host, this.port);

  final String host;
  final int port;

  factory LanEndpoint.parse(String host, String port) {
    final parts = host.split('.');
    final candidates = parts.map(int.tryParse).toList();
    if (parts.length != 4 ||
        parts.any((part) => !_decimal.hasMatch(part)) ||
        candidates.any((n) => n == null || n < 0 || n > 255)) {
      throw const FormatException('Informe um endereço IPv4 privado.');
    }
    final first = candidates[0]!;
    final second = candidates[1]!;
    final private =
        first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168) ||
        (first == 169 && second == 254);
    if (!private) {
      throw const FormatException('O computador precisa estar na rede local.');
    }
    final number = int.tryParse(port);
    if (!_decimal.hasMatch(port) ||
        number == null ||
        number < 1 ||
        number > 65535) {
      throw const FormatException('Porta inválida.');
    }
    return LanEndpoint._(host, number);
  }

  Uri get webSocketUri =>
      Uri(scheme: 'ws', host: host, port: port, path: '/ws/controller');
}

class PairingInvite {
  const PairingInvite._(this.endpoint, this.sessionId, this.ticket);

  final LanEndpoint endpoint;
  final String sessionId;
  final String ticket;

  factory PairingInvite.fromQr(String value) {
    if (value.length > 512 || value != value.trim()) {
      throw const FormatException('Convite inválido.');
    }
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'pulupa' ||
        uri.authority != 'pair' ||
        uri.path.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('QR Code incompatível com PULUPA.');
    }
    final fields = uri.queryParametersAll;
    const requiredKeys = {'v', 'host', 'port', 'session', 'ticket'};
    if (fields.length != requiredKeys.length ||
        requiredKeys.any((key) => fields[key]?.length != 1) ||
        fields['v']!.single != '$motionProtocolVersion' ||
        !sessionIdPattern.hasMatch(fields['session']!.single) ||
        !_ticket.hasMatch(fields['ticket']!.single)) {
      throw const FormatException('Dados do convite inválidos.');
    }
    return PairingInvite._(
      LanEndpoint.parse(fields['host']!.single, fields['port']!.single),
      fields['session']!.single,
      fields['ticket']!.single,
    );
  }
}
