import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

enum SocialPlatform { instagram, tiktok }

extension SocialPlatformX on SocialPlatform {
  String get label => switch (this) {
    SocialPlatform.instagram => 'Instagram',
    SocialPlatform.tiktok => 'TikTok',
  };
}

enum WatermarkPosition { none, topLeft, topRight, bottomLeft, bottomRight }
enum WatermarkTheme { black, white }

int? _parseNumberWithSuffix(String text) {
  final clean = text.replaceAll(',', '').toUpperCase().trim();
  if (clean.endsWith('K')) {
    final num = double.tryParse(clean.substring(0, clean.length - 1));
    return num != null ? (num * 1000).toInt() : null;
  } else if (clean.endsWith('M')) {
    final num = double.tryParse(clean.substring(0, clean.length - 1));
    return num != null ? (num * 1000000).toInt() : null;
  } else if (clean.endsWith('B')) {
    final num = double.tryParse(clean.substring(0, clean.length - 1));
    return num != null ? (num * 1000000000).toInt() : null;
  }
  final d = double.tryParse(clean);
  return d?.toInt();
}

class RepostDraft {
  const RepostDraft({
    required this.sourceUrl,
    required this.platform,
    required this.videoPath,
    required this.thumbnailUrl,
    required this.author,
    required this.authorProfileImageUrl,
    required this.description,
    this.likes,
    this.comments,
    this.views,
  });

  final Uri sourceUrl;
  final SocialPlatform platform;
  final String videoPath;
  final String thumbnailUrl;
  final String author;
  final String authorProfileImageUrl;
  final String description;
  final int? likes;
  final int? comments;
  final int? views;

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

  Future<String> resolveCanonicalUrl(String rawUrl) async {
    try {
      final uri = _normalizeUrl(rawUrl);
      final platform = _detectPlatform(uri);
      
      if (platform == SocialPlatform.tiktok) {
        if (uri.host.contains('vm.tiktok.com') || uri.host.contains('vt.tiktok.com')) {
          final request = http.Request('HEAD', uri)..followRedirects = false;
          final response = await http.Client().send(request);
          if (response.isRedirect && response.headers['location'] != null) {
            final redirectedUrl = Uri.parse(response.headers['location']!);
            return redirectedUrl.toString().split('?').first;
          }
        }
        return uri.toString().split('?').first;
      } else if (platform == SocialPlatform.instagram) {
        if (uri.host.contains('instagr.am')) {
           final request = http.Request('HEAD', uri)..followRedirects = false;
           final response = await http.Client().send(request);
           if (response.isRedirect && response.headers['location'] != null) {
             final redirectedUrl = Uri.parse(response.headers['location']!);
             return redirectedUrl.toString().split('?').first;
           }
        }
        final patterns = [
          RegExp(r'/(?:p|reel|reels)/([^/?#&]+)'),
        ];
        for (final pattern in patterns) {
          final match = pattern.firstMatch(uri.path);
          if (match != null) {
            return 'https://www.instagram.com/reel/${match.group(1)}/';
          }
        }
        return uri.toString().split('?').first;
      }
      return uri.toString().split('?').first;
    } catch (_) {
      return rawUrl.split('?').first;
    }
  }

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
      likes: metadata.likes,
      comments: metadata.comments,
      views: metadata.views,
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
    return uri ?? Uri.parse(withScheme);
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
    
    final html = response.body;
    // Check for common signs of a login wall or bot detection page
    if (html.contains('login') && 
        (html.contains('accounts/login') || html.contains('login_page')) && 
        !html.contains('shortcode_media')) {
      _log('Login wall detected.');
      throw const FormatException('Instagram is temporarily restricting access. Please try again in 10-20 seconds.');
    }
    
    return html;
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
        likes: data['digg_count'] is int ? data['digg_count'] : int.tryParse(data['digg_count']?.toString() ?? ''),
        comments: data['comment_count'] is int ? data['comment_count'] : int.tryParse(data['comment_count']?.toString() ?? ''),
        views: data['play_count'] is int ? data['play_count'] : int.tryParse(data['play_count']?.toString() ?? ''),
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
    try {
      return await _doExtractInstagramMetadata(sourceUrl);
    } catch (e) {
      // If we hit a temporary block, try one more time after a short delay
      if (e.toString().contains('temporarily restricting access')) {
        _log('Retrying Instagram extraction after 2s delay...');
        await Future.delayed(const Duration(seconds: 2));
        return await _doExtractInstagramMetadata(sourceUrl);
      }
      rethrow;
    }
  }

  Future<_ExtractedPost> _doExtractInstagramMetadata(Uri sourceUrl) async {
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

    int? likes;
    int? comments;
    int? views;

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
            // Priority: screenshot_url (cleanest), then image candidates, then display_url
            final candidates = media['image_versions2']?['candidates'] as List<dynamic>?;
            final thumbnailUrl = _cleanUrl(media['screenshot_url'] ?? 
                media['video_versions']?[0]?['screenshot_url'] ??
                candidates?[0]?['url'] ?? 
                candidates?.lastOrNull?['url'] ?? 
                media['display_url'] ?? '');
            final authorThumb = _cleanUrl(media['user']?['profile_pic_url'] ?? '');
            return _ExtractedPost(
              videoUrl: videoUrl,
              thumbnailUrl: thumbnailUrl ?? '',
              author: media['user']?['username'] ?? media['owner']?['username'] ?? 'ig_user',
              authorProfileImageUrl: authorThumb ?? '',
              description: media['caption']?['text'] ?? media['edge_media_to_caption']?['edges']?[0]?['node']?['text'] ?? '',
              likes: media['like_count'] ?? media['edge_media_preview_like']?['count'],
              comments: media['comment_count'] ?? media['edge_media_to_comment']?['count'],
              views: media['view_count'] ?? media['video_view_count'],
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

    // --- Smart Thumbnail Extraction (Reference-Match Strategy) ---
    // 1. Get a "Reference URL" that we KNOW belongs to this reel (from embed or og:tags)
    final referenceUrl = _cleanUrl(
      _firstMatch(embedHtml, [
        RegExp(r'screenshot_url\\?":\\?"(https?:[^"]+)"'),
        RegExp(r'"display_url":"([^"]+)"'),
      ]) ?? _firstMatch(postHtml, [
        RegExp(r'<meta[^>]*?property="og:image"[^>]*?content="([^"]+)"'),
        RegExp(r'"display_url":"([^"]+)"'),
      ]),
    );

    String? cleanThumb;
    if (referenceUrl != null) {
      // 2. Extract the unique file ID from the reference URL
      // Example: .../12345_67890_n.jpg -> 12345_67890
      final fileIdMatch = RegExp(r'/([A-Za-z0-9_]+)_n\.jpg').firstMatch(referenceUrl);
      final fileId = fileIdMatch?.group(1);
      
      if (fileId != null) {
        _log('Reference ID found: $fileId. Searching for high-res variant...');
        // 3. Search for the BEST version of THIS SPECIFIC file (InhwaWRz/XPIDS)
        cleanThumb = _cleanUrl(
          _firstMatch(postHtml + embedHtml, [
            RegExp('(https?:[^"]+$fileId[^"]+InhwaWRz[^"]+)'),
            RegExp('(https?:[^"]+$fileId[^"]+dst-jpegr[^"]+)'),
          ]),
        );
      }
    }

    // Step 4: Fallback to the reference URL if no high-res variant found
    cleanThumb ??= referenceUrl;

    // --- Anchored Stats Extraction (Temporarily Disabled for Instagram) ---
    final int? anchoredLikes = null;
    final int? anchoredComments = null;
    final int? anchoredViews = null;

    return _extractMetadata(
      html: postHtml,
      platform: SocialPlatform.instagram,
      providedVideoUrl: videoUrl,
      providedCaption: caption,
      providedThumbnailUrl: cleanThumb,
      providedLikes: anchoredLikes,
      providedComments: anchoredComments,
      providedViews: anchoredViews,
    );
  }

  _ExtractedPost _extractMetadata({
    required String html,
    required SocialPlatform platform,
    String? providedVideoUrl,
    String? providedCaption,
    String? providedThumbnailUrl,
    int? providedLikes,
    int? providedComments,
    int? providedViews,
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

    final thumbnailUrl = providedThumbnailUrl ??
        _cleanUrl(_firstMatch(html, [
              // Try high-resolution markers first
              RegExp(r'display_url\\?":\\?"(https?:[^"]+InhwaWRz[^"]+)"'),
              RegExp(r'"display_url":"([^"]+InhwaWRz[^"]+)"'),
              RegExp(r'screenshot_url\\?":\\?"(https?:[^"]+InhwaWRz[^"]+)"'),
              RegExp(r'"screenshot_url":"([^"]+InhwaWRz[^"]+)"'),
              // Then any screenshot_url
              RegExp(r'screenshot_url\\?":\\?"(https?:[^"]+)"'),
              RegExp(r'"screenshot_url":"([^"]+)"'),
              // Then specifically flagged high-res URLs
              RegExp(r'display_url\\?":\\?"(https?:[^"]+(?:1080x|1080|720x1280|1350)[^"]+)"'),
              // Then other specific markers
              RegExp(r'display_url\\?":\\?"(https?:[^"]+dst-jpegr[^"]+)"'),
              RegExp(r'"display_url":"([^"]+dst-jpegr[^"]+)"'),
              // Try thumbnail_src
              RegExp(r'thumbnail_src\\":\\"([^"]+)\\"'),
              RegExp(r'"thumbnail_src":"([^"]+)"'),
            ]) ??
            metaByNames(['og:image', 'og:image:secure_url', 'thumbnail_url', 'thumbnail', 'twitter:image']) ??
            _firstMatch(html, [
              // Fallback to other sources
              RegExp(r'display_url\\":\\"([^"]+)\\"'),
              RegExp(r'"display_url":"([^"]+)"'),
              RegExp(r'"thumbnail_url":"([^"]+)"'),
              RegExp(r'"origin_cover":"([^"]+)"'),
              RegExp(r'"cover":"([^"]+)"'),
              RegExp(r'"poster":"([^"]+)"'),
            ])) ??
        '';

    // Use provided caption if available
    final description = providedCaption ?? '';

    final author = _firstMatch(html, [
          RegExp(r'username\\":\\"([^"]+)\\"'),
          RegExp(r'owner_username\\":\\"([^"]+)\\"'),
          RegExp(r'"owner_username":"([^"]+)"'),
          RegExp(r'"username":"([A-Za-z0-9._]+)"'),
          RegExp(r'"uniqueId":"([A-Za-z0-9._]+)"'),
        ]) ??
        _authorFromText(
          platform: platform,
          text: metaByNames(['og:title', 'title', 'og:description', 'description']) ?? description,
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

    final likes = providedLikes ??
        _parseNumberWithSuffix(_firstMatch(html, [
          RegExp(r'"edge_media_preview_like":\{"count":(\d+)\}'),
          RegExp(r'edge_media_preview_like\\":\{\\"count\\":(\d+)\\}'),
          RegExp(r'([0-9,.]+K?M?B?)\s+Likes', caseSensitive: false),
          RegExp(r'like_count\\":(\d+)'),
          RegExp(r'"like_count":(\d+)'),
          RegExp(r'"diggCount":(\d+)'),
          RegExp(r'digg_count\\":(\d+)'),
        ]) ?? '') ?? 
        _statsFromMeta(html: html, labelPattern: 'likes');

    final comments = providedComments ??
        _parseNumberWithSuffix(_firstMatch(html, [
          RegExp(r'"edge_media_to_comment":\{"count":(\d+)\}'),
          RegExp(r'edge_media_to_comment\\":\{\\"count\\":(\d+)\\}'),
          RegExp(r'([0-9,.]+K?M?B?)\s+Comments', caseSensitive: false),
          RegExp(r'comment_count\\":(\d+)'),
          RegExp(r'"comment_count":(\d+)'),
          RegExp(r'"commentCount":(\d+)'),
          RegExp(r'comment_count\\":(\d+)'),
        ]) ?? '') ??
        _statsFromMeta(html: html, labelPattern: 'comments');

    final views = providedViews ??
        _parseNumberWithSuffix(_firstMatch(html, [
          RegExp(r'"video_view_count":(\d+)'),
          RegExp(r'video_view_count\\":(\d+)'),
          RegExp(r'([0-9,.]+K?M?B?)\s+Views', caseSensitive: false),
          RegExp(r'([0-9,.]+K?M?B?)\s+Plays', caseSensitive: false),
          RegExp(r'play_count\\":(\d+)'),
          RegExp(r'"play_count":(\d+)'),
          RegExp(r'"playCount":(\d+)'),
        ]) ?? '') ??
        _statsFromMeta(html: html, labelPattern: r'(?:views|plays)');

    final finalAuthor = author;

    _log('Extracted Author: $finalAuthor');
    _log('Extracted Profile Pic: $authorProfileImageUrl');
    _log('Extracted Thumb: $thumbnailUrl');
    if (description.isNotEmpty) {
      _log('Extracted Caption: ${description.substring(0, description.length > 50 ? 50 : description.length)}...');
    }
    _log('Extracted Likes: $likes');
    _log('Extracted Comments: $comments');
    _log('Extracted Views: $views');

    return _ExtractedPost(
      videoUrl: videoUrl,
      thumbnailUrl: thumbnailUrl,
      description: description,
      author: finalAuthor,
      authorProfileImageUrl: authorProfileImageUrl,
      likes: likes,
      comments: comments,
      views: views,
    );
  }

  String? _authorFromText({required SocialPlatform platform, required String text}) {
    if (text.isEmpty) return null;

    switch (platform) {
      case SocialPlatform.instagram:
        // Pattern 1: "Display Name (@handle) on Instagram" or "Display Name (@handle) • Instagram..."
        final handleInParens = RegExp(r'\(@([A-Za-z0-9._]+)\)').firstMatch(text);
        if (handleInParens != null) return handleInParens.group(1);

        // Pattern 2: "handle on Instagram" or "Display Name on Instagram"
        final onInstagram = RegExp(r'([^:@\n]+)\s+on Instagram').firstMatch(text);
        if (onInstagram != null) return onInstagram.group(1)?.trim();
        
        // Pattern 3: "138 likes, 6 comments - handle on April 15, 2026" (common in og:description)
        final descMatch = RegExp(r'(?:Likes|Comments)\s+-\s+([A-Za-z0-9._]+)\s+on\s+').firstMatch(text);
        if (descMatch != null) return descMatch.group(1);

        // Pattern 4: meta name="author" content="handle"
        final authorMeta = RegExp(r'''<meta[^>]*name=["\']author["\'][^>]*content=["\']([^"\']+)["\']''').firstMatch(text);
        if (authorMeta != null) {
           final val = authorMeta.group(1)!;
           if (!val.contains(' ')) return val; // Likely a handle if no spaces
        }
        break;

      case SocialPlatform.tiktok:
        final match = RegExp(r'([A-Za-z0-9._]+)\s+on TikTok').firstMatch(text);
        if (match != null) return match.group(1);
        break;
    }

    // Generic fallback: If the text IS just a handle, use it.
    // But don't just grab any @mention from a long caption.
    final handleMatch = RegExp(r'^@([A-Za-z0-9._]+)$').firstMatch(text.trim());
    if (handleMatch != null) return handleMatch.group(1);

    return null;
  }

  /// Extracts numeric stats (likes, comments, views) from DOM aria-labels and Meta tags
  int? _statsFromMeta({required String html, required String labelPattern}) {
    final document = html_parser.parse(html);

    // 1. Try DOM attributes (Aria-labels)
    final elements = document.querySelectorAll('*[aria-label]');
    for (final el in elements) {
      final ariaLabel = el.attributes['aria-label'] ?? '';
      final match = RegExp('([0-9,.]+K?M?B?)\\s+$labelPattern', caseSensitive: false)
          .firstMatch(ariaLabel);
      if (match != null) return _parseNumberWithSuffix(match.group(1)!);
    }

    // 2. Try Meta tags fallback
    final selectors = [
      'meta[property="og:description"]',
      'meta[name="description"]',
      'meta[property="og:title"]',
      'meta[name="title"]',
    ];

    for (final selector in selectors) {
      final el = document.querySelector(selector);
      final content = el?.attributes['content'] ?? '';
      if (content.isNotEmpty) {
        final match = RegExp('([0-9,.]+K?M?B?)\\s+$labelPattern', caseSensitive: false)
            .firstMatch(content);
        if (match != null) return _parseNumberWithSuffix(match.group(1)!);
      }
    }

    // 3. Last resort: Greedy text search in whole HTML
    final greedyMatch = RegExp('([0-9,.]+K?M?B?)\\s+$labelPattern', caseSensitive: false)
        .firstMatch(html);
    if (greedyMatch != null) return _parseNumberWithSuffix(greedyMatch.group(1)!);

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

  String? _cleanUrl(String? url) {
    if (url == null) return null;
    
    // Decode HTML entities (like &amp;)
    var decoded = html_parser.parseFragment(url).text ?? url;
    
    // Handle escaped JSON URLs (https:\/\/...)
    decoded = _decodeEscapedUrl(decoded) ?? decoded;
    
    // If it's a srcset (contains multiple URLs followed by descriptors like '640w'), take the first URL
    if (decoded.contains(' ')) {
      // Split by whitespace and take the first token
      decoded = decoded.split(RegExp(r'\s+')).first;
    }
    
    // Remove trailing commas if any
    if (decoded.endsWith(',')) {
      decoded = decoded.substring(0, decoded.length - 1);
    }
    
    return decoded.trim();
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

  /// Downloads an image from [url] to a local cache directory and returns the
  /// local file path. Returns `null` if the download fails or the URL is empty.
  /// If a cached file already exists for this URL, returns it immediately.
  static Future<String?> cacheImageLocally(String url, {String prefix = 'img'}) async {
    if (url.isEmpty) return null;
    try {
      // Create a stable filename from the URL (use hash to avoid path issues)
      final hash = url.hashCode.toUnsigned(32).toRadixString(16);
      final ext = url.contains('.png') ? 'png' : 'jpg';
      final fileName = '${prefix}_$hash.$ext';

      final baseDir = await getTemporaryDirectory();
      final cacheDir = Directory(p.join(baseDir.path, 'reposts', 'image_cache'));
      if (!await cacheDir.exists()) await cacheDir.create(recursive: true);

      final filePath = p.join(cacheDir.path, fileName);
      final file = File(filePath);

      // Return cached file if it already exists
      if (await file.exists()) return filePath;

      final response = await http.get(
        Uri.parse(url),
        headers: _browserHeaders,
      );
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      if (response.bodyBytes.isEmpty) return null;

      await file.writeAsBytes(response.bodyBytes);
      return filePath;
    } catch (e) {
      if (kDebugMode) print('[RepostService] Image cache failed for $url: $e');
      return null;
    }
  }
}

class _ExtractedPost {
  const _ExtractedPost({
    required this.videoUrl,
    required this.thumbnailUrl,
    required this.description,
    required this.author,
    required this.authorProfileImageUrl,
    this.likes,
    this.comments,
    this.views,
  });

  final String videoUrl;
  final String thumbnailUrl;
  final String description;
  final String author;
  final String authorProfileImageUrl;
  final int? likes;
  final int? comments;
  final int? views;
}

/// Bridge for sharing videos to social media platforms
class ShareBridge {
  static const _channel = MethodChannel('reposter/share');

  Future<void> shareToPlatform({
    required SocialPlatform platform,
    required String filePath,
    required String caption,
  }) async {
    if (kDebugMode) print('[Share] Sharing ${platform.label} video: $filePath');
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _shareOnAndroid(
        platform: platform,
        filePath: filePath,
        caption: caption,
      );
      return;
    }

    await Share.shareXFiles(
      [XFile(filePath)],
      text: caption,
    );
  }

  Future<void> _shareOnAndroid({
    required SocialPlatform platform,
    required String filePath,
    required String caption,
  }) async {
    final packages = switch (platform) {
      SocialPlatform.instagram => const ['com.instagram.android'],
      SocialPlatform.tiktok => const [
        'com.zhiliaoapp.musically',
        'com.ss.android.ugc.trill',
      ],
    };

    PlatformException? lastError;

    for (final packageName in packages) {
      try {
        await _channel.invokeMethod<void>('shareToTarget', {
          'filePath': filePath,
          'packageName': packageName,
          'caption': caption,
        });
        return;
      } on PlatformException catch (error) {
        lastError = error;
        if (error.code != 'APP_NOT_FOUND') {
          rethrow;
        }
      }
    }

    throw lastError ??
        PlatformException(
          code: 'APP_NOT_FOUND',
          message: 'Install the target app first.',
        );
  }

  Future<void> shareGeneric({
    required String filePath,
    required String caption,
  }) async {
    await Share.shareXFiles(
      [XFile(filePath)],
      text: caption,
    );
  }

  bool get supportsDirectAppShare => !kIsWeb && Platform.isAndroid;
}
