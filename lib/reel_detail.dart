import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'repost_service.dart';
import 'history.dart';

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
    final appTheme = Theme.of(context);
    final author = widget.item.draft.authorHandle.isEmpty
        ? 'unknown'
        : widget.item.draft.authorHandle.replaceFirst(RegExp(r'^@'), '');

    return Scaffold(
      backgroundColor: appTheme.brightness == Brightness.dark
          ? const Color(0xFF151118)
          : const Color(0xFFFBF8FF),
      body: SafeArea(
        child: Column(
          children: [
            // Custom Header
            Container(
              color: appTheme.brightness == Brightness.dark
                  ? const Color(0xFF1F1A24)
                  : const Color(0xFFF0F0F5),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 12),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back_rounded),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      color: appTheme.brightness == Brightness.dark
                          ? Colors.white.withOpacity(0.9)
                          : Colors.black.withOpacity(0.7),
                    ),
                    const SizedBox(width: 1),
                    Expanded(
                      child: GestureDetector(
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
                              backgroundColor: appTheme.brightness == Brightness.dark
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
                                      style: appTheme.textTheme.labelSmall
                                          ?.copyWith(fontWeight: FontWeight.bold),
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                author,
                                style: (Platform.isIOS
                                    ? appTheme.textTheme.titleSmall
                                    : appTheme.textTheme.titleMedium)
                                        ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  fontSize: Platform.isIOS ? 14 : null,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Open in ${widget.item.draft.platform.label}',
                      onPressed: () {
                        launchUrl(
                          widget.item.draft.sourceUrl,
                          mode: LaunchMode.externalApplication,
                        );
                      },
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: Icon(
                        Icons.exit_to_app_rounded,
                        size: 22,
                        color: appTheme.brightness == Brightness.dark
                            ? Colors.white.withOpacity(0.9)
                            : Colors.black.withOpacity(0.7),
                      ),
                    ),
                    const SizedBox(width: 1),
                    IconButton(
                      tooltip: 'Share',
                      onPressed: _shareGeneric,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      icon: Icon(
                        Icons.share_outlined,
                        size: 22,
                        color: appTheme.brightness == Brightness.dark
                            ? Colors.white.withOpacity(0.9)
                            : Colors.black.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(22, 16, 22, 24),
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final aspect = _isReady ? _videoController!.value.aspectRatio : 9 / 16;
                      final maxHeight = MediaQuery.of(context).size.height * 0.45;
                      final vw = (maxHeight * aspect).clamp(0.0, constraints.maxWidth);

                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Center(
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxHeight: maxHeight),
                              child: ClipRRect(
                                borderRadius: BorderRadius.zero,
                                child: AspectRatio(
                                  aspectRatio: aspect,
                                  child: ColoredBox(
                                    color: appTheme.brightness == Brightness.dark
                                        ? const Color(0xFF222028)
                                        : const Color(0xFFEEEEEE),
                                    child: _isReady
                                        ? Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              VideoPlayer(_videoController!),
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
                                        : Center(
                                            child: CircularProgressIndicator(
                                              color: appTheme.brightness == Brightness.dark
                                                  ? Colors.white
                                                  : Colors.black,
                                            ),
                                          ),
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
                                width: vw,
                                child: _StatsRow(draft: widget.item.draft),
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 16),
                  Theme(
                    data: appTheme.copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      initiallyExpanded: false,
                      onExpansionChanged: (val) =>
                          setState(() => _isCaptionExpanded = val),
                      tilePadding: EdgeInsets.zero,
                      trailing: Icon(
                        _isCaptionExpanded
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.keyboard_arrow_right_rounded,
                        color: appTheme.brightness == Brightness.dark
                            ? Colors.white54
                            : Colors.black54,
                        size: 20,
                      ),
                      title: Text(
                        'CAPTION',
                        style: appTheme.textTheme.labelMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: appTheme.brightness == Brightness.dark
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
                          style: appTheme.textTheme.bodyMedium?.copyWith(
                            color: appTheme.brightness == Brightness.dark
                                ? Colors.white
                                : Colors.black,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Edit caption...',
                            filled: true,
                            fillColor: appTheme.brightness == Brightness.dark
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
                            backgroundColor: appTheme.brightness == Brightness.dark
                                ? const Color(0xFF000000)
                                : Colors.white,
                            foregroundColor: appTheme.brightness == Brightness.dark
                                ? Colors.white
                                : Colors.black,
                            shape: RoundedRectanglePlatform.buttonShape(22),
                            side: BorderSide(
                                color: appTheme.brightness == Brightness.dark
                                    ? Colors.white24
                                    : Colors.black12,
                                width: 1),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Image.asset(
                                appTheme.brightness == Brightness.dark
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
                            backgroundColor: appTheme.brightness == Brightness.dark
                                ? const Color(0xFF000000)
                                : Colors.white,
                            foregroundColor: appTheme.brightness == Brightness.dark
                                ? Colors.white
                                : Colors.black,
                            shape: RoundedRectanglePlatform.buttonShape(22),
                            side: BorderSide(
                                color: appTheme.brightness == Brightness.dark
                                    ? Colors.white24
                                    : Colors.black12,
                                width: 1),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Image.asset(
                                appTheme.brightness == Brightness.dark
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
    final spacing = Platform.isIOS ? 16.0 : 24.0;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (draft.likes != null)
          _StatItem(icon: Icons.favorite_border, count: draft.likes!, label: 'Likes'),
        if (draft.likes != null && (draft.comments != null || draft.views != null))
          SizedBox(width: spacing),
        if (draft.comments != null)
          _StatItem(icon: Icons.chat_bubble_outline, count: draft.comments!, label: 'Comments'),
        if (draft.comments != null && draft.views != null)
          SizedBox(width: spacing),
        if (draft.views != null)
          _StatItem(icon: Icons.play_arrow_outlined, count: draft.views!, label: 'Views'),
      ],
    );
  }
}

class _StatItem extends StatelessWidget {
  final IconData icon;
  final int count;
  final String label;

  const _StatItem({required this.icon, required this.count, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconSize = Platform.isIOS ? 18.0 : 24.0;
    final fontSize = Platform.isIOS ? 14.0 : 16.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: iconSize, color: theme.brightness == Brightness.dark ? Colors.white : Colors.black87),
        const SizedBox(height: 6),
        Text(_formatNumber(count), style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.bold,
          fontSize: fontSize,
        )),
        Text(label.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(
          color: theme.brightness == Brightness.dark ? Colors.white54 : Colors.black54,
          fontSize: Platform.isIOS ? 8 : 9,
          letterSpacing: 1.0,
        )),
      ],
    );
  }

  String _formatNumber(int number) {
    if (number >= 1000000) return '${(number / 1000000).toStringAsFixed(1)}M';
    if (number >= 1000) return '${(number / 1000).toStringAsFixed(1)}K';
    return number.toString();
  }
}
