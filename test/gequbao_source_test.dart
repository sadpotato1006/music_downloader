import 'package:flutter_test/flutter_test.dart';
import 'package:qingting/gequbao_source.dart';
import 'package:qingting/models.dart';
import 'package:qingting/storage_service.dart';

void main() {
  final baseUrl = Uri.parse('https://www.gequbao.com/');

  test('parses search result anchors from public HTML', () {
    const html = '''
      <html>
        <body>
          <a href="/music/123">1 告白气球 - 周杰伦 2026-06-13</a>
          <a href="/music/456">夜曲 - 周杰伦</a>
          <a href="/s/周杰伦">周杰伦</a>
        </body>
      </html>
    ''';

    final results = GequbaoParser.parseSearchResults(html, baseUrl: baseUrl);

    expect(results, hasLength(2));
    expect(results.first.id, '123');
    expect(results.first.title, '告白气球');
    expect(results.first.artist, '周杰伦');
    expect(results.first.detailUrl, 'https://www.gequbao.com/music/123');
  });

  test('filters community activity links from search results', () {
    const html = '''
      <html>
        <body>
          <a href="/music/100">网友刚刚下载了 有些 - 颜人中</a>
          <a href="/music/101">网友刚刚搜索了 其实 - DJ阿智&DJ阿布</a>
          <a href="/music/102">等下一个天亮 - 郭静</a>
        </body>
      </html>
    ''';

    final results = GequbaoParser.parseSearchResults(html, baseUrl: baseUrl);

    expect(results, hasLength(1));
    expect(results.single.id, '102');
    expect(results.single.title, '等下一个天亮');
    expect(results.single.artist, '郭静');
  });

  test('extracts nearby cover urls from search results', () {
    const html = '''
      <html>
        <body>
          <div class="result">
            <img data-original="/cover/search-one.webp">
            <a href="/music/200">稻香 - 周杰伦</a>
          </div>
          <div class="result">
            <div class="cover" style="background-image: url('/upload/search-two.jpg')"></div>
            <div><a href="/music/201">晴天 - 周杰伦</a></div>
          </div>
        </body>
      </html>
    ''';

    final results = GequbaoParser.parseSearchResults(html, baseUrl: baseUrl);

    expect(results, hasLength(2));
    expect(
      results.first.coverUrl,
      'https://www.gequbao.com/cover/search-one.webp',
    );
    expect(
      results.last.coverUrl,
      'https://www.gequbao.com/upload/search-two.jpg',
    );
  });

  test('parses detail candidates and prefers mp3', () {
    const html = r'''
      <html>
        <head><title>夜曲 - 周杰伦 - 歌曲宝</title></head>
        <body>
          歌名：夜曲
          歌手：周杰伦
          <a href="/download/night.flac">FLAC</a>
          <audio src="https:\/\/cdn.example.test\/night.mp3?token=abc"></audio>
        </body>
      </html>
    ''';
    const fallback = TrackSearchResult(
      id: '456',
      title: '夜曲',
      artist: '周杰伦',
      source: '歌曲宝',
      detailUrl: 'https://www.gequbao.com/music/456',
    );

    final detail = GequbaoParser.parseTrackDetail(
      html,
      baseUrl: baseUrl,
      fallback: fallback,
    );

    expect(detail.title, '夜曲');
    expect(detail.artist, '周杰伦');
    expect(detail.candidates, hasLength(2));
    expect(detail.candidates.first.format, 'mp3');
  });

  test('parses escaped appData from detail page HTML', () {
    const html = r'''
      <script>
        window.appData = JSON.parse('{\u0022mp3_id\u0022:4195,\u0022play_id\u0022:\u0022abc123\u0022,\u0022mp3_title\u0022:\u0022\\u544a\\u767d\\u6c14\\u7403\u0022,\u0022mp3_author\u0022:\u0022\\u5468\\u6770\\u4f26\u0022}');
      </script>
    ''';

    final data = GequbaoParser.parseAppData(html);

    expect(data?['mp3_id'], 4195);
    expect(data?['play_id'], 'abc123');
    expect(data?['mp3_title'], '告白气球');
    expect(data?['mp3_author'], '周杰伦');
  });

  test('extracts lrc lyrics from detail page text', () {
    const html = '''
      <html>
        <body>
          <div>[00:00.00]Song - Artist [00:01.00]...</div>
          <button>下载歌词</button>
          <section>
            [00:00.00]Song - Artist
            [00:01.00]line one
            [00:02.50]line two
          </section>
        </body>
      </html>
    ''';
    const fallback = TrackSearchResult(
      id: '789',
      title: 'Song',
      artist: 'Artist',
      source: '歌曲宝',
      detailUrl: 'https://www.gequbao.com/music/789',
    );

    final detail = GequbaoParser.parseTrackDetail(
      html,
      baseUrl: baseUrl,
      fallback: fallback,
    );

    expect(
      detail.lyrics,
      '[00:00.00]Song - Artist\n[00:01.00]line one\n[00:02.50]line two',
    );
  });

  test('strips html break tags from extracted lrc lyrics', () {
    const html = r'''
      <html>
        <body>
          <div class="lrc">
            [00:00.00]Song - Artist<br />
            [00:01.00]line one<br>
            [00:02.50]line two&lt;br /&gt;
          </div>
        </body>
      </html>
    ''';
    const fallback = TrackSearchResult(
      id: '790',
      title: 'Song',
      artist: 'Artist',
      source: '歌曲宝',
      detailUrl: 'https://www.gequbao.com/music/790',
    );

    final detail = GequbaoParser.parseTrackDetail(
      html,
      baseUrl: baseUrl,
      fallback: fallback,
    );

    expect(detail.lyrics, isNot(contains('<br')));
    expect(detail.lyrics, isNot(contains('&lt;br')));
    expect(
      detail.lyrics,
      '[00:00.00]Song - Artist\n[00:01.00]line one\n[00:02.50]line two',
    );
  });

  test('extracts cover url from detail page metadata', () {
    const html = '''
      <html>
        <head>
          <meta property="og:image" content="/cover/song.jpg">
        </head>
        <body>Song</body>
      </html>
    ''';
    const fallback = TrackSearchResult(
      id: '791',
      title: 'Song',
      artist: 'Artist',
      source: '歌曲宝',
      detailUrl: 'https://www.gequbao.com/music/791',
    );

    final detail = GequbaoParser.parseTrackDetail(
      html,
      baseUrl: baseUrl,
      fallback: fallback,
    );

    expect(detail.coverUrl, 'https://www.gequbao.com/cover/song.jpg');
  });

  test('sanitizes Windows and Android hostile file names', () {
    final name = StorageService.safeTrackBaseName(
      title: 'A:B/C*D?',
      artist: '周杰伦<>',
    );

    expect(name, '周杰伦 - A B C D');
    expect(name.contains(RegExp(r'[<>:"/\\|?*]')), isFalse);
  });
}
