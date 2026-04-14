import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

enum SocialPlatform { instagram, tiktok }

extension SocialPlatformX on SocialPlatform {
  String get label => switch (this) {
    SocialPlatform.instagram => 'Instagram',
    SocialPlatform.tiktok => 'TikTok',
  };
}

enum WatermarkPosition { none, topLeft, topRight, bottomLeft, bottomRight }
enum WatermarkTheme { black, white }

class RepostDraft {
  const RepostDraft({
    required this.sourceUrl,
    required this.platform,
    required this.videoPath,
    required this.thumbnailUrl,
    required this.author,
    required this.authorProfileImageUrl,
    required this.description,
  });

  final Uri sourceUrl;
  final SocialPlatform platform;
  final String videoPath;
  final String thumbnailUrl;
  final String author;
  final String authorProfileImageUrl;
  final String description;

  String get authorHandle {
    if (author.isEmpty) return '';
    return author.startsWith('@') ? author : '@$author';
  }

  String buildCaption(String customDescription) {
    final text = customDescription.trim();
    final handle = authorHandle;
    
    if (text.isEmpty) return handle;
    if (handle.isEmpty) return text;
    
    return '$text $handle';
  }
}

class RepostService {
  void _log(String message) {
    if (kDebugMode) print('[RepostService] $message');
  }

  static const _browserHeaders = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
    'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
    'Accept-Language': 'en-US,en;q=0.9',
    'Sec-Fetch-Dest': 'document',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Site': 'none',
    'Sec-Fetch-User': '?1',
    'Upgrade-Insecure-Requests': '1',
  };

  Future<RepostDraft> importPost(
    String rawUrl, {
    void Function(double)? onProgress,
  }) async {
    _log('Importing $rawUrl');
    final sourceUrl = _normalizeUrl(rawUrl);
    final platform = _detectPlatform(sourceUrl);
    if (platform == null) {
      _log('Platform detection failed for: $rawUrl');
      throw const FormatException('Paste an Instagram or TikTok post URL.');
    }

    _log('Detected platform: ${platform.label}');
    _ExtractedPost metadata;
    if (platform == SocialPlatform.tiktok) {
      _log('Using TikTok API...');
      metadata = await _extractTikTokViaApi(sourceUrl);
    } else {
      _log('Using Instagram logic...');
      metadata = await _extractInstagramMetadata(sourceUrl);
    }

    _log('Extracted Author: ${metadata.author}');
    _log('Extracted Profile Pic: ${metadata.authorProfileImageUrl}');
    _log('Extracted Thumb: ${metadata.thumbnailUrl}');
    _log('Extracted Caption: ${metadata.description}');

    final videoPath = await _downloadVideo(
      Uri.parse(metadata.videoUrl),
      sourceUrl: sourceUrl,
      platform: platform,
      onProgress: onProgress,
    );

    return RepostDraft(
      sourceUrl: sourceUrl,
      platform: platform,
      videoPath: videoPath,
      thumbnailUrl: metadata.thumbnailUrl,
      author: metadata.author,
      authorProfileImageUrl: metadata.authorProfileImageUrl,
      description: metadata.description,
    );
  }

  Uri _normalizeUrl(String rawUrl) {
    var trimmed = rawUrl.trim();
    if (trimmed.isEmpty) throw const FormatException('Paste a link first.');

    if (trimmed.contains('?')) {
      trimmed = trimmed.split('?').first;
    }

    final withScheme = trimmed.startsWith('http') ? trimmed : 'https://$trimmed';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) {
      throw const FormatException('That does not look like a valid URL.');
    }

    return uri;
  }

  SocialPlatform? _detectPlatform(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host.contains('instagram.com') || host.contains('instagr.am')) return SocialPlatform.instagram;
    if (host.contains('tiktok.com')) return SocialPlatform.tiktok;
    return null;
  }

  Future<String> _fetchPageHtml(Uri url, {Map<String, String>? headers}) async {
    final response = await http.get(url, headers: headers ?? _browserHeaders);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Server returned error ${response.statusCode}. The content might be private or restricted.',
      );
    }
    return response.body;
  }

  Future<_ExtractedPost> _extractTikTokViaApi(Uri sourceUrl) async {
    try {
      final apiUrl = Uri.https('www.tikwm.com', '/api/', {
        'url': sourceUrl.toString(),
      });
      final response = await http.get(apiUrl);
      final json = jsonDecode(response.body) as Map<String, dynamic>;

      if (json['code'] != 0) throw FormatException(json['msg'] ?? 'TikTok API error.');

      final data = json['data'] as Map<String, dynamic>;
      final videoUrl = data['play'] as String?;
      final thumbnailUrl = data['origin_cover'] as String? ?? data['cover'] as String? ?? '';
      if (videoUrl == null) throw const FormatException('No video found.');

      final author = data['author']?['unique_id'] as String? ?? 'tiktok_user';
      final authorData = data['author'] as Map<String, dynamic>?;
      final authorThumb = (authorData?['avatar_larger'] ?? authorData?['avatar_medium'] ?? authorData?['avatar_thumb'] ?? authorData?['avatar'] ?? '') as String;
      final description = data['title'] as String? ?? '';

      return _ExtractedPost(
        videoUrl: videoUrl.startsWith('http') ? videoUrl : 'https://www.tikwm.com$videoUrl',
        thumbnailUrl: thumbnailUrl,
        author: author,
        authorProfileImageUrl: authorThumb,
        description: description,
      );
    } catch (_) {
      final html = await _fetchPageHtml(sourceUrl);
      return _extractMetadata(
        html: html,
        platform: SocialPlatform.tiktok,
      );
    }
  }

  Future<_ExtractedPost> _extractInstagramMetadata(Uri sourceUrl) async {
    final patterns = [
      RegExp(r'/(?:p|reel|reels)/([^/?#&]+)'),
      RegExp(r'/share/reel/([^/?#&]+)'),
    ];

    String? shortcode;
    for (final pattern in patterns) {
      final match = pattern.firstMatch(sourceUrl.path);
      if (match != null) {
        shortcode = match.group(1);
        break;
      }
    }

    shortcode ??= sourceUrl.pathSegments.firstWhere((s) => s.length > 5, orElse: () => '');
    if (shortcode == null || shortcode.isEmpty) {
      throw const FormatException('Could not find the Instagram post ID.');
    }

    try {
      final ajaxUrl = Uri.https('www.instagram.com', '/p/$shortcode/', {
        '__a': '1',
        '__d': 'dis',
      });

      final response = await http.get(ajaxUrl, headers: {
        ..._browserHeaders,
        'X-IG-App-ID': '936619743392459',
        'X-Requested-With': 'XMLHttpRequest',
      });

      if (response.statusCode == 200) {
        _log('Instagram AJAX successful.');
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final media = json['items']?[0] ?? json['graphql']?['shortcode_media'];
        if (media != null) {
          final videoUrl = media['video_versions']?[0]?['url'] ?? media['video_url'];
          if (videoUrl != null) {
            final thumbnailUrl = media['image_versions2']?['candidates']?[0]?['url'] ?? media['display_url'] ?? '';
            final authorThumb = media['user']?['profile_pic_url'] ?? '';
            return _ExtractedPost(
              videoUrl: videoUrl,
              thumbnailUrl: thumbnailUrl,
              author: media['user']?['username'] ?? media['owner']?['username'] ?? 'ig_user',
              authorProfileImageUrl: authorThumb,
              description: media['caption']?['text'] ?? media['edge_media_to_caption']?['edges']?[0]?['node']?['text'] ?? '',
            );
          }
        }
      }
    } catch (_) {}

    // Fetch main post page for caption extraction
    final postUrl = Uri.https('www.instagram.com', '/p/$shortcode/');
    final postHtml = await _fetchPageHtml(postUrl);

    // Extract caption from embedded JSON in the main page
    final caption = _extractCaptionFromInstagramHtml(postHtml);

    // Fetch embed page for video URL
    final embedUrl = Uri.https('www.instagram.com', '/p/$shortcode/embed/captioned/');
    final embedHtml = await _fetchPageHtml(embedUrl);

    var videoUrl = _decodeEscapedUrl(
      _firstMatch(embedHtml, [
        RegExp(r'"video_url":"([^"]+)"'),
        RegExp(r'video_url\\":\\"([^"]+)\\"'),
        RegExp(r'video_url\\?":\\?"([^"]+)'),
        // Additional patterns for different Instagram formats
        RegExp(r'"contentUrl":"([^"]+)"'),
        RegExp(r'contentUrl\\":\\"([^"]+)\\"'),
        RegExp(r'"url":"([^"]+\\.mp4[^"]*)"'),
        RegExp(r'"playbackURI":"([^"]+)"'),
        RegExp(r'videoUrl[^"]*"([^"]+)"'),
      ]),
    );

    // If embed page doesn't have video URL, try the main post page
    if (videoUrl == null) {
      _log('Embed page missing video URL, trying main post page...');
      videoUrl = _decodeEscapedUrl(
        _firstMatch(postHtml, [
          RegExp(r'"video_url":"([^"]+)"'),
          RegExp(r'video_url\\":\\"([^"]+)\\"'),
          RegExp(r'"videoVersions":\[\{[^}]*"url":"([^"]+)"'),
          RegExp(r'video_versions[^}]*"url":"([^"]+)"'),
          RegExp(r'"contentUrl":"([^"]+)"'),
        ]),
      );
    }

    if (videoUrl == null) {
      throw const FormatException('Could not extract video. The post may be private or require login.');
    }

    return _extractMetadata(
      html: postHtml,
      platform: SocialPlatform.instagram,
      providedVideoUrl: videoUrl,
      providedCaption: caption,
    );
  }

  _ExtractedPost _extractMetadata({
    required String html,
    required SocialPlatform platform,
    String? providedVideoUrl,
    String? providedCaption,
  }) {
    final document = html_parser.parse(html);

    String? metaByNames(List<String> names) {
      for (final name in names) {
        final element = document.querySelector(
          'meta[property="$name"], meta[name="$name"], meta[property="og:$name"]',
        );
        final content = element?.attributes['content']?.trim();
        if (content != null && content.isNotEmpty) return _decodeHtml(content);
      }
      return null;
    }

    final videoUrl = providedVideoUrl ??
        metaByNames(['og:video', 'og:video:url', 'og:video:secure_url', 'video']) ??
        _firstMatch(html, [
          RegExp(r'"video_url":"([^"]+)"'),
          RegExp(r'video_url\\":\\"([^"]+)\\"'),
          RegExp(r'"playAddr":"([^"]+)"'),
          RegExp(r'"downloadAddr":"([^"]+)"'),
          RegExp(r'contentUrl":"([^"]+)"'),
        ]);

    if (videoUrl == null) throw const FormatException('Could not find the video source.');

    final thumbnailUrl = _decodeEscapedUrl(metaByNames(['og:image', 'og:image:secure_url', 'thumbnail_url', 'thumbnail', 'twitter:image']) ??
        _firstMatch(html, [
          RegExp(r'display_url\\":\\"([^"]+)\\"'),
          RegExp(r'thumbnail_src\\":\\"([^"]+)\\"'),
          RegExp(r'"display_url":"([^"]+)"'),
          RegExp(r'"thumbnail_url":"([^"]+)"'),
          RegExp(r'"origin_cover":"([^"]+)"'),
          RegExp(r'"cover":"([^"]+)"'),
          RegExp(r'"poster":"([^"]+)"'),
        ])) ?? '';

    // Use provided caption if available, otherwise try meta tags
    String description = providedCaption ?? '';
    
    // Fallback to meta description if no caption found
    if (description.isEmpty) {
      final metaDesc = metaByNames(['description', 'og:description', 'twitter:description']);
      if (metaDesc != null) {
        description = _cleanCaption(metaDesc);
      }
    }

    final author = _firstMatch(html, [
          RegExp(r'username\\":\\"([^"]+)\\"'),
          RegExp(r'owner_username\\":\\"([^"]+)\\"'),
          RegExp(r'"owner_username":"([^"]+)"'),
          RegExp(r'"username":"([A-Za-z0-9._]+)"'),
          RegExp(r'"uniqueId":"([A-Za-z0-9._]+)"'),
        ]) ??
        _authorFromText(
          platform: platform,
          text: metaByNames(['og:title', 'title']) ?? description,
        ) ??
        platform.label.toLowerCase();

    final authorProfileImageUrl = _decodeEscapedUrl(_firstMatch(html, [
          // The Nuclear Option: Broad discovery of any TikTok CDN Avatar URL (Top Priority)
          RegExp(r'(https?://[A-Za-z0-9\._\-]+tiktokcdn[A-Za-z0-9\._\-/:~?&=%]+(?:avt|avatar)[A-Za-z0-9\._\-/:~?&=%]+)'),
          RegExp(r'(https?%3A%2F%2F[A-Za-z0-9\._\-]+tiktokcdn[A-Za-z0-9\._\-%2F:~?&=%]+(?:avt|avatar)[A-Za-z0-9\._\-%2F:~?&=%]+)'),
          // Higher priority structural patterns for TikTok
          RegExp(r'"author":\{[^}]*"avatarThumb":"([^"]+)"\}'),
          RegExp(r'"author":\{[^}]*"avatar_thumb":"([^"]+)"\}'),
          RegExp(r'"user":\{[^}]*"avatarThumb":"([^"]+)"\}'),
          RegExp(r'"user":\{[^}]*"avatar_thumb":"([^"]+)"\}'),
          RegExp(r'"profile_pic_url":"([^"]+)"'),
          RegExp(r'profile_pic_url\\":\\"([^"]+)\\"'),
          RegExp(r'"avatar":"([^"]+)"'),
          RegExp(r'"avatarThumb":"([^"]+)"'),
          RegExp(r'avatarThumb\\":\\"([^"]+)\\"'),
          RegExp(r'"avatarLarger":"([^"]+)"'),
          RegExp(r'avatarLarger\\":\\"([^"]+)\\"'),
          RegExp(r'"avatar_larger":"([^"]+)"'),
          RegExp(r'"avatar_medium":"([^"]+)"'),
          RegExp(r'"avatar_thumb":"([^"]+)"'),
          RegExp(r'avatar_thumb\\":\\"([^"]+)\\"'),
          RegExp(r'avatar_larger\\":\\"([^"]+)\\"'),
          RegExp(r'"avatarThumb":\["([^"]+)"\]'),
          RegExp(r'"avatar_larger":\["([^"]+)"\]'),
          RegExp(r'avatar_larger\\":\[\\"([^"]+)\\"\]'),
          RegExp(r'avatar_thumb\\":\[\\"([^"]+)\\"\]'),
          // Broad TikTok CDN discovery (structured)
          RegExp(r'"(https://[^"]+tiktokcdn[^"]+(?:avt|avatar)[^"]+)"'),
          RegExp(r'\\"(https://[^"]+tiktokcdn[^"]+(?:avt|avatar)[^"]+)\\"'),
          RegExp(r'"avatar[^"]*":"([^"]+)"'),
          RegExp(r'avatar[^"]*\\":\\"([^"]+)\\"'),
        ])) ?? '';

    if (authorProfileImageUrl.isEmpty && thumbnailUrl.isNotEmpty) {
      _log('Warning: Found thumbnail but failed to extract profile pic.');
    }

    return _ExtractedPost(
      videoUrl: videoUrl,
      thumbnailUrl: thumbnailUrl,
      description: description,
      author: author,
      authorProfileImageUrl: authorProfileImageUrl,
    );
  }

  String? _authorFromText({required SocialPlatform platform, required String text}) {
    if (text.isEmpty) return null;
    final handleMatch = RegExp(r'@([A-Za-z0-9._]+)').firstMatch(text);
    if (handleMatch != null) return handleMatch.group(1);

    switch (platform) {
      case SocialPlatform.instagram:
        final match = RegExp(r'([A-Za-z0-9._]+)(?:\s+\(@[A-Za-z0-9._]+\))?\s+on Instagram').firstMatch(text);
        return match?.group(1);
      case SocialPlatform.tiktok:
        final match = RegExp(r'([A-Za-z0-9._]+)\s+on TikTok').firstMatch(text);
        return match?.group(1);
    }
    return null;
  }

  String? _firstMatch(String text, List<RegExp> patterns) {
    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      if (match != null) {
        final group = match.group(1);
        if (group != null && group.trim().isNotEmpty) return group.trim();
      }
    }
    return null;
  }

  String _decodeHtml(String value) {
    final decodedEntities = html_parser.parseFragment(value).text ?? value;
    return _decodeEscapedUrl(decodedEntities) ?? decodedEntities;
  }

  /// Extracts caption from Instagram HTML embedded JSON data
  String _extractCaptionFromInstagramHtml(String html) {
    // Patterns for caption in embedded JSON
    final patterns = [
      // edge_media_to_caption format (most common)
      RegExp(r'edge_media_to_caption\":\{\"edges\":\[\{\"node\":\{\"text\":\"([^"]+)\"'),
      RegExp(r'"edge_media_to_caption":\{"edges":\[\{"node":\{"text":"([^"]+)"'),
      // Direct caption.text format
      RegExp(r'\"caption\":\{\"text\":\"([^"]+)\"'),
      RegExp(r'"caption":\{"text":"([^"]+)"'),
      // Shortcode media caption
      RegExp(r'shortcode_media[^}]*?\"caption\":\{\"text\":\"([^"]+)\"'),
    ];

    for (final pattern in patterns) {
      final match = pattern.firstMatch(html);
      if (match != null) {
        final raw = match.group(1);
        if (raw != null && raw.isNotEmpty) {
          final decoded = _decodeEscapedUrl(raw) ?? raw;
          final cleaned = _cleanCaption(decoded);
          if (cleaned.isNotEmpty) {
            _log('Found caption via pattern: ${pattern.pattern.substring(0, pattern.pattern.length > 30 ? 30 : pattern.pattern.length)}...');
            return cleaned;
          }
        }
      }
    }
    return '';
  }

  /// Cleans caption by removing auto-generated prefixes and rejecting invalid content
  String _cleanCaption(String text) {
    if (text.isEmpty) return '';

    // Decode HTML entities and escaped characters
    var cleaned = _decodeHtml(text);

    // Reject generic Instagram landing page / login page text
    final invalidPatterns = [
      RegExp(r'create an account or log in', caseSensitive: false),
      RegExp("share what you're into", caseSensitive: false),
      RegExp(r'sign up to see photos', caseSensitive: false),
      RegExp(r'log in to see this', caseSensitive: false),
      RegExp(r'log in to continue', caseSensitive: false),
      RegExp(r'sign up.*instagram', caseSensitive: false),
      RegExp(r'get the app.*instagram', caseSensitive: false),
    ];

    for (final pattern in invalidPatterns) {
      if (pattern.hasMatch(cleaned)) {
        return '';
      }
    }

    // Remove auto-generated Instagram prefixes
    final prefixes = [
      RegExp(r'^Instagram post by [^,]+,\s*', caseSensitive: false),
      RegExp(r'^Photo by [^,]+ on Instagram[:\s]*', caseSensitive: false),
      RegExp(r'^Photo by [^.]+\.\s*', caseSensitive: false),
      RegExp(r'^[^,]+ on Instagram[:\s]*', caseSensitive: false),
      RegExp(r'^Watch this video by [^,]+ on Instagram[:\s]*', caseSensitive: false),
    ];

    for (final prefix in prefixes) {
      cleaned = cleaned.replaceFirst(prefix, '');
    }

    // Trim whitespace and newlines
    cleaned = cleaned.trim();

    // Return empty if what remains looks like auto-generated text
    if (RegExp(r'^(Instagram|Photo by|Watch)', caseSensitive: false).hasMatch(cleaned)) {
      return '';
    }

    return cleaned;
  }

  String? _decodeEscapedUrl(String? url) {
    if (url == null) return null;
    try {
      // Collapse literal double-escaped backslashes (\\u -> \u)
      var safe = url.replaceAll(r'\\u', r'\u').replaceAll('"', r'\"');
      return jsonDecode('"$safe"').toString().replaceAll(RegExp(r'\\+/'), '/');
    } catch (e) {
      // Fallback to manual cleaning if jsonDecode fails
      return url
          .replaceAll(RegExp(r'\\+/'), '/')
          .replaceAll(r'\u002F', '/')
          .replaceAll(r'\u0026', '&')
          .replaceAll(r'\u003D', '=')
          .replaceAll(r'\n', '\n')
          .replaceAll(r'\"', '"');
    }
  }

  Future<String> _downloadVideo(
    Uri videoUrl, {
    required Uri sourceUrl,
    required SocialPlatform platform,
    void Function(double)? onProgress,
  }) async {
    final request = http.Request('GET', videoUrl)
      ..headers.addAll(_browserHeaders)
      ..headers['Referer'] = '${sourceUrl.scheme}://${sourceUrl.host}/';
    final streamed = await request.send();

    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw HttpException('Download failed (Status ${streamed.statusCode}).');
    }

    final contentLength = streamed.contentLength;
    var downloaded = 0;
    final fileName = '${platform.name}_${DateTime.now().millisecondsSinceEpoch}.mp4';
    final baseDir = await getTemporaryDirectory();
    final parentDir = Directory(p.join(baseDir.path, 'reposts'));
    if (!await parentDir.exists()) await parentDir.create(recursive: true);

    final filePath = p.join(parentDir.path, fileName);
    _log('Downloading video to: $filePath');
    final file = File(filePath);
    final sink = file.openWrite();

    await for (final chunk in streamed.stream) {
      downloaded += chunk.length;
      if (contentLength != null && onProgress != null) onProgress(downloaded / contentLength);
      sink.add(chunk);
    }

    await sink.close();
    return file.path;
  }
}

class _ExtractedPost {
  const _ExtractedPost({
    required this.videoUrl,
    required this.thumbnailUrl,
    required this.description,
    required this.author,
    required this.authorProfileImageUrl,
  });

  final String videoUrl;
  final String thumbnailUrl;
  final String description;
  final String author;
  final String authorProfileImageUrl;
}
