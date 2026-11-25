/// Player name rule shared with the motion server (`clean_text` in
/// `motion-server/app/protocol.py` and `protocol/fixtures/names.json`).
///
/// Every Unicode space separator (category Zs) becomes U+0020, the edges are
/// trimmed of U+0020 and the result must hold 1 to [maxPlayerNameRunes] code
/// points with no control, line/paragraph separator, bidi control, private
/// use or lone surrogate code point. ZWJ and emoji are allowed.
library;

const maxPlayerNameRunes = 32;

const _spaceSeparators = {
  0x00A0,
  0x1680,
  0x2000,
  0x2001,
  0x2002,
  0x2003,
  0x2004,
  0x2005,
  0x2006,
  0x2007,
  0x2008,
  0x2009,
  0x200A,
  0x202F,
  0x205F,
  0x3000,
};

bool _forbidden(int rune) =>
    rune < 0x20 ||
    (rune >= 0x7F && rune <= 0x9F) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    (rune >= 0x202A && rune <= 0x202E) ||
    (rune >= 0x2066 && rune <= 0x2069) ||
    (rune >= 0xD800 && rune <= 0xDFFF) ||
    (rune >= 0xE000 && rune <= 0xF8FF) ||
    rune >= 0xF0000;

/// Returns the normalized name to send in `hello`, or `null` when the server
/// would answer `invalid_name`.
String? normalizePlayerName(String input) {
  final runes = [
    for (final rune in input.runes)
      _spaceSeparators.contains(rune) ? 0x20 : rune,
  ];
  var start = 0;
  var end = runes.length;
  while (start < end && runes[start] == 0x20) {
    start++;
  }
  while (end > start && runes[end - 1] == 0x20) {
    end--;
  }
  final length = end - start;
  if (length < 1 || length > maxPlayerNameRunes) return null;
  final kept = runes.sublist(start, end);
  if (kept.any(_forbidden)) return null;
  return String.fromCharCodes(kept);
}
