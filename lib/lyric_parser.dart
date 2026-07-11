class LyricLine {
  const LyricLine({required this.time, required this.text});

  final Duration? time;
  final String text;
}

const _lyricLinesCacheLimit = 24;
final Map<String, List<LyricLine>> _lyricLinesCache = {};
final RegExp _timestampPattern = RegExp(
  r'\[(\d{1,2}):([0-5]\d)(?:[.:](\d{1,3}))?\]',
);
final RegExp _offsetPattern = RegExp(
  r'^\s*\[offset:([+-]?\d+)\]\s*$',
  caseSensitive: false,
);

List<LyricLine> parseLyricLines(String? rawLyrics) {
  final raw = rawLyrics?.trim();
  if (raw == null || raw.isEmpty) {
    return const [];
  }

  final cached = _lyricLinesCache.remove(raw);
  if (cached != null) {
    _lyricLinesCache[raw] = cached;
    return cached;
  }

  final rawLines = raw.split(RegExp(r'[\r\n]+'));
  var offsetMilliseconds = 0;
  for (final rawLine in rawLines) {
    final offsetMatch = _offsetPattern.firstMatch(rawLine);
    if (offsetMatch != null) {
      offsetMilliseconds = int.tryParse(offsetMatch.group(1) ?? '') ?? 0;
    }
  }

  final lines = <_ParsedRawLyricLine>[];
  var hasTimedLine = false;
  var hasUntimedLine = false;
  for (final rawLine in rawLines) {
    final matches = _timestampPattern.allMatches(rawLine).toList();
    final text = matches.isEmpty
        ? rawLine.trim()
        : rawLine.substring(matches.last.end).trim();
    if (text.isEmpty || (matches.isEmpty && _isLrcMetadata(text))) {
      continue;
    }
    lines.add(_ParsedRawLyricLine(text: text, timestamps: matches));
    if (matches.isEmpty) {
      hasUntimedLine = true;
    } else {
      hasTimedLine = true;
    }
  }

  final parsed = <LyricLine>[];
  if (hasTimedLine && !hasUntimedLine) {
    for (final line in lines) {
      for (final timestamp in line.timestamps) {
        parsed.add(
          LyricLine(
            time: _parseLyricTimestamp(timestamp, offsetMilliseconds),
            text: line.text,
          ),
        );
      }
    }
    parsed.sort((a, b) => a.time!.compareTo(b.time!));
  } else {
    // Partially timestamped lyrics are not safe to seek. Preserve every line,
    // but treat the whole document as plain lyrics so a tap cannot jump to an
    // unrelated (or out-of-range) position and advance playback.
    parsed.addAll([
      for (final line in lines) LyricLine(time: null, text: line.text),
    ]);
  }

  final result = List<LyricLine>.unmodifiable(parsed);
  _lyricLinesCache[raw] = result;
  if (_lyricLinesCache.length > _lyricLinesCacheLimit) {
    _lyricLinesCache.remove(_lyricLinesCache.keys.first);
  }
  return result;
}

bool isLyricTimestampSeekable(Duration? timestamp, Duration duration) {
  return timestamp != null &&
      duration > Duration.zero &&
      timestamp >= Duration.zero &&
      timestamp < duration;
}

bool _isLrcMetadata(String line) {
  return RegExp(
    r'^\[(?:ar|al|ti|au|by|offset|length|re|ve):.*\]$',
    caseSensitive: false,
  ).hasMatch(line);
}

Duration _parseLyricTimestamp(RegExpMatch match, int offsetMilliseconds) {
  final minutes = int.tryParse(match.group(1) ?? '') ?? 0;
  final seconds = int.tryParse(match.group(2) ?? '') ?? 0;
  final fraction = match.group(3) ?? '0';
  final milliseconds = switch (fraction.length) {
    1 => (int.tryParse(fraction) ?? 0) * 100,
    2 => (int.tryParse(fraction) ?? 0) * 10,
    _ => int.tryParse(fraction.padRight(3, '0').substring(0, 3)) ?? 0,
  };
  final timestamp = Duration(
    minutes: minutes,
    seconds: seconds,
    milliseconds: milliseconds,
  );
  final shiftedMilliseconds = timestamp.inMilliseconds + offsetMilliseconds;
  return Duration(
    milliseconds: shiftedMilliseconds < 0 ? 0 : shiftedMilliseconds,
  );
}

class _ParsedRawLyricLine {
  const _ParsedRawLyricLine({required this.text, required this.timestamps});

  final String text;
  final List<RegExpMatch> timestamps;
}
