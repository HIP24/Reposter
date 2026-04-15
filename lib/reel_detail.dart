import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'repost_service.dart';
import 'history.dart';

enum WatermarkPosition { none, topLeft, topRight, bottomLeft, bottomRight }
enum WatermarkTheme { black, white }

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
    if (!mounted) return;
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
    } on PlatformException catch (error) {
      if (!mounted) return;
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
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            final cleanAuthor = author.replaceFirst(RegExp(r'^@'), '');
            if (cleanAuthor != 'unknown') {
              final url = widget.item.draft.platform == SocialPlatform.instagram
                  ? 'https://www.instagram.com/$cleanAuthor/'
                  : 'https://www.tiktok.com/@$cleanAuthor';
              launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
            }
          },
          child: Row(
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
                        author
                            .replaceFirst('@', '')
                            .characters
                            .take(1)
                            .toString()
                            .toUpperCase()
                            .ifEmpty('R'),
                        style: theme.textTheme.labelSmall
                            ?.copyWith(fontWeight: FontWeight.bold),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                  child: Text(author,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Open in ${widget.item.draft.platform.label}',
            onPressed: () {
              launchUrl(
                widget.item.draft.sourceUrl,
                mode: LaunchMode.externalApplication,
              );
            },
            icon: Image.asset(
              widget.item.draft.platform == SocialPlatform.instagram
                  ? theme.brightness == Brightness.dark
                      ? 'assets/social_media/instagram-dark.png'
                      : 'assets/social_media/instagram-light.png'
                  : theme.brightness == Brightness.dark
                      ? 'assets/social_media/tiktok-dark.png'
                      : 'assets/social_media/tiktok-light.png',
              width: 22,
              height: 22,
            ),
          ),
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
            LayoutBuilder(
              builder: (context, constraints) {
                final aspect = _isReady ? _videoController!.value.aspectRatio : 9 / 16;
                final maxHeight = MediaQuery.of(context).size.height * 0.45;
                final videoWidth = (maxHeight * aspect).clamp(0.0, constraints.maxWidth);

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Center(
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: maxHeight,
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.zero,
                          child: AspectRatio(
                            aspectRatio: aspect,
                            child: ColoredBox(
                              color: theme.brightness == Brightness.dark
                                  ? const Color(0xFF222028)
                                  : const Color(0xFFEEEEEE),
                              child: _isReady
                                  ? Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        VideoPlayer(_videoController!),
                                        if (_wmPosition != WatermarkPosition.none)
                                          Positioned(
                                            top: (_wmPosition ==
                                                        WatermarkPosition.topLeft ||
                                                    _wmPosition ==
                                                        WatermarkPosition.topRight)
                                                ? 4
                                                : null,
                                            bottom: (_wmPosition ==
                                                        WatermarkPosition.bottomLeft ||
                                                    _wmPosition ==
                                                        WatermarkPosition.bottomRight)
                                                ? 4
                                                : null,
                                            left: (_wmPosition ==
                                                        WatermarkPosition.topLeft ||
                                                    _wmPosition ==
                                                        WatermarkPosition.bottomLeft)
                                                ? 4
                                                : null,
                                            right: (_wmPosition ==
                                                        WatermarkPosition.topRight ||
                                                    _wmPosition ==
                                                        WatermarkPosition.bottomRight)
                                                ? 4
                                                : null,
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(
                                                  horizontal: 3, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: _wmTheme == WatermarkTheme.black
                                                    ? Colors.black.withOpacity(0.6)
                                                    : Colors.white.withOpacity(0.8),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(2),
                                                    child: Image.asset(
                                                      'assets/reposter.png',
                                                      width: 8,
                                                      height: 8,
                                                      fit: BoxFit.cover,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 3),
                                                  CircleAvatar(
                                                    radius: 5,
                                                    backgroundImage: widget
                                                            .item
                                                            .draft
                                                            .authorProfileImageUrl
                                                            .isNotEmpty
                                                        ? NetworkImage(widget
                                                            .item
                                                            .draft
                                                            .authorProfileImageUrl)
                                                        : null,
                                                    backgroundColor: Colors.grey[800],
                                                    child: widget
                                                            .item
                                                            .draft
                                                            .authorProfileImageUrl
                                                            .isEmpty
                                                        ? const Icon(Icons.person,
                                                            size: 5, color: Colors.white)
                                                        : null,
                                                  ),
                                                  const SizedBox(width: 3),
                                                  Text(
                                                    author.replaceFirst('@', ''),
                                                    style: TextStyle(
                                                      fontSize: 7,
                                                      fontWeight: FontWeight.bold,
                                                      color: _wmTheme ==
                                                              WatermarkTheme.black
                                                          ? Colors.white
                                                          : Colors.black,
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
                                                visible:
                                                    !_videoController!.value.isPlaying,
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
                    if (widget.item.draft.likes != null ||
                        widget.item.draft.comments != null ||
                        widget.item.draft.views != null) ...[
                      const SizedBox(height: 18),
                      Center(
                        child: SizedBox(
                          width: videoWidth,
                          child: _StatsRow(draft: widget.item.draft),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 18),
            Theme(
              data: theme.copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: false,
                onExpansionChanged: (val) =>
                    setState(() => _isAttributionExpanded = val),
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
                                  child: Text(p.name.toUpperCase(),
                                      style: const TextStyle(fontSize: 12)),
                                );
                              }).toList(),
                              onChanged: (val) =>
                                  setState(() => _wmPosition = val!),
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
                                  : (val) =>
                                      setState(() => _wmTheme = val!),
                              decoration: InputDecoration(
                                filled: true,
                                fillColor: theme.brightness == Brightness.dark
                                    ? const Color(0xFF332D37).withOpacity(
                                        _wmPosition == WatermarkPosition.none
                                            ? 0.4
                                            : 1.0)
                                    : Colors.black.withOpacity(
                                        _wmPosition == WatermarkPosition.none
                                            ? 0.02
                                            : 0.05),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              items: WatermarkTheme.values.map((t) {
                                final isEnabled =
                                    _wmPosition != WatermarkPosition.none;
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
                                            color: t == WatermarkTheme.black
                                                ? Colors.black
                                                : Colors.white,
                                            shape: BoxShape.circle,
                                            border: t == WatermarkTheme.white
                                                ? Border.all(
                                                    color: Colors.white24)
                                                : null,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(t.name.toUpperCase(),
                                            style:
                                                const TextStyle(fontSize: 12)),
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
                onExpansionChanged: (val) =>
                    setState(() => _isCaptionExpanded = val),
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
                      backgroundColor: theme.brightness == Brightness.dark
                          ? const Color(0xFF000000)
                          : Colors.white,
                      foregroundColor: theme.brightness == Brightness.dark
                          ? Colors.white
                          : Colors.black,
                      shape: RoundedRectanglePlatform.buttonShape(22),
                      side: BorderSide(
                          color: theme.brightness == Brightness.dark
                              ? Colors.white24
                              : Colors.black12,
                          width: 1),
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
                        const Text('Instagram',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.bold)),
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
                      backgroundColor: theme.brightness == Brightness.dark
                          ? const Color(0xFF000000)
                          : Colors.white,
                      foregroundColor: theme.brightness == Brightness.dark
                          ? Colors.white
                          : Colors.black,
                      shape: RoundedRectanglePlatform.buttonShape(22),
                      side: BorderSide(
                          color: theme.brightness == Brightness.dark
                              ? Colors.white24
                              : Colors.black12,
                          width: 1),
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
                        const Text('TikTok',
                            style: TextStyle(
                                fontSize: 13, fontWeight: FontWeight.bold)),
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

class _StatsRow extends StatelessWidget {
  final RepostDraft draft;

  const _StatsRow({required this.draft});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (draft.likes != null)
            _StatItem(
              icon: Icons.favorite_border,
              count: draft.likes!,
              label: 'Likes',
            ),
          if (draft.comments != null)
            _StatItem(
              icon: Icons.chat_bubble_outline,
              count: draft.comments!,
              label: 'Comments',
            ),
          if (draft.views != null)
            _StatItem(
              icon: Icons.play_arrow_outlined,
              count: draft.views!,
              label: 'Views',
            ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final int count;
  final String label;

  const _StatItem(
      {required this.icon, required this.count, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: 24,
          color: theme.brightness == Brightness.dark
              ? Colors.white
              : Colors.black87,
        ),
        const SizedBox(height: 6),
        Text(
          _formatNumber(count),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.brightness == Brightness.dark
                ? Colors.white54
                : Colors.black54,
            fontSize: 9,
            letterSpacing: 1.0,
          ),
        ),
      ],
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
