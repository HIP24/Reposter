import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'repost_service.dart';
import 'share_bridge.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ReposterApp());
}

class RoundedRectanglePlatform {
  static OutlinedBorder buttonShape(double radius) => 
    RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
}

extension StringUtils on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

class ReposterApp extends StatefulWidget {
  const ReposterApp({super.key});

  static _ReposterAppState of(BuildContext context) =>
      context.findAncestorStateOfType<_ReposterAppState>()!;

  @override
  State<ReposterApp> createState() => _ReposterAppState();
}

class _ReposterAppState extends State<ReposterApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  ThemeMode get themeMode => _themeMode;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Reposter',
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFFBF8FF),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF151118),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7C4DFF),
          brightness: Brightness.dark,
          surface: const Color(0xFF201B24),
        ),
        useMaterial3: true,
      ),
      themeMode: _themeMode,
      home: const ReposterHomePage(),
    );
  }
}

class ReposterHomePage extends StatefulWidget {
  const ReposterHomePage({super.key});

  @override
  State<ReposterHomePage> createState() => _ReposterHomePageState();
}

class _ReposterHomePageState extends State<ReposterHomePage>
    with WidgetsBindingObserver {
  static const _historyStorageKey = 'history_items_v1';
  final _service = RepostService();
  final List<HistoryItem> _history = [];
  bool _isImporting = false;
  double _importProgress = 0;
  Timer? _clipboardTimer;
  String? _lastClipboardText;

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
    _clipboardTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Clear last clipboard text on resume to allow re-import of same URL
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

    // Only import relevant URLs
    final lower = text.toLowerCase();
    final looksRelevant = lower.contains('instagram.com/') ||
        lower.contains('instagr.am/') ||
        lower.contains('tiktok.com/');

    if (!looksRelevant) {
      _lastClipboardText = text;
      return;
    }

    // Check if URL already exists in history (anywhere, not just top)
    final normalizedText = text.endsWith('/') ? text : '$text/';
    final existsInHistory = _history.any((item) {
      final url = item.draft.sourceUrl.toString();
      return url == text || url == normalizedText || '$url/' == normalizedText;
    });

    if (existsInHistory) {
      _lastClipboardText = text;
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

    FocusScope.of(context).unfocus();
    setState(() {
      _isImporting = true;
      _importProgress = 0;
    });

    try {
      // Check if we already have this URL in history to avoid redownload
      final existingIndex = _history.indexWhere((item) =>
          item.draft.sourceUrl.toString() == cleanUrl ||
          '${item.draft.sourceUrl}/' == cleanUrl ||
          item.draft.sourceUrl.toString() == '$cleanUrl/');

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
      if (kDebugMode) print('[UI] History updated. Author: ${item.draft.author}');
      await _persistHistory();


    } catch (error) {
      if (!mounted) {
        return;
      }
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
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF222028),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Delete Post?'),
        content: const Text(
          'This will permanently remove this video from your history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel', style: TextStyle(color: Colors.white)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(color: Color(0xFFFF4B4B)),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() {
        _history.removeWhere((entry) => entry.id == item.id);
      });
      await _persistHistory();

      // Attempt to clean up the video file as well
      try {
        final file = File(item.draft.videoPath);
        if (await file.exists()) await file.delete();
      } catch (_) {}

      if (popDetail && mounted) {
        Navigator.of(context).pop();
      }
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
      } catch (_) {
        // Skip malformed or stale history entries.
      }
    }

    if (!mounted) {
      return;
    }

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

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              color: theme.brightness == Brightness.dark
                  ? const Color(0xFF1F1A24)
                  : const Color(0xFFF0F0F5),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 12),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.asset(
                      'assets/reposter.png',
                      width: 36,
                      height: 36,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text('Reposter', style: theme.textTheme.headlineMedium),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => ReposterApp.of(context).toggleTheme(),
                    child: Container(
                      width: 64,
                      height: 34,
                      decoration: BoxDecoration(
                        color: theme.brightness == Brightness.dark
                            ? const Color(0xFF332C3B)
                            : Colors.grey[300],
                        borderRadius: BorderRadius.circular(17),
                      ),
                      child: Stack(
                        children: [
                          AnimatedAlign(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOutCubic,
                            alignment: theme.brightness == Brightness.light
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: Padding(
                              padding: const EdgeInsets.all(2.0),
                              child: Container(
                                width: 30,
                                height: 30,
                                alignment: Alignment.center,
                                child: Icon(
                                  theme.brightness == Brightness.light
                                      ? Icons.light_mode_rounded
                                      : Icons.dark_mode_rounded,
                                  size: 20,
                                  color: theme.brightness == Brightness.light
                                      ? Colors.orange
                                      : Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              ),
            ),
            Expanded(
              child: _history.isEmpty && !_isImporting
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'Import a reel first and it will show up in history here.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: _history.length + (_isImporting ? 1 : 0),
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: Colors.white12),
                      itemBuilder: (context, index) {
                        if (_isImporting && index == 0) {
                          return const _LoadingSkeleton();
                        }
                        final item = _history[_isImporting ? index - 1 : index];
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
                                    ),
                                    const SizedBox(width: 16),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              CircleAvatar(
                                                radius: 16,
                                                backgroundColor: theme.brightness == Brightness.dark
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
                                                        style: theme.textTheme.titleMedium
                                                            ?.copyWith(fontWeight: FontWeight.bold),
                                                      )
                                                    : null,
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
                                                        style: theme.textTheme.titleMedium?.copyWith(
                                                          fontWeight: FontWeight.bold,
                                                        ),
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
                                          const SizedBox(height: 12),
                                          Text(
                                            item.editableDescription.isEmpty
                                                ? 'No description found'
                                                : item.editableDescription,
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodyMedium?.copyWith(
                                              color: theme.brightness == Brightness.dark
                                                  ? Colors.white70
                                                  : Colors.black87,
                                            ),
                                          ),
                                        ],
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
        ),
      ),
    );
  }
}

class RepostDetailPage extends StatefulWidget {
  const RepostDetailPage({
    super.key,
    required this.item,
    required this.onDelete,
    required this.onDescriptionChanged,
  });

  final HistoryItem item;
  final VoidCallback onDelete;
  final ValueChanged<String> onDescriptionChanged;

  @override
  State<RepostDetailPage> createState() => _RepostDetailPageState();
}

class _RepostDetailPageState extends State<RepostDetailPage> {
  final _shareBridge = ShareBridge();
  late final TextEditingController _descriptionController;
  VideoPlayerController? _videoController;
  bool _isReady = false;
  
  WatermarkPosition _wmPosition = WatermarkPosition.none;
  WatermarkTheme _wmTheme = WatermarkTheme.black;
  bool _isAttributionExpanded = false;
  bool _isCaptionExpanded = false;

  @override
  void initState() {
    super.initState();
    _descriptionController = TextEditingController(
      text: widget.item.editableDescription,
    );
    _loadVideo();
  }

  Future<void> _loadVideo() async {
    final controller = VideoPlayerController.file(
      File(widget.item.draft.videoPath),
    );
    await controller.initialize();
    await controller.setLooping(true);
    if (!mounted) {
      await controller.dispose();
      return;
    }
    setState(() {
      _videoController = controller;
      _isReady = true;
    });
  }

  @override
  void dispose() {
    widget.onDescriptionChanged(_descriptionController.text);
    _descriptionController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  String get _caption =>
      widget.item.draft.buildCaption(_descriptionController.text);

  Future<void> _copyCaption() async {
    await Clipboard.setData(ClipboardData(text: _caption));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Caption copied.')));
  }

  Future<void> _shareTo(SocialPlatform target) async {
    await Clipboard.setData(ClipboardData(text: _caption));
    try {
      await _shareBridge.shareToPlatform(
        platform: target,
        filePath: widget.item.draft.videoPath,
        caption: _caption,
      );
      // No SnackBar here
    } on PlatformException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message ?? 'Could not open target app.')),
      );
    }
  }

  Future<void> _shareGeneric() async {
    await Clipboard.setData(ClipboardData(text: _caption));
    await _shareBridge.shareGeneric(
      filePath: widget.item.draft.videoPath,
      caption: _caption,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final author = widget.item.draft.authorHandle.isEmpty
        ? 'unknown'
        : widget.item.draft.authorHandle.replaceFirst(RegExp(r'^@'), '');

    return Scaffold(
      appBar: AppBar(
        backgroundColor: theme.brightness == Brightness.dark
            ? const Color(0xFF1F1A24)
            : const Color(0xFFF0F0F5),
        surfaceTintColor: Colors.transparent,
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: theme.brightness == Brightness.dark
                  ? const Color(0xFF332C3B)
                  : const Color(0xFFE0E0E0),
              backgroundImage: widget.item.draft.authorProfileImageUrl.isNotEmpty
                  ? NetworkImage(widget.item.draft.authorProfileImageUrl)
                  : null,
              child: widget.item.draft.authorProfileImageUrl.isEmpty
                  ? Text(
                      author.replaceFirst('@', '').characters.take(1).toString().toUpperCase().ifEmpty('R'),
                      style: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold),
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(author, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis)),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Share',
            onPressed: _shareGeneric,
            icon: const Icon(Icons.share_outlined, size: 22),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(22, 16, 22, 24),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.45,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.zero,
                  child: AspectRatio(
                    aspectRatio: _isReady
                        ? _videoController!.value.aspectRatio
                        : 9 / 16,
                    child: ColoredBox(
                      color: theme.brightness == Brightness.dark
                          ? const Color(0xFF222028)
                          : const Color(0xFFEEEEEE),
                      child: _isReady
                          ? Stack(
                              fit: StackFit.expand,
                              children: [
                                VideoPlayer(_videoController!),
                                // Attribution Watermark Overlay
                                if (_wmPosition != WatermarkPosition.none)
                                  Positioned(
                                    top: (_wmPosition == WatermarkPosition.topLeft || _wmPosition == WatermarkPosition.topRight) ? 4 : null,
                                    bottom: (_wmPosition == WatermarkPosition.bottomLeft || _wmPosition == WatermarkPosition.bottomRight) ? 4 : null,
                                    left: (_wmPosition == WatermarkPosition.topLeft || _wmPosition == WatermarkPosition.bottomLeft) ? 4 : null,
                                    right: (_wmPosition == WatermarkPosition.topRight || _wmPosition == WatermarkPosition.bottomRight) ? 4 : null,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: _wmTheme == WatermarkTheme.black ? Colors.black.withOpacity(0.6) : Colors.white.withOpacity(0.8),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          // App Logo
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(2),
                                            child: Image.asset(
                                              'assets/reposter.png',
                                              width: 8,
                                              height: 8,
                                              fit: BoxFit.cover,
                                            ),
                                          ),
                                          const SizedBox(width: 3),
                                          // Author Thumb
                                          CircleAvatar(
                                            radius: 5,
                                            backgroundImage: widget.item.draft.authorProfileImageUrl.isNotEmpty
                                                ? NetworkImage(widget.item.draft.authorProfileImageUrl)
                                                : null,
                                            backgroundColor: Colors.grey[800],
                                            child: widget.item.draft.authorProfileImageUrl.isEmpty
                                                ? const Icon(Icons.person, size: 5, color: Colors.white)
                                                : null,
                                          ),
                                          const SizedBox(width: 3),
                                          // Author Name
                                          Text(
                                            author.replaceFirst('@', ''),
                                            style: TextStyle(
                                              fontSize: 7,
                                              fontWeight: FontWeight.bold,
                                              color: _wmTheme == WatermarkTheme.black ? Colors.white : Colors.black,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                GestureDetector(
                                  onTap: () {
                                    final controller = _videoController!;
                                    if (controller.value.isPlaying) {
                                      controller.pause();
                                    } else {
                                      controller.play();
                                    }
                                    setState(() {});
                                  },
                                  child: Container(
                                    color: Colors.transparent,
                                    child: Center(
                                      child: Visibility(
                                        visible: !_videoController!.value.isPlaying,
                                        child: const Icon(
                                          Icons.play_arrow_rounded,
                                          color: Colors.white,
                                          size: 80,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : const Center(child: CircularProgressIndicator()),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: false,
                onExpansionChanged: (val) => setState(() => _isAttributionExpanded = val),
                tilePadding: EdgeInsets.zero,
                trailing: Icon(
                  _isAttributionExpanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_right_rounded,
                  color: theme.brightness == Brightness.dark
                      ? Colors.white54
                      : Colors.black54,
                  size: 20,
                ),
                title: Text(
                  'ATTRIBUTION SETTINGS',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.brightness == Brightness.dark
                        ? Colors.white54
                        : Colors.black54,
                    letterSpacing: 1.2,
                  ),
                ),
                children: [
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Position', style: theme.textTheme.bodySmall),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<WatermarkPosition>(
                              value: _wmPosition,
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: theme.brightness == Brightness.dark
                                    ? const Color(0xFF332D37)
                                    : Colors.black.withOpacity(0.05),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              items: WatermarkPosition.values.map((p) {
                                return DropdownMenuItem(
                                  value: p,
                                  child: Text(p.name.toUpperCase(), style: const TextStyle(fontSize: 12)),
                                );
                              }).toList(),
                              onChanged: (val) => setState(() => _wmPosition = val!),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Color', style: theme.textTheme.bodySmall),
                            const SizedBox(height: 8),
                            DropdownButtonFormField<WatermarkTheme>(
                              value: _wmTheme,
                              onChanged: _wmPosition == WatermarkPosition.none
                                  ? null
                                  : (val) => setState(() => _wmTheme = val!),
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: theme.brightness == Brightness.dark
                                    ? const Color(0xFF332D37).withOpacity(_wmPosition == WatermarkPosition.none ? 0.4 : 1.0)
                                    : Colors.black.withOpacity(_wmPosition == WatermarkPosition.none ? 0.02 : 0.05),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              items: WatermarkTheme.values.map((t) {
                                final isEnabled = _wmPosition != WatermarkPosition.none;
                                return DropdownMenuItem(
                                  value: t,
                                  child: Opacity(
                                    opacity: isEnabled ? 1.0 : 0.5,
                                    child: Row(
                                      children: [
                                        Container(
                                          width: 12,
                                          height: 12,
                                          decoration: BoxDecoration(
                                            color: t == WatermarkTheme.black ? Colors.black : Colors.white,
                                            shape: BoxShape.circle,
                                            border: t == WatermarkTheme.white ? Border.all(color: Colors.white24) : null,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(t.name.toUpperCase(), style: const TextStyle(fontSize: 12)),
                                      ],
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: false,
                onExpansionChanged: (val) => setState(() => _isCaptionExpanded = val),
                tilePadding: EdgeInsets.zero,
                trailing: Icon(
                  _isCaptionExpanded
                      ? Icons.keyboard_arrow_down_rounded
                      : Icons.keyboard_arrow_right_rounded,
                  color: theme.brightness == Brightness.dark
                      ? Colors.white54
                      : Colors.black54,
                  size: 20,
                ),
                title: Text(
                  'CAPTION',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.brightness == Brightness.dark
                        ? Colors.white54
                        : Colors.black54,
                    letterSpacing: 1.2,
                  ),
                ),
                children: [
                  TextField(
                    controller: _descriptionController,
                    minLines: 2,
                    maxLines: 5,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.brightness == Brightness.dark
                          ? Colors.white
                          : Colors.black,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Edit caption...',
                      filled: true,
                      fillColor: theme.brightness == Brightness.dark
                          ? const Color(0xFF221C27)
                          : Colors.black.withOpacity(0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(22),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: () => _shareTo(SocialPlatform.instagram),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(64),
                      backgroundColor: theme.brightness == Brightness.dark ? const Color(0xFF000000) : Colors.white,
                      foregroundColor: theme.brightness == Brightness.dark ? Colors.white : Colors.black,
                      shape: RoundedRectanglePlatform.buttonShape(22),
                      side: BorderSide(color: theme.brightness == Brightness.dark ? Colors.white24 : Colors.black12, width: 1),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(
                          theme.brightness == Brightness.dark
                              ? 'assets/social_media/instagram-dark.png'
                              : 'assets/social_media/instagram-light.png',
                          width: 22,
                          height: 22,
                        ),
                        const SizedBox(height: 4),
                        const Text('Instagram', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: FilledButton(
                    onPressed: () => _shareTo(SocialPlatform.tiktok),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(64),
                      backgroundColor: theme.brightness == Brightness.dark ? const Color(0xFF000000) : Colors.white,
                      foregroundColor: theme.brightness == Brightness.dark ? Colors.white : Colors.black,
                      shape: RoundedRectanglePlatform.buttonShape(22),
                      side: BorderSide(color: theme.brightness == Brightness.dark ? Colors.white24 : Colors.black12, width: 1),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(
                          theme.brightness == Brightness.dark
                              ? 'assets/social_media/tiktok-dark.png'
                              : 'assets/social_media/tiktok-light.png',
                          width: 22,
                          height: 22,
                        ),
                        const SizedBox(height: 4),
                        const Text('TikTok', style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoThumb extends StatelessWidget {
  const _VideoThumb({required this.platform, required this.thumbnailUrl});

  final SocialPlatform platform;
  final String thumbnailUrl;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 100,
      height: 125,
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
            // Dark overlay for better icon visibility
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
            // No icon here, moved to main entry positioned
          ],
        ),
      ),
    );
  }
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
  };

  factory HistoryItem.fromJson(Map<String, dynamic> json) {
    final platformName = json['platform'] as String? ?? 'instagram';
    final platform = SocialPlatform.values.firstWhere(
      (value) => value.name == platformName,
      orElse: () => SocialPlatform.instagram,
    );

    return HistoryItem(
      id:
          json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      draft: RepostDraft(
        sourceUrl: Uri.parse(json['sourceUrl'] as String? ?? ''),
        platform: platform,
        videoPath: json['videoPath'] as String? ?? '',
        thumbnailUrl: json['thumbnailUrl'] as String? ?? '',
        author: json['author'] as String? ?? '',
        authorProfileImageUrl: json['authorProfileImageUrl'] as String? ?? '',
        description: json['description'] as String? ?? '',
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
        final opacity = 0.05 + (_controller.value < 0.5 
            ? _controller.value 
            : 1.0 - _controller.value) * 0.1;

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
