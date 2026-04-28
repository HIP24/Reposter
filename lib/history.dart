import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
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
    this.localThumbnailPath,
    this.localProfileImagePath,
  });

  final String id;
  final RepostDraft draft;
  String editableDescription;
  final DateTime importedAt;

  /// Local file path for the cached thumbnail image (survives CDN URL expiry).
  String? localThumbnailPath;

  /// Local file path for the cached author profile image.
  String? localProfileImagePath;

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
        'localThumbnailPath': localThumbnailPath,
        'localProfileImagePath': localProfileImagePath,
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
      localThumbnailPath: json['localThumbnailPath'] as String?,
      localProfileImagePath: json['localProfileImagePath'] as String?,
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
  static const double thumbHeight = 125.0; // Adjusted based on your latest change
  final _service = RepostService();
  final List<HistoryItem> _history = [];
  List<HistoryItem> _cachedFilteredHistory = [];
  bool _isImporting = false;
  double _importProgress = 0;
  Timer? _clipboardTimer;
  String? _lastClipboardText;
  String? _highlightedItemId;
  Timer? _highlightTimer;
  final ScrollController _scrollController = ScrollController();

  Set<SocialPlatform> _activePlatforms = {
    SocialPlatform.instagram,
    SocialPlatform.tiktok
  };

  void _updateFilteredHistory() {
    _cachedFilteredHistory = _history
        .where((item) => _activePlatforms.contains(item.draft.platform))
        .toList();
  }

  void togglePlatform(SocialPlatform platform) {
    setState(() {
      if (_activePlatforms.contains(platform)) {
        _activePlatforms.remove(platform);
      } else {
        _activePlatforms.add(platform);
      }
      _updateFilteredHistory();
    });
  }

  bool isPlatformActive(SocialPlatform platform) =>
      _activePlatforms.contains(platform);

  List<HistoryItem> get _filteredHistory => _cachedFilteredHistory;

  List<HistoryItem> get history => _history;

  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeData();
  }

  Future<void> _initializeData() async {
    await _restoreHistory();
    if (mounted) {
      setState(() {
        _isInitialized = true;
      });
    }
    _startClipboardWatcher();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clipboardTimer?.cancel();
    _highlightTimer?.cancel();
    _scrollController.dispose();
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

    HistoryItem? existingItem;
    for (final item in _history) {
      String url = item.draft.sourceUrl.toString().split('?').first;
      if (url.endsWith('/')) url = url.substring(0, url.length - 1);
      if (url == normalizedClipboard) {
        existingItem = item;
        break;
      }
    }

    if (existingItem != null) {
      _lastClipboardText = text;
      if (kDebugMode) print('[UI] URL already in history, skipping: $normalizedClipboard');
      _flashHighlight(existingItem.id);
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

    // Resolve canonical URL to reliably catch TikTok shortlinks (vm.tiktok) or Instagram variants
    final canonicalUrl = await _service.resolveCanonicalUrl(cleanUrl);

    final existingIndex = _history.indexWhere((item) {
      return item.draft.sourceUrl == canonicalUrl || 
             item.draft.sourceUrl.toString().split('?').first.replaceAll(RegExp(r'/$'), '') == canonicalUrl.replaceAll(RegExp(r'/$'), '');
    });

    if (existingIndex != -1) {
      final existingItem = _history[existingIndex];
      if (await File(existingItem.draft.videoPath).exists()) {
        if (kDebugMode)
          print('[UI] Reusing existing video for: $canonicalUrl');
        setState(() {
          _history.removeAt(existingIndex);
          _history.insert(0, existingItem);
          _updateFilteredHistory();
        });
        await _persistHistory();
        _flashHighlight(existingItem.id);
        return;
      }
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _isImporting = true;
      _importProgress = 0;
    });
    // Scroll to top immediately so the skeleton at index 0 is visible
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOutCubic,
        );
      }
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

      // Cache thumbnail & profile image locally so they survive CDN URL expiry
      item.localThumbnailPath = await RepostService.cacheImageLocally(
        draft.thumbnailUrl, prefix: 'thumb',
      );
      item.localProfileImagePath = await RepostService.cacheImageLocally(
        draft.authorProfileImageUrl, prefix: 'profile',
      );

      setState(() {
        _history.removeWhere(
          (entry) => entry.draft.sourceUrl == draft.sourceUrl,
        );
        _history.insert(0, item);
        _updateFilteredHistory();
      });
      if (kDebugMode)
        print('[UI] History updated. Author: ${item.draft.author}');
      await _persistHistory();
      // Scroll to top so the new reel is visible
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
        );
      }
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

  void _flashHighlight(String itemId) {
    if (!mounted) return;
    _highlightTimer?.cancel();
    setState(() => _highlightedItemId = itemId);

    // Scroll to the item so the user can see it
    final index = _filteredHistory.indexWhere((e) => e.id == itemId);
    if (index != -1 && _scrollController.hasClients) {
      final itemOffset = index * (thumbHeight + 36 + 1); // height + padding + divider
      _scrollController.animateTo(
        itemOffset.clamp(0.0, _scrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    }

    _highlightTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _highlightedItemId = null);
    });
  }

  Future<void> _openItem(HistoryItem item) async {
    await Navigator.of(context).push(
      CupertinoPageRoute(
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

  Future<bool> _confirmDeleteModal() async {
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
    return confirmed == true;
  }

  Future<void> _performItemDelete(HistoryItem item, {bool popDetail = false}) async {
    setState(() {
      _history.removeWhere((entry) => entry.id == item.id);
      _updateFilteredHistory();
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

  Future<void> _deleteItem(HistoryItem item, {bool popDetail = false}) async {
    if (await _confirmDeleteModal()) {
      await _performItemDelete(item, popDetail: popDetail);
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
        _updateFilteredHistory();
      });
      await _persistHistory();
    }
  }

  Future<void> _restoreHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final rawItems = prefs.getStringList(_historyStorageKey) ?? const [];
    final restored = <HistoryItem>[];
    var needsPersist = false;

    for (final raw in rawItems) {
      try {
        final item = HistoryItem.fromJson(
          jsonDecode(raw) as Map<String, dynamic>,
        );
        if (await File(item.draft.videoPath).exists()) {
          // Migrate: cache images locally if not already cached
          if (item.localThumbnailPath == null ||
              !(await File(item.localThumbnailPath!).exists())) {
            item.localThumbnailPath = await RepostService.cacheImageLocally(
              item.draft.thumbnailUrl, prefix: 'thumb',
            );
            needsPersist = true;
          }
          if (item.localProfileImagePath == null ||
              !(await File(item.localProfileImagePath!).exists())) {
            item.localProfileImagePath = await RepostService.cacheImageLocally(
              item.draft.authorProfileImageUrl, prefix: 'profile',
            );
            needsPersist = true;
          }
          restored.add(item);
        }
      } catch (_) {}
    }

    if (!mounted) return;

    setState(() {
      _history
        ..clear()
        ..addAll(restored);
      _updateFilteredHistory();
    });

    if (needsPersist) await _persistHistory();
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
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: !_isInitialized
                ? const SizedBox(key: ValueKey('loading_history_state'))
                : _history.isEmpty && !_isImporting
                    ? Center(
                        key: const ValueKey('empty_repost_state'),
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
                : _filteredHistory.isEmpty && !_isImporting
                    ? const SizedBox(key: ValueKey('empty_filtered_state'), width: double.infinity, height: double.infinity)
                    : ListView.separated(
                        key: const ValueKey('master_history_list'),
                        controller: _scrollController,
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: _filteredHistory.length + (_isImporting ? 1 : 0),
                  separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: theme.brightness == Brightness.dark
                          ? Colors.white12
                          : Colors.black12),
                  itemBuilder: (context, index) {
                    Widget child;
                    if (_isImporting && index == 0) {
                      child = const _LoadingSkeleton(key: ValueKey('skeleton'));
                    } else {
                      final item = _filteredHistory[_isImporting ? index - 1 : index];
                      final isHighlighted = _highlightedItemId == item.id;
                      child = Dismissible(
                        key: ValueKey(item.id),
                        direction: DismissDirection.endToStart,
                        confirmDismiss: (_) => _confirmDeleteModal(),
                        onDismissed: (_) => _performItemDelete(item),
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          color: const Color(0xFFFF4B4B),
                          child: const Icon(Icons.delete_outline, color: Colors.white, size: 28),
                        ),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.easeInOut,
                          color: isHighlighted
                              ? (theme.brightness == Brightness.dark
                                  ? Colors.white.withOpacity(0.10)
                                  : Colors.black.withOpacity(0.07))
                              : Colors.transparent,
                          child: InkWell(
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
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              _VideoThumb(
                                platform: item.draft.platform,
                                thumbnailUrl: item.draft.thumbnailUrl,
                                localPath: item.localThumbnailPath,
                                width: thumbWidth,
                                height: thumbHeight,
                              ),
                              Positioned(
                                right: 6,
                                bottom: 6,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.4),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Image.asset(
                                    item.draft.platform == SocialPlatform.instagram
                                        ? 'assets/social_media/instagram-dark.png'
                                        : 'assets/social_media/tiktok-dark.png',
                                    width: 12,
                                    height: 12,
                                  ),
                                ),
                              ),
                            ],
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
                                                    backgroundImage: item.localProfileImagePath != null
                                                        ? FileImage(File(item.localProfileImagePath!))
                                                        : (item.draft.authorProfileImageUrl.isNotEmpty
                                                            ? NetworkImage(item.draft.authorProfileImageUrl)
                                                            : null),
                                                    child: (item.localProfileImagePath == null && item.draft.authorProfileImageUrl.isEmpty)
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
                                                const SizedBox(width: 8),
                                                Expanded(
                                                  child: Row(
                                                    children: [
                                                      Flexible(
                                                        child: Text(
                                                          item.draft.authorHandle.isEmpty
                                                              ? 'unknown'
                                                              : item.draft.authorHandle.replaceFirst(RegExp(r'^@'), ''),
                                                          style: (Platform.isIOS
                                                              ? theme.textTheme.titleSmall
                                                              : theme.textTheme.titleMedium)
                                                                  ?.copyWith(
                                                                fontWeight: FontWeight.bold,
                                                                fontSize:
                                                                    Platform.isIOS
                                                                        ? 14
                                                                        : null,
                                                              ),
                                                          maxLines: 1,
                                                          overflow: TextOverflow.ellipsis,
                                                        ),
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
                                                color: theme.brightness == Brightness.dark
                                                    ? Colors.white70
                                                    : Colors.black87,
                                                fontSize: Platform.isIOS ? 12 : null,
                                              ),
                                            ),
                                          ],
                                        ),

                                        // Bottom section (Stats)
                                        Positioned(
                                          bottom: 0,
                                          left: 0,
                                          right: 0,
                                          child: Row(
                                            children: [
                                              _StatItem(
                                                icon: Icons.favorite_border,
                                                count: _formatNumber(item.draft.likes),
                                              ),
                                              _StatItem(
                                                icon: Icons.chat_bubble_outline,
                                                count: _formatNumber(item.draft.comments),
                                              ),
                                              _StatItem(
                                                icon: Icons.play_arrow_outlined,
                                                count: item.draft.platform == SocialPlatform.instagram
                                                    ? (item.draft.views != null ? _formatNumber(item.draft.views!) : '-')
                                                    : _formatNumber(item.draft.views),
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
                      ), // InkWell
                     ), // AnimatedContainer
                    ); // Dismissible
                    }
                    return child;
                  },
                ),
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
    this.localPath,
  });

  final SocialPlatform platform;
  final String thumbnailUrl;
  final double width;
  final double height;
  /// If set, prefer displaying from this local file instead of [thumbnailUrl].
  final String? localPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Prefer local file, fall back to network URL
    Widget? imageWidget;
    if (localPath != null) {
      imageWidget = Image.file(
        File(localPath!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) {
          // Local file missing/corrupt — try network as fallback
          if (thumbnailUrl.isNotEmpty) {
            return Image.network(
              thumbnailUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.expand(),
            );
          }
          return const SizedBox.expand();
        },
      );
    } else if (thumbnailUrl.isNotEmpty) {
      imageWidget = Image.network(
        thumbnailUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.expand(),
      );
    }

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
            if (imageWidget != null) imageWidget,
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
  const _LoadingSkeleton({super.key});

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
      duration: const Duration(milliseconds: 1700),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Solid base color for the skeleton shapes (will be masked by ShaderMask)
    final shapeColor = Colors.white;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // shimmerX moves from -1.0 to 2.0 to ensure it starts fully offscreen left,
        // sweeps entirely across, and has an extremely brief pause before returning.
        final shimmerX = _controller.value * 3.0 - 1.0;

        // Helper to create solid shapes
        Widget solidShape(double w, double h, BorderRadius r) {
          return Container(
            width: w,
            height: h,
            decoration: BoxDecoration(color: shapeColor, borderRadius: r),
          );
        }

        final skeletonLayout = Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Thumbnail placeholder
            solidShape(100, 125, BorderRadius.circular(20)),
            const SizedBox(width: 16),
            Expanded(
              child: SizedBox(
                height: 125,
                child: Stack(
                  children: [
                    // Top: avatar + name bars
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            solidShape(32, 32, BorderRadius.circular(16)),
                            const SizedBox(width: 8),
                            solidShape(100, 20, BorderRadius.circular(10)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        solidShape(double.infinity, 14, BorderRadius.circular(7)),
                        const SizedBox(height: 8),
                        solidShape(140, 14, BorderRadius.circular(7)),
                      ],
                    ),
                    // Bottom: stats placeholders
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: Row(
                        children: [
                          _SkeletonStatItem(shapeColor: shapeColor),
                          _SkeletonStatItem(shapeColor: shapeColor),
                          _SkeletonStatItem(shapeColor: shapeColor),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );

        return Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: ShaderMask(
            blendMode: BlendMode.srcIn,
            shaderCallback: (bounds) {
              return LinearGradient(
                // 45 degree diagonal sweeping across the united bounds
                begin: Alignment(shimmerX - 0.8, shimmerX - 0.8),
                end: Alignment(shimmerX + 0.8, shimmerX + 0.8),
                colors: isDark
                    ? [
                        Colors.white.withOpacity(0.06),
                        Colors.white.withOpacity(0.80),
                        Colors.white.withOpacity(0.06),
                      ]
                    : [
                        Colors.black.withOpacity(0.04),
                        Colors.black.withOpacity(0.60),
                        Colors.black.withOpacity(0.04),
                      ],
                stops: const [0.0, 0.5, 1.0],
              ).createShader(bounds);
            },
            child: skeletonLayout,
          ),
        );
      },
    );
  }
}

class _SkeletonStatItem extends StatelessWidget {
  final Color shapeColor;
  const _SkeletonStatItem({required this.shapeColor});

  @override
  Widget build(BuildContext context) {
    final w = Platform.isIOS ? 55.0 : 65.0;
    final iconSize = Platform.isIOS ? 12.0 : 14.0;

    Widget solidShape(double width, double height, BorderRadius radius) {
      return Container(
        width: width,
        height: height,
        decoration: BoxDecoration(color: shapeColor, borderRadius: radius),
      );
    }

    return SizedBox(
      width: w,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          solidShape(iconSize, iconSize, BorderRadius.circular(iconSize / 2)),
          const SizedBox(width: 4),
          solidShape(
              28, Platform.isIOS ? 10.0 : 11.0, BorderRadius.circular(6)),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {

  final IconData icon;
  final String count;

  const _StatItem({required this.icon, required this.count});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconSize = Platform.isIOS ? 12.0 : 14.0;
    final fontSize = Platform.isIOS ? 10.0 : 11.0;
    
    return SizedBox(
      width: Platform.isIOS ? 55 : 65, // Fixed width for alignment
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: iconSize,
            color: theme.brightness == Brightness.dark ? Colors.white54 : Colors.black45,
          ),
          const SizedBox(width: 4),
          Text(
            count,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.brightness == Brightness.dark ? Colors.white54 : Colors.black45,
              fontWeight: FontWeight.bold,
              fontSize: fontSize,
            ),
          ),
        ],
      ),
    );
  }
}

String _formatNumber(int? number) {
  if (number == null) return '0';
  if (number >= 1000000) {
    return '${(number / 1000000).toStringAsFixed(1)}M';
  } else if (number >= 1000) {
    return '${(number / 1000).toStringAsFixed(1)}K';
  }
  return number.toString();
}
