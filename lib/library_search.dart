import 'package:lpinyin/lpinyin.dart';

import 'models.dart';

class LibrarySearch {
  const LibrarySearch._();

  static bool matchesDownloadedTrack(
    DownloadedTrack track,
    String query, {
    String? lyrics,
  }) {
    final normalizedQuery = normalize(query);
    if (normalizedQuery.isEmpty) {
      return true;
    }

    return LibrarySearchIndex.fromTrack(
      track,
      lyrics: lyrics,
    ).matchesNormalizedQuery(normalizedQuery);
  }

  static bool matchesText(String text, String normalizedQuery) {
    if (text.trim().isEmpty || normalizedQuery.isEmpty) {
      return false;
    }
    final normalizedText = normalize(text);
    if (normalizedText.contains(normalizedQuery)) {
      return true;
    }

    final pinyinInitials = normalize(_safeShortPinyin(text));
    if (pinyinInitials.contains(normalizedQuery)) {
      return true;
    }
    if (_isClosePinyinInitialQuery(normalizedQuery, pinyinInitials)) {
      return true;
    }

    final fullPinyin = normalize(_safeFullPinyin(text));
    return fullPinyin.contains(normalizedQuery);
  }

  static String normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(_noisePattern, '')
        .replaceAll(RegExp(r'\s+'), '');
  }

  static String _safeShortPinyin(String text) {
    try {
      return PinyinHelper.getShortPinyin(text);
    } catch (_) {
      return '';
    }
  }

  static String _safeFullPinyin(String text) {
    try {
      return PinyinHelper.getPinyin(text, separator: '');
    } catch (_) {
      return '';
    }
  }

  static bool _isClosePinyinInitialQuery(String query, String initials) {
    if (!_asciiLetterPattern.hasMatch(query) || initials.length < 2) {
      return false;
    }
    final foldedInitials = _foldRepeatedAsciiLetters(initials);
    if (foldedInitials.contains(query)) {
      return true;
    }
    if (query.length < 3 || query.length > 6) {
      return false;
    }
    return _editDistanceAtMostOne(query, foldedInitials);
  }

  static String _foldRepeatedAsciiLetters(String value) {
    final buffer = StringBuffer();
    var previous = '';
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune);
      if (char != previous) {
        buffer.write(char);
      }
      previous = char;
    }
    return buffer.toString();
  }

  static bool _editDistanceAtMostOne(String left, String right) {
    if ((left.length - right.length).abs() > 1) {
      return false;
    }

    var leftIndex = 0;
    var rightIndex = 0;
    var edits = 0;
    while (leftIndex < left.length && rightIndex < right.length) {
      if (left.codeUnitAt(leftIndex) == right.codeUnitAt(rightIndex)) {
        leftIndex += 1;
        rightIndex += 1;
        continue;
      }
      edits += 1;
      if (edits > 1) {
        return false;
      }
      if (left.length > right.length) {
        leftIndex += 1;
      } else if (right.length > left.length) {
        rightIndex += 1;
      } else {
        leftIndex += 1;
        rightIndex += 1;
      }
    }

    if (leftIndex < left.length || rightIndex < right.length) {
      edits += 1;
    }
    return edits <= 1;
  }

  static final RegExp _noisePattern = RegExp(
    r'''[\s\-_.,，。·・/\\:：;；'"“”‘’!?！？()[\]{}<>《》【】]+''',
  );
  static final RegExp _asciiLetterPattern = RegExp(r'^[a-z]+$');
}

class LibrarySearchIndex {
  LibrarySearchIndex._({
    required this.normalizedText,
    required this.pinyinInitials,
    required this.foldedPinyinInitials,
    required this.fullPinyin,
    required this.fieldPinyinInitials,
    required this.fieldFullPinyin,
    required this.normalizedLyrics,
  });

  factory LibrarySearchIndex.fromTrack(
    DownloadedTrack track, {
    String? lyrics,
  }) {
    final metadataFields = [
      track.title,
      track.artist,
      track.album,
    ].where((value) => value.trim().isNotEmpty).toList();
    final metadataText = metadataFields.join(' ');
    final pinyinInitials = LibrarySearch.normalize(
      LibrarySearch._safeShortPinyin(metadataText),
    );
    return LibrarySearchIndex._(
      normalizedText: LibrarySearch.normalize(metadataText),
      pinyinInitials: pinyinInitials,
      foldedPinyinInitials: LibrarySearch._foldRepeatedAsciiLetters(
        pinyinInitials,
      ),
      fullPinyin: LibrarySearch.normalize(
        LibrarySearch._safeFullPinyin(metadataText),
      ),
      fieldPinyinInitials: [
        for (final field in metadataFields)
          LibrarySearch.normalize(LibrarySearch._safeShortPinyin(field)),
      ],
      fieldFullPinyin: [
        for (final field in metadataFields)
          LibrarySearch.normalize(LibrarySearch._safeFullPinyin(field)),
      ],
      normalizedLyrics: LibrarySearch.normalize(lyrics ?? ''),
    );
  }

  final String normalizedText;
  final String pinyinInitials;
  final String foldedPinyinInitials;
  final String fullPinyin;
  final List<String> fieldPinyinInitials;
  final List<String> fieldFullPinyin;
  final String normalizedLyrics;

  bool matchesNormalizedQuery(String normalizedQuery) {
    if (normalizedQuery.isEmpty) {
      return true;
    }
    if (normalizedText.contains(normalizedQuery) ||
        normalizedLyrics.contains(normalizedQuery) ||
        pinyinInitials.contains(normalizedQuery) ||
        foldedPinyinInitials.contains(normalizedQuery) ||
        fullPinyin.contains(normalizedQuery) ||
        fieldFullPinyin.any((field) => field.contains(normalizedQuery)) ||
        fieldPinyinInitials.any(
          (field) =>
              field.contains(normalizedQuery) ||
              LibrarySearch._foldRepeatedAsciiLetters(
                field,
              ).contains(normalizedQuery),
        )) {
      return true;
    }
    return fieldPinyinInitials.any(
      (field) =>
          LibrarySearch._isClosePinyinInitialQuery(normalizedQuery, field),
    );
  }
}
