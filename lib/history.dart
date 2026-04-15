import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'repost_service.dart';
import 'reel_detail.dart';

class RoundedRectanglePlatform {
  static OutlinedBorder buttonShape(double radius) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
}

extension StringUtils on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class HistoryItem {
  HistoryItem({
    required this.id,
    required this.draft,
    required this.editableDescription,
    required this.importedAt,
  });

  final String id;
  final RepostDraft draft;
  String editableDescription;
  final DateTime importedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'sourceUrl': draft.sourceUrl.toString(),
        'platform': draft.platform.name,
        'videoPath': draft.videoPath,
        'author': draft.author,
        'description': draft.description,
        'thumbnailUrl': draft.thumbnailUrl,
        'authorProfileImageUrl': draft.authorProfileImageUrl,
        'editableDescription': editableDescription,
        'importedAt': importedAt.toIso8601String(),
        'likes': draft.likes,
        'comments': draft.comments,
        'views': draft.views,
      };

  factory HistoryItem.fromJson(Map<String, dynamic> json) {
    final platformName = json['platform'] as String? ?? 'instagram';
    final platform = SocialPlatform.values.firstWhere(
      (value) => value.name == platformName,
      orElse: () => SocialPlatform.instagram,
    );

    return HistoryItem(
      id: json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      draft: RepostDraft(
        sourceUrl: Uri.parse(json['sourceUrl'] as String? ?? ''),
        platform: platform,
        videoPath: json['videoPath'] as String? ?? '',
        thumbnailUrl: json['thumbnailUrl'] as String? ?? '',
        author: json['author'] as String? ?? '',
        authorProfileImageUrl: json['authorProfileImageUrl'] as String? ?? '',
        description: json['description'] as String? ?? '',
        likes: json['likes'] as int?,
        comments: json['comments'] as int?,
        views: json['views'] as int?,
      ),
      editableDescription:
          json['editableDescription'] as String? ??
          json['description'] as String? ??
          '',
      importedAt:
          DateTime.tryParse(json['importedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => HistoryPageState();
}

class HistoryPageState extends State<HistoryPage>
    with WidgetsBindingObserver {
  static const _historyStorageKey = 'history_items_v1';
  static const double thumbWidth = 100.0;
  static const double thumbHeight = 120.0; // Adjusted based on your latest change
  final _service = RepostService();
  final List<HistoryItem> _history = [];
  bool _isImporting = false;
  double _importProgress = 0;
  Timer? _clipboardTimer;
  String? _lastClipboardText;

  Set<SocialPlatform> _activePlatforms = {
    SocialPlatform.instagram,
    SocialPlatform.tiktok
  };

  void togglePlatform(SocialPlatform platform) {
    setState(() {
      if (_activePlatforms.contains(platform)) {
        _activePlatforms.remove(platform);
      } else {
        _activePlatforms.add(platform);
      }
    });
  }

  bool isPlatformActive(SocialPlatform platform) =>
      _activePlatforms.contains(platform);

  List<HistoryItem> get _filteredHistory => _history
      .where((item) => _activePlatforms.contains(item.draft.platform))
      .toList();

  List<HistoryItem> get history => _history;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _restoreHistory();
    _startClipboardWatcher();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clipboardTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _lastClipboardText = null;
      _startClipboardWatcher();
      _checkClipboardForAutoImport();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _clipboardTimer?.cancel();
    }
  }

  void _startClipboardWatcher() {
    if (kIsWeb) return;

    _clipboardTimer?.cancel();
    _clipboardTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _checkClipboardForAutoImport(),
    );
    _checkClipboardForAutoImport();
  }

  Future<void> _checkClipboardForAutoImport() async {
    if (_isImporting || !mounted) return;

    String? text;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text?.trim();
    } catch (_) {
      return;
    }

    if (text == null || text.isEmpty || text == _lastClipboardText) return;

    final lower = text.toLowerCase();
    final looksRelevant = lower.contains('instagram.com/') ||
        lower.contains('instagr.am/') ||
        lower.contains('tiktok.com/');

    if (!looksRelevant) {
      _lastClipboardText = text;
      return;
    }

    // Strip query params and normalize for comparison
    String normalizedClipboard = text.split('?').first;
    if (normalizedClipboard.endsWith('/')) {
      normalizedClipboard = normalizedClipboard.substring(0, normalizedClipboard.length - 1);
    }

    final existsInHistory = _history.any((item) {
      String url = item.draft.sourceUrl.toString().split('?').first;
      if (url.endsWith('/')) {
        url = url.substring(0, url.length - 1);
      }
      return url == normalizedClipboard;
    });

    if (existsInHistory) {
      _lastClipboardText = text;
      if (kDebugMode) print('[UI] URL already in history, skipping: $normalizedClipboard');
      return;
    }

    _lastClipboardText = text;
    if (kDebugMode) print('[UI] Auto-import from clipboard: $text');
    await _importPost(url: text, fromClipboardWatcher: true);
  }

  Future<void> _importPost({
    required String url,
    bool fromClipboardWatcher = false,
  }) async {
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) return;

    // Check for duplicates BEFORE showing skeleton
    String normalizedCleanUrl = cleanUrl.split('?').first;
    if (normalizedCleanUrl.endsWith('/')) {
      normalizedCleanUrl = normalizedCleanUrl.substring(0, normalizedCleanUrl.length - 1);
    }

    final existingIndex = _history.indexWhere((item) {
      String url = item.draft.sourceUrl.toString().split('?').first;
      if (url.endsWith('/')) {
        url = url.substring(0, url.length - 1);
      }
      return url == normalizedCleanUrl;
    });

    if (existingIndex != -1) {
      final existingItem = _history[existingIndex];
      if (await File(existingItem.draft.videoPath).exists()) {
        if (kDebugMode)
          print('[UI] Reusing existing video for: ${existingItem.draft.sourceUrl}');
        setState(() {
          _history.removeAt(existingIndex);
          _history.insert(0, existingItem);
        });
        await _persistHistory();
        return;
      }
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isImporting = true;
      _importProgress = 0;
    });

    try {

      DateTime lastProgressUpdate = DateTime.now();
      final draft = await _service.importPost(
        cleanUrl,
        onProgress: (progress) {
          final now = DateTime.now();
          if (now.difference(lastProgressUpdate).inMilliseconds > 100 ||
              progress == 1.0) {
            setState(() {
              _importProgress = progress;
            });
            lastProgressUpdate = now;
          }
        },
      );

      final item = HistoryItem(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        draft: draft,
        editableDescription: draft.description,
        importedAt: DateTime.now(),
      );

      setState(() {
        _history.removeWhere(
          (entry) => entry.draft.sourceUrl == draft.sourceUrl,
        );
        _history.insert(0, item);
      });
      if (kDebugMode)
        print('[UI] History updated. Author: ${item.draft.author}');
      await _persistHistory();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.toString().replaceFirst('Exception: ', '')),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isImporting = false;
          _importProgress = 0;
        });
      }
    }
  }

  Future<void> _openItem(HistoryItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RepostDetailPage(
          item: item,
          onDelete: () => _deleteItem(item, popDetail: true),
          onDescriptionChanged: (description) {
            item.editableDescription = description;
            _persistHistory();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() {});
            });
          },
        ),
      ),
    );
  }

  Future<void> _deleteItem(HistoryItem item, {bool popDetail = false}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF222028) : Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('Delete Post?',
              style: TextStyle(color: isDark ? Colors.white : Colors.black)),
          content: Text(
            'This will permanently remove this video from your history.',
            style: TextStyle(color: isDark ? Colors.white70 : Colors.black87),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel',
                  style: TextStyle(color: isDark ? Colors.white : Colors.black87)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text(
                'Delete',
                style: TextStyle(color: Color(0xFFFF4B4B)),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      setState(() {
        _history.removeWhere((entry) => entry.id == item.id);
      });
      await _persistHistory();

      try {
        final file = File(item.draft.videoPath);
        if (await file.exists()) await file.delete();
      } catch (_) {}

      if (popDetail && mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  Future<void> deleteAll() async {
    if (_history.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final isDark = theme.brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF222028) : Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text('Delete All?',
              style: TextStyle(color: isDark ? Colors.white : Colors.black)),
          content: Text(
            'This will permanently remove all ${_history.length} videos from your history.',
            style: TextStyle(color: isDark ? Colors.white70 : Colors.black87),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel',
                  style: TextStyle(color: isDark ? Colors.white : Colors.black87)),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text(
                'Delete All',
                style: TextStyle(color: Color(0xFFFF4B4B)),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      // Delete all video files
      for (final item in _history) {
        try {
          final file = File(item.draft.videoPath);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }

      setState(() {
        _history.clear();
      });
      await _persistHistory();
    }
  }

  Future<void> _restoreHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final rawItems = prefs.getStringList(_historyStorageKey) ?? const [];
    final restored = <HistoryItem>[];

    for (final raw in rawItems) {
      try {
        final item = HistoryItem.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (await File(item.draft.videoPath).exists()) {
          restored.add(item);
        }
      } catch (_) {}
    }

    if (!mounted) return;

    setState(() {
      _history
        ..clear()
        ..addAll(restored);
    });
  }

  Future<void> _persistHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _historyStorageKey,
      _history.map((item) => jsonEncode(item.toJson())).toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      children: [
        Expanded(
          child: _history.isEmpty && !_isImporting
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'How To Repost',
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: theme.brightness == Brightness.dark
                                ? Colors.white
                                : Colors.black,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          '1) Copy the link of the reel on Instagram or TikTok.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.brightness == Brightness.dark
                                ? Colors.white70
                                : Colors.black54,
                            fontWeight: FontWeight.bold,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          '2) Return back here and wait for the post to show up.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.brightness == Brightness.dark
                                ? Colors.white70
                                : Colors.black54,
                            fontWeight: FontWeight.bold,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: _filteredHistory.length + (_isImporting ? 1 : 0),
                  separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: theme.brightness == Brightness.dark
                          ? Colors.white12
                          : Colors.black12),
                  itemBuilder: (context, index) {
                    if (_isImporting && index == 0) {
                      return const _LoadingSkeleton();
                    }
                    final item = _filteredHistory[_isImporting ? index - 1 : index];
                    return InkWell(
                      onTap: () => _openItem(item),
                      onLongPress: () => _deleteItem(item),
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _VideoThumb(
                                  platform: item.draft.platform,
                                  thumbnailUrl: item.draft.thumbnailUrl,
                                  width: thumbWidth,
                                  height: thumbHeight,
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: SizedBox(
                                    height: thumbHeight,
                                    child: Stack(
                                      children: [
                                        // Top & Middle items
                                        Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            // Top section (Profile)
                                            Row(
                                              children: [
                                                GestureDetector(
                                                  onTap: () {
                                                    final handle = item.draft.authorHandle.replaceFirst(RegExp(r'^@'), '');
                                                    final profileUrl = item.draft.platform == SocialPlatform.instagram
                                                        ? 'https://www.instagram.com/$handle/'
                                                        : 'https://www.tiktok.com/@$handle';
                                                    launchUrl(Uri.parse(profileUrl), mode: LaunchMode.externalApplication);
                                                  },
                                                  child: CircleAvatar(
                                                    radius: 16,
                                                    backgroundColor:
                                                        theme.brightness == Brightness.dark
                                                            ? const Color(0xFF332C3B)
                                                            : const Color(0xFFE0E0E0),
                                                    backgroundImage: item.draft.authorProfileImageUrl.isNotEmpty
                                                        ? NetworkImage(item.draft.authorProfileImageUrl)
                                                        : null,
                                                    child: item.draft.authorProfileImageUrl.isEmpty
                                                        ? Text(
                                                            item.draft.authorHandle
                                                                .replaceFirst('@', '')
                                                                .characters
                                                                .take(1)
                                                                .toString()
                                                                .toUpperCase()
                                                                .ifEmpty('R'),
                                                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                                          )
                                                        : null,
                                                  ),
                                                ),
                                                const SizedBox(width: 14),
                                                Expanded(
                                                  child: Row(
                                                    children: [
                                                      Flexible(
                                                        child: Text(
                                                          item.draft.authorHandle.isEmpty
                                                              ? 'unknown'
                                                              : item.draft.authorHandle.replaceFirst(RegExp(r'^@'), ''),
                                                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                                                          maxLines: 1,
                                                          overflow: TextOverflow.ellipsis,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 8),
                                                      Image.asset(
                                                        item.draft.platform == SocialPlatform.instagram
                                                            ? theme.brightness == Brightness.dark
                                                                ? 'assets/social_media/instagram-dark.png'
                                                                : 'assets/social_media/instagram-light.png'
                                                            : theme.brightness == Brightness.dark
                                                                ? 'assets/social_media/tiktok-dark.png'
                                                                : 'assets/social_media/tiktok-light.png',
                                                        width: 18,
                                                        height: 18,
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                            
                                            const SizedBox(height: 4),

                                            // Middle section (Description)
                                            Text(
                                              item.editableDescription.isEmpty ? '' : item.editableDescription,
                                              maxLines: 3,
                                              overflow: TextOverflow.ellipsis,
                                              style: theme.textTheme.bodyMedium?.copyWith(
                                                color: theme.brightness == Brightness.dark ? Colors.white70 : Colors.black87,
                                              ),
                                            ),
                                          ],
                                        ),

                                        // Bottom section (Stats)
                                        if (item.draft.likes != null || item.draft.comments != null || item.draft.views != null)
                                          Positioned(
                                            bottom: 0,
                                            left: 0,
                                            right: 0,
                                            child: Row(
                                              children: [
                                                if (item.draft.likes != null)
                                                  _StatItem(
                                                    icon: Icons.favorite_border,
                                                    count: item.draft.likes!,
                                                  ),
                                                if (item.draft.comments != null)
                                                  _StatItem(
                                                    icon: Icons.chat_bubble_outline,
                                                    count: item.draft.comments!,
                                                  ),
                                                if (item.draft.views != null)
                                                  _StatItem(
                                                    icon: Icons.play_arrow_outlined,
                                                    count: item.draft.views!,
                                                  ),
                                              ],
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _VideoThumb extends StatelessWidget {
  const _VideoThumb({
    required this.platform,
    required this.thumbnailUrl,
    required this.width,
    required this.height,
  });

  final SocialPlatform platform;
  final String thumbnailUrl;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? const Color(0xFF222028)
            : const Color(0xFFEEEEEE),
        borderRadius: BorderRadius.circular(20),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumbnailUrl.isNotEmpty)
              Image.network(
                thumbnailUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.expand(),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.3),
                    Colors.black.withOpacity(0.1),
                    Colors.black.withOpacity(0.4),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadingSkeleton extends StatefulWidget {
  const _LoadingSkeleton();

  @override
  State<_LoadingSkeleton> createState() => _LoadingSkeletonState();
}

class _LoadingSkeletonState extends State<_LoadingSkeleton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final opacity = 0.05 +
            (_controller.value < 0.5
                ? _controller.value
                : 1.0 - _controller.value) *
                0.1;

        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 100,
                height: 125,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(opacity),
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 22,
                          backgroundColor: Colors.white.withOpacity(opacity),
                        ),
                        const SizedBox(width: 14),
                        Container(
                          width: 100,
                          height: 20,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(opacity),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Container(
                      width: double.infinity,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(opacity),
                        borderRadius: BorderRadius.circular(9),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      width: 140,
                      height: 18,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(opacity),
                        borderRadius: BorderRadius.circular(9),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final int count;

  const _StatItem({required this.icon, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.brightness == Brightness.dark
        ? Colors.white70
        : Colors.black54;

    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            _formatNumber(count),
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  String _formatNumber(int number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}K';
    }
    return number.toString();
  }
}
